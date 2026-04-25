#!/usr/bin/env python3
"""SRT 라이브러리 래핑 API 스크립트.

JSON-in / JSON-out 방식. stdin에서 JSON 받고 stdout으로 JSON 출력.
Depends on the PyPI package SRTrain (installed in the kclawbox image).

Usage:
  echo '{"action":"search","dep":"평택지제","arr":"수서","date":"20260428"}' | python3 srt_api.py
  echo '{"action":"login","id":"xxx","pw":"xxx"}' | python3 srt_api.py
  echo '{"action":"reserve","dep":"평택지제","arr":"수서","date":"20260428","train_number":"301"}' | python3 srt_api.py
"""
import json
import os
import sys
from datetime import datetime

from SRT import SRT, Adult, Child, SeatType

# English-to-Korean station alias map. SRTrain only accepts the Korean
# names from SRT.constants.STATION_CODE; this lets the agent pass either
# form. Match the names exposed in references/stations.md.
STATION_ALIAS = {
    "suseo": "수서",
    "dongtan": "동탄",
    "pyeongtaekjije": "평택지제",
    "cheonanasan": "천안아산",
    "osong": "오송",
    "daejeon": "대전",
    "gimcheongumi": "김천(구미)",
    "dongdaegu": "동대구",
    "gyeongju": "경주",
    "singyeongju": "신경주",
    "ulsan": "울산(통도사)",
    "ulsantongdosa": "울산(통도사)",
    "busan": "부산",
    "gongju": "공주",
    "iksan": "익산",
    "jeongeup": "정읍",
    "gwangjusongjeong": "광주송정",
    "naju": "나주",
    "mokpo": "목포",
    "pohang": "포항",
    "yeosuexpo": "여수EXPO",
    "yeocheon": "여천",
    "suncheon": "순천",
    "namwon": "남원",
    "gokseong": "곡성",
    "guryegu": "구례구",
    "jeonju": "전주",
    "jinju": "진주",
    "miryang": "밀양",
    "masan": "마산",
    "changwon": "창원",
    "changwonjungang": "창원중앙",
    "jinyeong": "진영",
    "seodaegu": "서대구",
}

SEAT_TYPE_MAP = {
    "GENERAL_FIRST": SeatType.GENERAL_FIRST,
    "GENERAL_ONLY": SeatType.GENERAL_ONLY,
    "SPECIAL_FIRST": SeatType.SPECIAL_FIRST,
    "SPECIAL_ONLY": SeatType.SPECIAL_ONLY,
    # Friendly aliases:
    "GENERAL": SeatType.GENERAL_FIRST,
    "SPECIAL": SeatType.SPECIAL_FIRST,
    "STND": SeatType.GENERAL_FIRST,
    "SPFC": SeatType.SPECIAL_FIRST,
}


def normalize_station(name):
    if not name:
        return name
    key = name.replace(" ", "").replace("-", "").replace("_", "").lower()
    return STATION_ALIAS.get(key, name)


def normalize_date(date):
    if not date:
        return datetime.now().strftime("%Y%m%d")
    return str(date).replace("-", "")[:8]


def serialize_train(t):
    return {
        "train_code": t.train_code,
        "train_name": t.train_name,
        "train_number": t.train_number,
        "dep_date": t.dep_date,
        "dep_time": t.dep_time,
        "dep_station_name": t.dep_station_name,
        "arr_date": getattr(t, "arr_date", None),
        "arr_time": t.arr_time,
        "arr_station_name": t.arr_station_name,
        "general_seat_state": t.general_seat_state,
        "special_seat_state": t.special_seat_state,
        "general_seat_available": t.general_seat_available(),
        "special_seat_available": t.special_seat_available(),
        "reserve_standby_available": t.reserve_standby_available(),
    }


def serialize_reservation(r):
    return {
        "reservation_number": r.reservation_number,
        "train_code": r.train_code,
        "train_name": r.train_name,
        "train_number": r.train_number,
        "dep_date": r.dep_date,
        "dep_time": r.dep_time,
        "dep_station_name": r.dep_station_name,
        "arr_time": r.arr_time,
        "arr_station_name": r.arr_station_name,
        "total_cost": r.total_cost,
        "seat_count": r.seat_count,
        "paid": r.paid,
        "payment_date": r.payment_date,
        "payment_time": r.payment_time,
    }


# 글로벌 SRT 인스턴스
_srt_instance = None


def get_srt():
    global _srt_instance
    if _srt_instance is None:
        srt_id = os.environ.get("SRT_ID") or ""
        srt_pw = os.environ.get("SRT_PW") or ""
        _srt_instance = SRT(srt_id, srt_pw, auto_login=False)
    return _srt_instance


