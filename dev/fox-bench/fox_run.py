#!/usr/bin/env python3
import json, urllib.request, time, os, sys

# Portable: paths relative to this script. Override OLLAMA host with FOXBENCH_HOST,
# and which bench to run with FOXBENCH_FILE (default fox_bench.json).
HERE = os.path.dirname(os.path.abspath(__file__))
HOST = os.environ.get("FOXBENCH_HOST", "http://127.0.0.1:11436") + "/api/generate"
BENCH_FILE = os.environ.get("FOXBENCH_FILE", "fox_bench.json")
STEM = os.path.splitext(os.path.basename(BENCH_FILE))[0]
OUT = os.environ.get("FOXBENCH_RESULTS", os.path.join(HERE, "results", STEM))
os.makedirs(OUT, exist_ok=True)
MODELS = sys.argv[1:] if len(sys.argv) > 1 else ["qwen3.6:latest", "gemma4:31b-it-qat"]

B = json.load(open(os.path.join(HERE, BENCH_FILE)))
CTX, TASKS = B["ctx"], B["tasks"]

# Sampling defaults can be overridden to match production. FOXBENCH_OPTS = JSON
# merged into options; FOXBENCH_THINK=1 enables thinking. Production qwen3.6 uses
# temperature 1.0, presence_penalty 1.5, top_p 0.95, top_k 20 (see `ollama show`).
OPTS = {"temperature": 0.2, "num_ctx": 8192}
OPTS.update(json.loads(os.environ.get("FOXBENCH_OPTS", "{}")))
THINK = os.environ.get("FOXBENCH_THINK", "") == "1"

def gen(model, prompt):
    payload = json.dumps({"model": model, "prompt": prompt, "stream": False,
        "think": THINK, "options": OPTS}).encode()
    req = urllib.request.Request(HOST, data=payload, headers={"Content-Type": "application/json"})
    t0 = time.time()
    try:
        r = json.load(urllib.request.urlopen(req, timeout=600))
        ans = r.get("response") or ("ERR:" + str(r.get("error")))
    except Exception as e:
        ans = "EXC:" + str(e)
    return ans, time.time() - t0

for model in MODELS:
    safe = model.replace("/", "_").replace(":", "_")
    res = {}
    for t in TASKS:
        prompt = t["q"]
        if t.get("ctx"):
            prompt = CTX[t["ctx"]] + "\n\n" + t["q"]
        ans, dt = gen(model, prompt)
        res[t["id"]] = {"q": t["q"], "pillar": t["pillar"], "ans": ans, "sec": round(dt, 1)}
        print(f"[{model}] {t['id']} {dt:.0f}s", flush=True)
    json.dump(res, open(os.path.join(OUT, safe + ".json"), "w"), ensure_ascii=False, indent=1)
print("ALL DONE", flush=True)
