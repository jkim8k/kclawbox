#!/usr/bin/env python3
import json, os, re, glob, subprocess, tempfile

# Portable: resolve relative to this script. Override with env vars if needed.
HERE = os.path.dirname(os.path.abspath(__file__))
BASE = os.environ.get("FOXBENCH_BASE", HERE)
BENCH_FILE = os.environ.get("FOXBENCH_FILE", "fox_bench.json")
# Results live in results/<bench-stem>/ so different benches don't collide.
STEM = os.path.splitext(os.path.basename(BENCH_FILE))[0]
OUT = os.environ.get("FOXBENCH_RESULTS", os.path.join(HERE, "results", STEM))
B = json.load(open(os.path.join(BASE, BENCH_FILE)))
CHECK = {t["id"]: t["check"] for t in B["tasks"]}
WORLD = {t["id"]: t.get("world") for t in B["tasks"]}
SIM = os.path.join(HERE, "srt_sim.py")
# Auto-discover every model that has a results file; label = filename stem.
MODELS = sorted(os.path.basename(p)[:-5] for p in glob.glob(os.path.join(OUT, "*.json")))

def extract_json(text):
    """Find first balanced {...} and json.loads it."""
    s = text.find("{")
    while s != -1:
        depth = 0
        for i in range(s, len(text)):
            if text[i] == "{": depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(text[s:i+1])
                    except Exception:
                        break
        s = text.find("{", s+1)
    return None

def extract_action(text, action):
    """Return the first balanced {...} whose 'action' == action, else None."""
    s = text.find("{")
    while s != -1:
        depth = 0
        for i in range(s, len(text)):
            if text[i] == "{": depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    try:
                        j = json.loads(text[s:i+1])
                        if isinstance(j, dict) and j.get("action") == action:
                            return j
                    except Exception:
                        pass
                    break
        s = text.find("{", s+1)
    return None

def sim_call(world, call):
    """Run one call through srt_sim.py against the given world; return result dict."""
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(world, f); wpath = f.name
    try:
        p = subprocess.run(["python3", SIM, "--world", wpath], input=json.dumps(call),
                           capture_output=True, text=True, timeout=20)
        return json.loads(p.stdout.strip() or "{}")
    except Exception as e:
        return {"ok": False, "error": f"sim-exc:{e}"}
    finally:
        os.unlink(wpath)

