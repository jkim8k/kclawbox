#!/usr/bin/env node
// verify.mjs — deterministic OPERATIONAL VERIFIER for kclawbox-fox.
//
// The missing "verifier" leg of the harness (see docs/HARNESS.md §0). It reads
// ENVIRONMENT STATE only — files, SQLite dbs, cron run-state, and live HTTP
// probes of the gateway / SearXNG — and emits ground-truth health. It NEVER
// consults the model, because the model confabulates its own status.
//
// Why this exists: the existing cron "status: ok" records only that an LLM turn
// *finished*, not that the intended state change *happened* (raw-data-auto-save
// logged 54 "ok" runs while writing pure junk, plus 430 errors, for weeks, with
// no signal). A verifier checks OUTCOMES, not completion.
//
// Usage:  node verify.mjs            # human report, exit 0/1/2 = PASS/WARN/FAIL
//         node verify.mjs --json     # machine-readable
//
// Node 22+ (node:sqlite, global fetch, AbortSignal.timeout).
import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

const HOME = process.env.HOME || '/data/home';
const OC = path.join(process.env.OPENCLAW_HOME || '/data/openclaw', '.openclaw');
const MEM = path.join(HOME, 'memory');
const GW = 'http://127.0.0.1:18789';
const OLLAMA = 'http://127.0.0.1:11434';
const today = new Date().toISOString().slice(0, 10); // UTC

const readSafe = (f) => { try { return fs.readFileSync(f, 'utf8'); } catch { return null; } };
const CFG = JSON.parse(readSafe(path.join(OC, 'openclaw.json')) || '{}');
const TOKEN = process.env.OPENCLAW_GATEWAY_TOKEN || CFG?.gateway?.auth?.token || '';

const checks = [];
const add = (name, status, evidence = {}) => checks.push({ name, status, evidence });

const ageMin = (f) => { try { return +((Date.now() - fs.statSync(f).mtimeMs) / 60000).toFixed(1); } catch { return null; } };
function walk(dir, cb) { let e; try { e = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; } for (const d of e) { const p = path.join(dir, d.name); d.isDirectory() ? walk(p, cb) : cb(p); } }
async function probe(url, opts = {}, ms = 5000) {
  try { const r = await fetch(url, { ...opts, signal: AbortSignal.timeout(ms) }); const body = await r.text().catch(() => ''); return { ok: r.ok, status: r.status, body }; }
  catch (e) { return { ok: false, error: e.name || String(e) }; }
}
function telegramTurnsToday() {
  try {
    const sj = JSON.parse(fs.readFileSync(path.join(OC, 'agents/main/sessions/sessions.json'), 'utf8'));
    const k = Object.keys(sj).find((x) => /telegram:direct:/.test(x)); if (!k) return 0;
    const sf = sj[k].sessionFile; if (!sf || !fs.existsSync(sf)) return 0;
    let n = 0;
    for (const l of fs.readFileSync(sf, 'utf8').split('\n')) { if (!l) continue; let o; try { o = JSON.parse(l); } catch { continue; }
      if (o.type === 'message' && o.timestamp?.slice(0, 10) === today && ['user', 'assistant'].includes(o.message?.role)) n++; }
    return n;
  } catch { return 0; }
}