def handle_login(data):
    srt = get_srt()
    srt_id = data.get("id") or os.environ.get("SRT_ID")
    srt_pw = data.get("pw") or os.environ.get("SRT_PW")
    if not srt_id or not srt_pw:
        return {"ok": False, "error": "id와 pw를 입력해주세요"}
    srt.login(srt_id, srt_pw)
    return {"ok": True, "message": "로그인 성공"}


def handle_search(data):
    srt = get_srt()
    dep = normalize_station(data.get("dep"))
    arr = normalize_station(data.get("arr"))
    date = normalize_date(data.get("date"))
    time = data.get("time")  # "HHMM" or "HH:MM"
    if time:
        time = str(time).replace(":", "")[:6].ljust(6, "0")
    available_only = data.get("available_only", True)

    if not dep or not arr:
        return {"ok": False, "error": "dep와 arr를 입력해주세요"}

    trains = srt.search_train(dep, arr, date=date, time=time, available_only=available_only)
    return {"ok": True, "trains": [serialize_train(t) for t in trains]}


def _parse_passengers(passengers_input):
    psgr_list = []
    if not passengers_input:
        passengers_input = [{"type": "adult", "count": 1}]
    for p in passengers_input:
        ptype = p.get("type", "adult")
        count = int(p.get("count", 1))
        if ptype == "child":
            psgr_list.extend(Child() for _ in range(count))
        else:
            psgr_list.extend(Adult() for _ in range(count))
    return psgr_list


def _find_train(srt, dep, arr, date, train_number, time=None):
    trains = srt.search_train(dep, arr, date=date, time=time, available_only=False)
    for t in trains:
        if str(t.train_number) == str(train_number):
            return t
    return None


def handle_reserve(data):
    srt = get_srt()
    dep = normalize_station(data.get("dep"))
    arr = normalize_station(data.get("arr"))
    date = normalize_date(data.get("date"))
    train_number = data.get("train_number")
    time = data.get("time")
    if time:
        time = str(time).replace(":", "")[:6].ljust(6, "0")
    seat_type_key = str(data.get("seat_type", "GENERAL_FIRST")).upper()
    seat_type = SEAT_TYPE_MAP.get(seat_type_key, SeatType.GENERAL_FIRST)
    passengers = _parse_passengers(data.get("passengers"))

    if not dep or not arr or not train_number:
        return {"ok": False, "error": "dep, arr, train_number를 입력해주세요"}

    train = _find_train(srt, dep, arr, date, train_number, time=time)
    if train is None:
        return {"ok": False, "error": f"해당 열차를 찾을 수 없습니다 (train_number={train_number}, {dep}->{arr}, {date})"}

    reservation = srt.reserve(train, passengers=passengers, special_seat=seat_type)
    return {"ok": True, "reservation": serialize_reservation(reservation)}


def handle_reservations(data):
    srt = get_srt()
    paid_only = bool(data.get("paid_only", False))
    reservations = srt.get_reservations(paid_only=paid_only)
    return {"ok": True, "reservations": [serialize_reservation(r) for r in reservations]}


def handle_cancel(data):
    srt = get_srt()
    rid = data.get("reservation_number") or data.get("resno") or data.get("reservation")
    if rid is None:
        return {"ok": False, "error": "reservation_number를 입력해주세요"}
    try:
        rid_int = int(rid)
    except (TypeError, ValueError):
        return {"ok": False, "error": f"reservation_number는 정수여야 합니다 (got {rid!r})"}
    cancelled = srt.cancel(rid_int)
    return {"ok": True, "cancelled": bool(cancelled)}


# 액션 매핑
ACTIONS = {
    "login": handle_login,
    "search": handle_search,
    "reserve": handle_reserve,
    "reservations": handle_reservations,
    "cancel": handle_cancel,
}


def main():
    try:
        raw = sys.stdin.read().strip()
        if not raw:
            print(json.dumps({"ok": False, "error": "empty input"}))
            return
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        print(json.dumps({"ok": False, "error": f"invalid JSON: {e}"}))
        return

    action = data.get("action")
    if action not in ACTIONS:
        print(json.dumps({"ok": False, "error": f"unknown action: {action}"}))
        return

    try:
        result = ACTIONS[action](data)
    except Exception as e:  # surface SRT library errors as ok=false instead of stack trace
        result = {"ok": False, "error": f"{type(e).__name__}: {e}"}

    print(json.dumps(result, ensure_ascii=False, default=str))


if __name__ == "__main__":
    main()
