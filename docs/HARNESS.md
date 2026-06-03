# kclawbox Harness

> The single most important document for this project. Read it before touching
> the boot path, the memory pipeline, the cron jobs, or the provider config.

## 0. What the harness *is*

kclawbox runs a **small, weak, local model** (default `qwen3.6:latest` on Ollama).
Such a model is, by nature, unreliable: it **hallucinates, loops, is slow,
forgets, and behaves differently every run.** That cannot be fixed — it is a
property of the model. So we do not try to make the *model* reliable; we move
reliability **out of the model and into deterministic code around it.**

**The harness is that deterministic scaffolding** — everything outside the
model's probabilistic generation that turns a dumb, unreliable engine into a
trustworthy, reproducible agent. It does four jobs:

1. **Constrain** — encode procedures as deterministic code, not model prompts.
   (Raw capture is a shell loop, not an LLM turn. Debate is `debate.js`, not a
   "please run a debate" prompt.)
2. **Ground** — feed the model real data so it cannot confabulate. (Recall
   injection; the retrospective must read today's raw and report only what is
   there — "no activity" if empty, never an invented day.)
3. **Provision** — supply the capabilities the model lacks reliably: memory
   (L1/L2/L3), web search/fetch, scheduling.
4. **Recover** — fail safely when the model misbehaves: loop detection,
   self-heal from canonical copies, idempotency, isolation of failing steps,
   and **honest failure over confabulation.**

**Guiding law:** *the weaker the model, the more the harness must carry.* Every
failure this system has had was a **hole in the harness**, not bad luck — and
every fix is the same move: **shift the burden from the model to the harness,
and where the model must act, force grounding.**

What is **not** the harness: the model's generation itself. We never make that
deterministic — we surround it (constrain / ground / curate / recover / observe).

### This is the industry "agent harness"

The definition above is not idiosyncratic — it is the mainstream **agent
harness** concept: *the scaffolding around an LLM that turns it into a working
agent (control loop, tool calls, context management, memory, guardrails,
tracing) — everything except the model's reasoning.* The documented consensus is
that **the harness matters as much as or more than the model**: the same model
swings up to ~6x on task performance depending on harness design (Stanford/
Tsinghua), and the same Claude model scored 46% vs 80% on one benchmark purely
by changing the harness (Cursor). And, directly mirroring this project: *most
agent failures are not bad reasoning — they are the harness feeding bad context,
mishandling a tool error, or letting the model loop.* For a **small local
model**, this is not a nice-to-have; the harness is the product. (Note: "harness"
also has an older meaning — an **evaluation harness** like `lm-evaluation-harness`
that runs a model against benchmarks. We mean the **agent/runtime** harness.)

### The harness's jobs (functional view)

1. **Constrain** — procedures as deterministic code, not prompts.
2. **Ground** — feed real data so the model cannot confabulate.
3. **Curate context** — decide what enters the window each turn (in kclawbox:
   the `memory-graph-recall` injection + L1 `MEMORY.md` + compaction).
4. **Provision** — memory (L1/L2/L3), web search/fetch, scheduling.
5. **Recover** — loop detection, self-heal, idempotency, step isolation, and
   honest failure over confabulation.
6. **Observe / Verify** — determine, from the environment, whether what was
   supposed to happen actually happened. *This is kclawbox's weakest leg* — see
   the structural view below and debt F in §8.

### Structural view (task / environment / harness / verifier)

The functional view above is the "agent harness as the whole wrapper" sense.
There is a second, more rigorous lineage (from RL / agent **evaluation** harnesses)
where a complete agent system decomposes into siblings:

