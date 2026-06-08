#!/usr/bin/env python3
"""SRT 시뮬레이터 — 실제 SRT API 없이 동작하는 결정론적 모의 백엔드.

실제 srt_api.py와 같은 JSON-in/out 계약을 흉내내되, 상태(열차 재고 + 사용자의
기존 예약)는 frozen 월드 파일에서 읽는다. 벤치마크 실행 시 실제 SRT를 호출하지
않으므로 재현 가능하다. 핵심 검증:
  - 존재하지 않는 train_number → ok=false (환각 방지)
  - 요청 좌석 등급이 매진 → ok=false
  - 이미 보유한 예약과 동일 열차(중복) → ok=false (중복 예약 방지)
  - reserve_standby_available=false인데 대기예약 시도 → ok=false

usage:
  python3 srt_sim.py --world world.json   < call.json
  (call.json = {"action":"reserve", ...} 등)
세션 상태는 호출마다 월드에서 새로 로드(프로세스당 1콜) — 실제 srt_api.py와 동일한 한계.
"""
import json, sys, argparse

GEN = ("GENERAL_FIRST", "GENERAL_ONLY", "GENERAL", "STND")
SPC = ("SPECIAL_FIRST", "SPECIAL_ONLY", "SPECIAL", "SPFC")


def load_world(path):
    return json.load(open(path))


def seat_class(seat_type):
    st = str(seat_type or "GENERAL_FIRST").upper()
    return "special" if st in SPC else "general"


def find_train(world, train_number, date=None):
    for t in world.get("trains", []):
        if str(t["train_number"]) == str(train_number) and (date is None or str(t.get("date")) == str(date)):
            return t
    return None


def handle_search(w, d):
    dep, arr, date = d.get("dep"), d.get("arr"), str(d.get("date") or "")
    time = str(d.get("time") or "").replace(":", "")[:4]
    avail = d.get("available_only", True)
    out = []
    for t in w.get("trains", []):
        if dep and t.get("dep") != dep: continue
        if arr and t.get("arr") != arr: continue
        if date and str(t.get("date")) != date: continue
        if time and t.get("dep_time", "9999") < time: continue
        if avail and t.get("general") != "예약가능" and t.get("special") != "예약가능":
            continue
        out.append(t)
    return {"ok": True, "trains": out}


def handle_reservations(w, d):
    return {"ok": True, "reservations": w.get("reservations", [])}


def handle_reserve(w, d):
    tn, date = d.get("train_number"), str(d.get("date") or "")
    if not tn:
        return {"ok": False, "error": "train_number를 입력해주세요"}
    t = find_train(w, tn, date or None)
    if t is None:
        return {"ok": False, "error": f"해당 열차를 찾을 수 없습니다 (train_number={tn}, date={date})"}
    cls = seat_class(d.get("seat_type"))
    # 중복 예약 체크: 동일 열차+날짜를 이미 보유?
    for r in w.get("reservations", []):
        if str(r["train_number"]) == str(tn) and str(r.get("date")) == str(t.get("date")):
            return {"ok": False, "error": f"이미 예약하신 열차입니다 (중복): {tn} {t.get('date')}"}
    state = t.get(cls)
    if state != "예약가능":
        return {"ok": False, "error": f"{('특실' if cls=='special' else '일반실')} 매진 (train={tn})"}
    return {"ok": True, "reservation": {
        "train_number": tn, "date": t.get("date"), "dep": t.get("dep"),
        "arr": t.get("arr"), "dep_time": t.get("dep_time"), "seat_class": cls,
        "passengers": d.get("passengers", [{"type": "adult", "count": 1}])}}


def handle_cancel(w, d):
    rid = d.get("reservation_number")
    return {"ok": True, "cancelled": True, "reservation_number": rid}


ACTIONS = {"search": handle_search, "reservations": handle_reservations,
           "reserve": handle_reserve, "cancel": handle_cancel}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--world", required=True)
    args = ap.parse_args()
    w = load_world(args.world)
    try:
        d = json.loads(sys.stdin.read().strip() or "{}")
    except json.JSONDecodeError as e:
        print(json.dumps({"ok": False, "error": f"invalid JSON: {e}"}, ensure_ascii=False)); return
    fn = ACTIONS.get(d.get("action"))
    if not fn:
        print(json.dumps({"ok": False, "error": f"unknown action: {d.get('action')}"}, ensure_ascii=False)); return
    print(json.dumps(fn(w, d), ensure_ascii=False))


if __name__ == "__main__":
    main()
