// Ollama loop guard.
//
// Sits in front of ollama and watches streaming /api/generate or /api/chat
// responses. If the model repeats the same chunk three or more times in a
// row (token-level looping inside one generation), the proxy aborts the
// upstream stream and returns a final error event so the client can move on
// instead of hanging until a watchdog kicks in.
//
// All traffic that is not a streaming generation is forwarded transparently.

import http from "node:http";
import { Buffer } from "node:buffer";

const UPSTREAM_HOST = process.env.OLLAMA_LOOPGUARD_UPSTREAM_HOST || "127.0.0.1";
const UPSTREAM_PORT = Number(process.env.OLLAMA_LOOPGUARD_UPSTREAM_PORT || 11435);
const LISTEN_HOST = process.env.OLLAMA_LOOPGUARD_LISTEN_HOST || "0.0.0.0";
const LISTEN_PORT = Number(process.env.OLLAMA_LOOPGUARD_LISTEN_PORT || 11434);
// Sliding window of recent generated text, in characters.
const WINDOW_CHARS = Number(process.env.OLLAMA_LOOPGUARD_WINDOW || 1500);
// Smallest substring length we consider a loop. Below this is noisy.
const MIN_REPEAT_LEN = Number(process.env.OLLAMA_LOOPGUARD_MIN_LEN || 40);
// Number of consecutive identical repeats that triggers an abort.
const TRIGGER_REPEATS = Number(process.env.OLLAMA_LOOPGUARD_REPEATS || 3);
// Step in characters between loop checks. Cheap CPU-wise.
const CHECK_EVERY = Number(process.env.OLLAMA_LOOPGUARD_CHECK_EVERY || 50);

const STREAM_PATHS = new Set(["/api/generate", "/api/chat"]);

function detectRepeat(buffer) {
  // Look for the smallest substring length L such that the last
  // TRIGGER_REPEATS * L characters of the buffer are L identical chunks
  // back-to-back.
  if (buffer.length < MIN_REPEAT_LEN * TRIGGER_REPEATS) return null;
  const ceiling = Math.floor(buffer.length / TRIGGER_REPEATS);
  for (let L = MIN_REPEAT_LEN; L <= ceiling; L++) {
    const last = buffer.slice(-L);
    let ok = true;
    for (let r = 1; r < TRIGGER_REPEATS; r++) {
      if (buffer.slice(-(r + 1) * L, -r * L) !== last) {
        ok = false;
        break;
      }
    }
    if (ok) return { length: L, sample: last };
  }
  return null;
}

function pickGenText(obj) {
  if (typeof obj.response === "string") return obj.response;
  if (obj.message && typeof obj.message.content === "string") return obj.message.content;
  if (typeof obj.thinking === "string") return obj.thinking;
  return "";
}

const server = http.createServer((req, res) => {
  const isStreamCandidate = req.method === "POST" && STREAM_PATHS.has(req.url.split("?")[0]);
  const proxyReq = http.request(
    {
      host: UPSTREAM_HOST,
      port: UPSTREAM_PORT,
      method: req.method,
      path: req.url,
      headers: { ...req.headers, host: `${UPSTREAM_HOST}:${UPSTREAM_PORT}` },
    },
    (proxyRes) => {
      res.writeHead(proxyRes.statusCode || 502, proxyRes.headers);

      if (!isStreamCandidate) {
        proxyRes.pipe(res);
        return;
      }

      let leftover = "";
      let acc = "";
      let nextCheckAt = CHECK_EVERY;
      let aborted = false;

      proxyRes.on("data", (chunk) => {
        if (aborted) return;
        // Pass the chunk to the client immediately so latency is unaffected.
        res.write(chunk);

        const text = leftover + chunk.toString("utf8");
        const lines = text.split("\n");
        leftover = lines.pop() ?? "";
        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed) continue;
          let obj;
          try {
            obj = JSON.parse(trimmed);
          } catch {
            continue;
          }
          const piece = pickGenText(obj);
          if (!piece) continue;
          acc += piece;
        }

        if (acc.length > WINDOW_CHARS) acc = acc.slice(-WINDOW_CHARS);

        if (acc.length >= nextCheckAt) {
          nextCheckAt = acc.length + CHECK_EVERY;
          const hit = detectRepeat(acc);
          if (hit) {
            aborted = true;
            const errPayload = {
              error: `loop-guard: detected a ${hit.length}-char chunk repeating ${TRIGGER_REPEATS}+ times`,
              done: true,
              done_reason: "loop_guard_abort",
            };
            try {
              res.write(JSON.stringify(errPayload) + "\n");
            } catch (_) {}
            try {
              res.end();
            } catch (_) {}
            try {
              proxyReq.destroy();
            } catch (_) {}
            try {
              proxyRes.destroy();
            } catch (_) {}
            const sample = hit.sample.replace(/\s+/g, " ").slice(0, 80);
            console.error(
              `[ollama-loop-guard] aborted ${req.method} ${req.url} after ${acc.length} chars; ` +
                `${hit.length}-char chunk x${TRIGGER_REPEATS} = ${JSON.stringify(sample)}`
            );
          }
        }
      });

      proxyRes.on("end", () => {
        if (!aborted) res.end();
      });
      proxyRes.on("error", () => {
        if (!aborted) {
          try {
            res.end();
          } catch (_) {}
        }
      });
    }
  );

  proxyReq.on("error", (err) => {
    console.error(`[ollama-loop-guard] upstream error: ${err.message}`);
    if (!res.headersSent) {
      res.writeHead(502, { "content-type": "application/json" });
    }
    try {
      res.end(JSON.stringify({ error: `loop-guard upstream error: ${err.message}` }));
    } catch (_) {}
  });

  req.pipe(proxyReq);
});

server.on("error", (err) => {
  console.error(`[ollama-loop-guard] listen error: ${err.message}`);
  process.exit(1);
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  console.log(
    `[ollama-loop-guard] listening on ${LISTEN_HOST}:${LISTEN_PORT} -> ${UPSTREAM_HOST}:${UPSTREAM_PORT} ` +
      `(window=${WINDOW_CHARS}, minLen=${MIN_REPEAT_LEN}, repeats=${TRIGGER_REPEATS})`
  );
});