| Component | Meaning | kclawbox |
| --- | --- | --- |
| **Task** | the goal / input distribution the agent is measured against | **weak/implicit** — "be a good companion, run the crons, keep memory" is not a measurable goal |
| **Environment** | observation + action + state the agent acts in | **strong** — OpenClaw runtime, tools (web/memory), Telegram, filesystem |
| **Harness** (narrow) | *how* the agent interacts / the policy is executed | **strong & growing** — entrypoint, config pins, recall injection, capture loop |
| **Verifier / Evaluator** | the deterministic definition of "did it succeed?" | **ABSENT** |

In this lineage "harness" is one component, not the whole — so be precise about
which sense you mean.

**The missing verifier is the root cause of the confabulation pathology.** When
no deterministic component answers "did it work?", the only available answer is
the model narrating itself — and a weak model narrating itself **hallucinates**
(it reported the memory graph "frozen" and invented a day's retrospective; both
false). The fix is not "trust the model less"; it is to **add the verifier leg**:
deterministic checks that read environment state — raw file grew? distill
produced nodes? cron delivered? db row count changed? — and emit ground-truth
status independent of the model.

(kclawbox is a *deployed companion*, not an RL/training setup, so there is no
reward signal or learning — the model is fixed. What it needs is the
**operational verifier**: continuous, deterministic confirmation that the harness
is doing its job, surfaced from data rather than narration.)

---

## 1. Where things live (repo ↔ volume ↔ container)

This is the #1 source of confusion. Three distinct layers:

| Layer | Path | Persists across | Source of truth? |
| --- | --- | --- | --- |
| **Repo** (image build) | `/media/data/users/jk/kclawbox` → baked into image at `/opt/kclawbox` and `/usr/local/bin/entrypoint.sh` | rebuilds | YES — version controlled |
| **Volumes** (runtime state) | host `workspaces/fox/{home,openclaw,ollama}` → container `/data/{home,openclaw,ollama}` | recreate & restart (NOT rebuild) | runtime state only |
| **Container FS** | everything else (`/usr/local/node/...`, installed openclaw) | nothing — reset to image on recreate | ephemeral |

Consequences you must internalize:
- **`entrypoint.sh` is COPYed into the image** (`/usr/local/bin/entrypoint.sh`).
  Editing the host file does nothing until `docker compose build` + recreate.
- **OpenClaw is NOT installed in the Dockerfile.** It is installed at first boot
  via `ollama launch openclaw` (entrypoint), into the ephemeral container FS.
  Therefore **every `docker compose up` recreate reinstalls openclaw at the
  latest version** (this silently upgraded 2026.4.23 → 2026.5.28). A plain
  `docker restart` does NOT reinstall (keeps the writable layer). If version
  stability ever matters, pin it.
- **Runtime state (config, memory, crons) lives in the `/data/openclaw` and
  `/data/home` volumes** and survives recreate. But it is **not in the repo**,
  so it is not reviewable/reproducible — see the open debts in §6.
- **The memory pipeline scripts live ONLY in the volume**
  (`/data/home/memory/scripts/`, host `workspaces/fox/...`, which is
  `.gitignore`d). The harness's deterministic heart is currently *outside*
  version control. (Debt D.)

---

## 2. Boot sequence (`entrypoint.sh`)

Order matters; each step assumes the previous succeeded.

1. Seed bundled skills + default workspace into the runtime workspace (once).
2. `ollama serve` on `OLLAMA_SERVER_HOST` (default `127.0.0.1:11435`).
3. **ollama loop guard** (`runtime/ollama-loop-guard.mjs`) — a proxy on `:11434`
   in front of ollama `:11435` so a single hung generation cannot block forever.
4. Pull chat model + **embedding model** (`nomic-embed-text`).
5. Bootstrap openclaw (`ollama launch openclaw`) if the binary/config is absent.
6. Gateway config (`config set gateway.*`).
7. **Harness config pins** (the deterministic defaults, §4): memory_search →
   local ollama; web_search → key-free provider; web_fetch → local. Re-asserted
   **every boot** because the onboard wizard wipes these on upgrades.