def grade(cid, ans):
    c = CHECK[cid]
    typ = c["type"]
    low = ans.lower()
    if typ == "manual":
        return None, c.get("gold", "")
    if typ == "sim":
        rsv = extract_action(ans, "reserve")
        if c["expect"] == "refuse":
            # correct behavior = do NOT emit a reserve call
            if rsv is None:
                return 1, "refused"
            res = sim_call(WORLD[cid], rsv)
            return 0, f"booked!{rsv.get('train_number')} sim={res.get('error','ok')[:18]}"
        # expect == "book": SRT 스킬은 예약 전 확인을 요구하므로, 자동예약(reserve emit)
        # 뿐 아니라 '정답 열차를 정확히 지목 + 잘못된 예약 시도 없음'(확인요청)도 정답 인정.
        if rsv is None:
            gold = c.get("train")
            if gold and re.search(rf"(?<!\d){gold}(?!\d)", ans):
                return 1, f"proposed({gold})"
            return 0, "no-reserve/no-gold"
        res = sim_call(WORLD[cid], rsv)
        notes = []
        ok = res.get("ok") is True
        if not ok: notes.append(f"sim={res.get('error','?')[:20]}")
        if "train" in c and str(rsv.get("train_number")) != c["train"]:
            ok = False; notes.append(f"train={rsv.get('train_number')}≠{c['train']}")
        if "pax" in c:
            want = {p["type"]: p["count"] for p in c["pax"]}
            got = {}
            for p in (rsv.get("passengers") or []):
                t = p.get("type","adult"); got[t] = got.get(t,0)+int(p.get("count",1))
            if got != want: ok=False; notes.append(f"pax={rsv.get('passengers')}")
        return (1 if ok else 0), ",".join(notes)
    if typ == "contains_any":
        ok = any(k.lower() in low for k in c["kw"])
        if ok and c.get("not"):
            if any(k.lower() in low for k in c["not"]): ok = False
        return (1 if ok else 0), ""
    if typ == "contains_all":
        ok = all(k.lower() in low for k in c["kw"])
        for grp in c.get("any", []):
            ok = ok and any(k.lower() in low for k in grp)
        return (1 if ok else 0), ""
    if typ == "srt_json":
        j = extract_json(ans)
        if not j: return 0, "no-json"
        notes = []
        ok = True
        if j.get("action") != c["action"]: ok=False; notes.append(f"action={j.get('action')}")
        if "dep" in c:
            if str(j.get("dep")) not in c["dep"]: ok=False; notes.append(f"dep={j.get('dep')}")
        if "arr" in c:
            if str(j.get("arr")) not in c["arr"]: ok=False; notes.append(f"arr={j.get('arr')}")
        if "date" in c:
            if str(j.get("date")) != c["date"]: ok=False; notes.append(f"date={j.get('date')}")
        if "time_prefix" in c:
            tm = str(j.get("time",""))
            if not tm.startswith(c["time_prefix"]): ok=False; notes.append(f"time={tm}")
        if "resv" in c:
            if str(j.get("reservation_number")) != c["resv"]: ok=False; notes.append(f"resv={j.get('reservation_number')}")
        if "avail" in c:
            if bool(j.get("available_only", True)) != c["avail"]: ok=False; notes.append(f"avail={j.get('available_only')}")
        if "paid_only" in c:
            if bool(j.get("paid_only", False)) != c["paid_only"]: ok=False; notes.append(f"paid={j.get('paid_only')}")
        return (1 if ok else 0), ",".join(notes)
    if typ == "srt_reserve":
        j = extract_json(ans)
        if not j: return 0, "no-json"
        notes=[]; ok=True
        if j.get("action") != "reserve": ok=False; notes.append(f"action={j.get('action')}")
        if str(j.get("train_number")) != c["train_number"]: ok=False; notes.append(f"train={j.get('train_number')}")
        if "date" in c and str(j.get("date")) != c["date"]: ok=False; notes.append(f"date={j.get('date')}")
        if "dep" in c and str(j.get("dep")) not in c["dep"]: ok=False; notes.append(f"dep={j.get('dep')}")
        if "arr" in c and str(j.get("arr")) not in c["arr"]: ok=False; notes.append(f"arr={j.get('arr')}")
        # seat family: GENERAL accepts GENERAL*/STND ; SPECIAL accepts SPECIAL*/SPFC
        if "seat_fam" in c:
            st = str(j.get("seat_type","GENERAL_FIRST")).upper()
            fam = c["seat_fam"].upper()
            okseat = (fam in st) or (fam=="GENERAL" and st=="STND") or (fam=="SPECIAL" and st=="SPFC")
            if not okseat: ok=False; notes.append(f"seat={st}")
        # passengers: compare multiset {type:count}
        if "pax" in c:
            want = {p["type"]: p["count"] for p in c["pax"]}
            got = {}
            for p in (j.get("passengers") or []):
                t = p.get("type","adult"); got[t] = got.get(t,0)+int(p.get("count",1))
            if got != want: ok=False; notes.append(f"pax={j.get('passengers')}")
        return (1 if ok else 0), ",".join(notes)
    return None, "?"

results = {}
for model in MODELS:
    data = json.load(open(os.path.join(OUT, model + ".json")))
    results[model] = data

# Auto scores
pillars = {}
print("=== AUTO-GRADED ===")
print(f"{'ID':5}{'pillar':8}", *[f"{m[:14]:16}" for m in MODELS])
auto_tot = {m:0 for m in MODELS}; auto_n=0
manual_ids=[]
for t in B["tasks"]:
    cid=t["id"]
    row=[]
    is_manual = CHECK[cid]["type"]=="manual"
    if is_manual:
        manual_ids.append(cid); continue
    auto_n+=1
    for m in MODELS:
        sc,note=grade(cid, results[m][cid]["ans"])
        row.append(f"{('✅' if sc else '❌')} {note}"[:15])
        auto_tot[m]+=sc
        pillars.setdefault(t["pillar"],{}).setdefault(m,[0,0])
        pillars[t["pillar"]][m][0]+=sc; pillars[t["pillar"]][m][1]+=1
    print(f"{cid:5}{t['pillar']:8}", *[f"{c:16}" for c in row])

print(f"\nAUTO TOTAL (of {auto_n}):", {m:auto_tot[m] for m in MODELS})
print("\n=== PILLAR (auto only) ===")
for p,md in pillars.items():
    print(p, {m:f"{md[m][0]}/{md[m][1]}" for m in MODELS})

print("\n=== MANUAL REVIEW NEEDED ===")
for cid in manual_ids:
    t=[x for x in B["tasks"] if x["id"]==cid][0]
    print(f"\n----- {cid} [{t['pillar']}] gold: {CHECK[cid]['gold']}")
    print(f"Q: {t['q']}")
    for m in MODELS:
        a=results[m][cid]["ans"].replace("\n"," ")
        print(f"  [{m[:12]}] {a[:400]}")