async function main() {
  // --- Services (is the environment up?) ---
  const g = await probe(`${GW}/`); add('svc:gateway', g.ok ? 'PASS' : 'FAIL', { status: g.status, error: g.error });
  const o = await probe(`${OLLAMA}/api/tags`); add('svc:ollama', o.ok ? 'PASS' : 'FAIL', { status: o.status, error: o.error });
  const sxUrl = CFG?.plugins?.entries?.searxng?.config?.webSearch?.baseUrl || process.env.SEARXNG_BASE_URL;
  if (sxUrl) { const r = await probe(`${sxUrl.replace(/\/$/, '')}/search?q=ping&format=json`, {}, 6000);
    add('svc:searxng', r.ok && /"results"|"query"/.test(r.body || '') ? 'PASS' : 'FAIL', { status: r.status, error: r.error }); }
  else add('svc:searxng', 'SKIP', { reason: 'no baseUrl' });

  let lpid = null, loopOk = false; try { lpid = parseInt(fs.readFileSync('/tmp/raw-capture-loop.pid', 'utf8').trim()); loopOk = fs.existsSync('/proc/' + lpid); } catch {}
  add('svc:capture-loop', loopOk ? 'PASS' : 'FAIL', { pid: lpid });

  let z = 0; for (const d of fs.readdirSync('/proc')) { if (!/^\d+$/.test(d)) continue; try { if (fs.readFileSync('/proc/' + d + '/stat', 'utf8').split(' ')[2] === 'Z') z++; } catch {} }
  add('svc:zombies', z <= 3 ? 'PASS' : z <= 10 ? 'WARN' : 'FAIL', { count: z });

  // --- Config invariants (the harness pins must hold) ---
  const ms = CFG?.agents?.defaults?.memorySearch?.provider;
  add('cfg:memory-local', ms === 'ollama' ? 'PASS' : 'FAIL', { provider: ms || null });
  const wp = CFG?.tools?.web?.search?.provider;
  add('cfg:web-keyfree', ['searxng', 'duckduckgo'].includes(wp) ? 'PASS' : 'WARN', { provider: wp || null });
  add('cfg:loop-detection', CFG?.tools?.loopDetection?.enabled === true ? 'PASS' : 'WARN', { enabled: !!CFG?.tools?.loopDetection?.enabled });

  // --- Capability probe (does the agent's web_search actually return results?) ---
  if (TOKEN) {
    const r = await probe(`${GW}/tools/invoke`, { method: 'POST', headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ tool: 'web_search', args: { query: '테스트' } }) }, 25000);
    let prov = null, count = null; try { const j = JSON.parse(r.body); const t = j?.result?.content?.[0]?.text || ''; prov = (t.match(/provider"\s*:\s*"([^"]+)"/) || [])[1]; count = parseInt((t.match(/count"\s*:\s*(\d+)/) || [])[1]); } catch {}
    add('cap:web-search', r.ok && count > 0 ? 'PASS' : 'FAIL', { provider: prov, count: Number.isNaN(count) ? null : count });
  } else add('cap:web-search', 'SKIP', { reason: 'no gateway token' });

  // --- Pipeline OUTCOMES (the high-value, anti-junk / anti-frozen checks) ---
  // raw capture: real turns must match today's telegram activity; never junk.
  const rawf = path.join(MEM, 'raw', today + '.md');
  const rawBody = readSafe(rawf) || '';
  const rawTurns = (rawBody.match(/^\[\d{2}:\d{2}:\d{2}\] (User|Fox)/gm) || []).length;
  const junk = /memory-graph-recall: registered/.test(rawBody) && rawTurns === 0;
  const sess = telegramTurnsToday();
  const rawAge = ageMin(rawf);
  // The capture loop runs hourly, so during an active conversation the raw
  // legitimately lags the live session by up to ~60 min of new turns — that is
  // NOT a failure. Only flag genuine breakage: junk, zero-while-active, or a
  // stalled loop (file older than the hourly cadence + grace).
  let rawStatus = 'PASS';
  if (junk) rawStatus = 'FAIL';
  else if (sess > 0 && rawTurns === 0) rawStatus = 'FAIL';
  else if (sess > 0 && rawAge === null) rawStatus = 'FAIL';
  else if (rawAge !== null && rawAge > 70) rawStatus = 'WARN'; // loop should have run within the hour
  add('pipe:raw-capture', rawStatus, { rawTurns, sessionTurns: sess, ageMin: rawAge, junk, behind: Math.max(0, sess - rawTurns) });

  // L3 vector index
  let l3 = null; try { const db = new DatabaseSync(path.join(MEM, 'indexes', 'l3.db')); l3 = db.prepare('SELECT count(*) c FROM chunks').get().c; db.close(); add('pipe:l3-index', l3 > 0 ? 'PASS' : 'WARN', { chunks: l3 }); } catch (e) { add('pipe:l3-index', 'FAIL', { error: e.message }); }

  // L2 graph: count + freshness (frozen detection)
  const nodes = []; walk(path.join(MEM, 'graph'), (f) => { if (f.endsWith('.md')) nodes.push(f); });
  const newest = nodes.length ? Math.max(...nodes.map((f) => fs.statSync(f).mtimeMs)) : 0;
  const newestDays = nodes.length ? +((Date.now() - newest) / 86400000).toFixed(1) : null;
  add('pipe:l2-graph', nodes.length > 0 && newestDays !== null && newestDays < 7 ? 'PASS' : 'WARN', { nodes: nodes.length, newestDays });

  // --- Cron OUTCOME health (replaces the misleading completion-status) ---
  const jobs = (JSON.parse(readSafe(path.join(OC, 'cron', 'jobs.json')) || '{}').jobs) || [];
  const cstate = (JSON.parse(readSafe(path.join(OC, 'cron', 'jobs-state.json')) || '{}').jobs) || {};
  for (const j of jobs.filter((x) => x.enabled)) {
    const s = cstate[j.id]?.state || {};
    const errs = s.consecutiveErrors || 0;
    const hrs = s.lastRunAtMs ? +((Date.now() - s.lastRunAtMs) / 3600000).toFixed(1) : null;
    const st = errs === 0 ? 'PASS' : errs < 3 ? 'WARN' : 'FAIL';
    add('cron:' + j.name, st, { lastStatus: s.lastRunStatus, consecutiveErrors: errs, lastRunHrsAgo: hrs, delivery: s.lastDeliveryStatus });
  }

  // --- Growth delta vs previous run (deterministic "frozen" signal) ---
  const snapf = path.join(MEM, 'indexes', 'verify-snapshot.json');
  const prev = JSON.parse(readSafe(snapf) || 'null');
  const snap = { tsMs: Date.now(), l2nodes: nodes.length, l3chunks: l3 };
  if (prev) add('trend:growth', 'INFO', { l2delta: snap.l2nodes - prev.l2nodes, l3delta: (l3 ?? 0) - (prev.l3chunks ?? 0), sinceHrs: +((snap.tsMs - prev.tsMs) / 3600000).toFixed(1) });
  try { fs.writeFileSync(snapf, JSON.stringify(snap)); } catch {}

  // --- Report ---
  const fail = checks.some((c) => c.status === 'FAIL');
  const warn = checks.some((c) => c.status === 'WARN');
  const overall = fail ? 'FAIL' : warn ? 'WARN' : 'PASS';
  if (process.argv.includes('--json')) {
    console.log(JSON.stringify({ overall, ts: new Date().toISOString(), checks }, null, 2));
  } else {
    const ic = { PASS: '✅', WARN: '⚠️ ', FAIL: '❌', SKIP: '· ', INFO: 'ℹ️ ' };
    console.log(`fox status: ${overall}  (${new Date().toISOString()})`);
    for (const c of checks) console.log(`  ${ic[c.status] || '?'} ${c.name.padEnd(22)} ${JSON.stringify(c.evidence)}`);
  }
  process.exit(overall === 'FAIL' ? 2 : overall === 'WARN' ? 1 : 0);
}
main();