8. Telegram channel.
9. **Launch the raw-capture loop** (`raw-capture-loop.sh`, §5) in the background.
10. `exec openclaw gateway run`.

> entrypoint currently does orchestration **and** config-pinning **and** service
> launches in one 261-line file. Phase 1 of the refactor extracts the pins. See §7.

---

## 3. Memory system (L1 / L2 / L3)

Three layers + deterministic pipelines. Recall is grounded; the model only
distills, never invents the structure.

- **L1 Identity** — `workspace/{SOUL,IDENTITY,USER,MEMORY}.md`. Character,
  relationship, lessons. `MEMORY.md` is loaded into context every session and is
  what the built-in `memory_search` (memory-core) indexes.
- **L2 Knowledge Graph** (the core) — `~/memory/graph/{people,projects,concepts,
  tools,places,tasks}/*.md`, atomic nodes + YAML relations, indexed in
  `~/memory/indexes/memory.db` (SQLite, trigram FTS — Korean-safe). Recall =
  the `memory-graph-recall` plugin injecting relevant nodes before each turn
  (pure SQLite, no embeddings, no LLM).
- **L3 Raw Archive** — `~/memory/raw/YYYY-MM-DD.md` verbatim, vector-indexed in
  `~/memory/indexes/l3.db` (Float32 BLOB, nomic-embed-text via `l3-index.js`).

Pipelines (`~/memory/scripts/`):
- **Capture**: `raw-capture-loop.sh` → `auto-raw-save.sh` regenerates today's raw
  from the authoritative Telegram session transcript (`sessions.json` →
  `sessionFile` JSONL). Deterministic, idempotent, no LLM. (§5)
- **Nightly** (04:00): `nightly.js` chains `l3-index` (vector index raw) →
  `l3-to-l2` (distill L3 → L2 nodes) → `reflect` (propose L1 updates).
  GraphRAG steps are hardcoded-skipped (see §6 / cron table).
- **Recall**: L2 via the recall plugin + `query.js`; L3 via `l3-index --search`;
  built-in `memory_search` over `MEMORY.md`.

`memory_search` (built-in memory-core) is **separate** from the custom L2/L3
system and only indexes `MEMORY.md`. Both are now fully local (no API key).

---

## 4. Deterministic config pins (the invariants)

These are asserted by entrypoint every boot and must always hold. When something
breaks, check these first.

| Invariant | Config | Why |
| --- | --- | --- |
| memory_search is **local** | `agents.defaults.memorySearch.provider=ollama`, `model=nomic-embed-text:latest` | unset → OpenClaw defaults to `openai` → demands `OPENAI_API_KEY` |
| web_search is **key-free** | `tools.web.search.provider` = `searxng` (active) | unset → auto-detects `ollama` provider → needs `ollama signin` → fails |
| web_fetch is **local** | `tools.web.fetch.enabled=true` | native HTTP+Readability, no key (firecrawl is the only pluggable fetch provider and needs a key) |
| no external embedding/search keys required | — | the whole point: a self-contained local box |
| raw capture is **deterministic** | `raw-capture-loop.sh`, not a cron LLM turn | an LLM turn confabulates + spams |
| retrospective is **grounded** | 23:30 cron prompt: read raw first, no invention | weak model fills empty context with fiction |
| reasoning loops are **bounded** | `tools.loopDetection.enabled=true` + ollama loop guard | model repeats a tool call dozens of times |

Provider precedence (entrypoint): explicit `KCLAWBOX_WEB_SEARCH_PROVIDER` >
SearXNG (`SEARXNG_BASE_URL`) > Brave (`BRAVE_API_KEY`) > DuckDuckGo.

---

## 5. Capabilities & services

- **SearXNG** (`searxng` compose service, `searxng/settings.yml`): self-hosted,
  key-free metasearch aggregating Google/Bing/Brave/DDG → engine-level
  resilience in one query. Gotcha: **JSON API is off by default** — settings
  must set `search.formats: [html, json]` + a `secret_key` + `limiter: false`.
  Fox reaches it at `http://searxng:8080`.
- **Brave** (optional): external plugin `@openclaw/brave-plugin` (NOT stock —
  must be `plugins install`ed; lands in the `/data/openclaw` volume). Key in
  `.env` → compose env → entrypoint. Configured but not active under SearXNG.
- **web_fetch**: built-in local provider (Chrome-UA HTTP GET + Readability).

---

## 6. Cron jobs (intent + status)

Runtime-created in the `/data/openclaw` volume — **not in the repo** (Debt C).
Their payloads that invoke the model must be grounded (anti-hallucination).

| Schedule (KST) | Name | Status | Notes |
| --- | --- | --- | --- |
| `0 8 * * *` | 오전 주요 뉴스 브리핑 | ON | hani + AItimes summary |
| `0 14 * * *` | daily-interesting-topic | ON | **흥미주제** (JK intent; a "stock job" node was a confabulation — reverted) |
| `30 23 * * *` | 저녁 회고 | ON | **grounded** prompt: read raw, no invention |
| `0 3 * * *` | daily-news-analysis | ON | fox-created |
| `0 4 * * *` | 새벽 기억정리 (nightly.js) | ON | L3 index → L2 distill → reflect |
| `0 * * * *` | raw-data-auto-save | **OFF** | replaced by the deterministic capture loop |
| `0 5 * * *` | graphrag-enrich | **OFF** | qwen3.6 too slow for per-chunk entity extraction (litellm timeout); non-essential |

---

## 7. Known gotchas (hard-won)

- Onboard wizard **wipes `tools.web` and `memorySearch`** on upgrade → entrypoint
  re-asserts them every boot.
- Recreate **reinstalls openclaw at latest** (binary is not in a volume).
- `openclaw session history` **does not exist** in this build — read transcripts
  from `sessions.json` → `sessionFile` JSONL directly.
- `openclaw capability web fetch` CLI only tests the firecrawl fallback — to test
  the agent's real tool path use `POST /tools/invoke` with the gateway token.
- The fox's **self-reports confabulate** (it once reported the whole memory
  system "frozen/broken" when it was healthy). Always verify against the
  deterministic data (node counts, raw files, db rows), never the narration.
- PID 1 (openclaw) does not reap orphaned zombies; they clear on restart.

---

## 8. Maintenance process

Because the harness accrues patches (each incident adds an `if`/`elif`/cron),
schedule **periodic structural refactors** instead of letting debt compound:

1. Trigger: every ~N incident-patches, or monthly.
2. Re-read this document.
3. Fold accumulated point-fixes back into structure (don't leave parallel
   special-cases).
4. Update this document in the same change. **A harness change that does not
   update HARNESS.md is incomplete.**

### Open structural debts (refactor backlog)
- **A** — entrypoint monolith (261 lines, mixed concerns). → extract pins to
  `runtime/harness-config.sh`.
- **C** — crons have no repo source-of-truth → drift. → declarative `crons.json`
  seed + boot-time reconcile.
- **D** (most dangerous) — the memory pipeline scripts live only in the volume,
  outside version control. → bring `~/memory/scripts/` into
  `default-openclaw-workspace/memory/scripts/`.
- **E** — config pins fight the onboard wizard imperatively each boot; consider a
  config-as-code approach that works *with* OpenClaw's model.
- **F** (most fundamental) — **the verifier leg is missing** (see §0 structural
  view). There is no deterministic component that answers "did it work?", so the
  only status signal is the model narrating itself — which it confabulates
  (§7). This is the *root* of the hallucination pathology, not a side issue.
  Build an operational verifier: deterministic checks that read environment state
  (raw file grew today? distill added nodes? each cron actually delivered? db row
  deltas?) and emit ground-truth health — plus a `fox status` / cron-health view
  that reads the dbs and files, never the model. Failures must surface from data.
