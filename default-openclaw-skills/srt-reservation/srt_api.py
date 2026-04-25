#!/usr/bin/env python3
"""SRT 라이브러리 래핑 API 스크립트.

JSON-in / JSON-out 방식. stdin에서 JSON 받고 stdout으로 JSON 출력.
Depends on the PyPI package SRTrain (installed in the kclawbox image).

Usage:
  echo '{"action":"search","dep":"PyeongtaekJije","arr":"Suseo","date":"20260425"}' | python3 srt_api.py
  echo '{"action":"login","id":"xxx","pw":"xxx"}' | python3 srt_api.py
  echo '{"action":"reserve","resno":"12345","pnrno":"67890"}' | python3 srt_api.py
"""
import json
import sys
import os

from SRT import SRT, Adult, Child, SeatType

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
    dep = data.get("dep")
    arr = data.get("arr")
    date = data.get("date")  # yyyyMMdd
    time = data.get("time")  # HH:MM or hhmm
    available_only = data.get("available_only", True)

    if not dep or not arr:
        return {"ok": False, "error": "dep와 arr를 입력해주세요"}

    if date:
        date = date.replace("-", "")[:8]
    else:
        from datetime import datetime
        date = datetime.now().strftime("%Y%m%d")

    trains = srt.search_train(dep, arr, date=date, time=time, available_only=available_only)

    result = []
    for t in trains:
        result.append({
            "no": t.no,
            "dep": t.dep,
            "dep_time": t.dep_time,
            "arr": t.arr,
            "arr_time": t.arr_time,
            "duration": t.duration,
            "total_seat_open_time": t.total_seat_open_time,
            "reservation_total_count": t.reservation_total_count,
            "seat_type": t.seat_type,
            "seat_fare": t.seat_fare,
            "seat_name": t.seat_name,
        })

    return {"ok": True, "trains": result}


def handle_reserve(data):
    srt = get_srt()
    resno = data.get("resno")
    pnrno = data.get("pnrno")
    seat_type = data.get("seat_type", "STND")
    passengers = data.get("passengers", [{"type": "adult", "count": 1}])

    # 승객 파싱
    psgr_list = []
    for p in passengers:
        ptype = p.get("type", "adult")
        count = p.get("count", 1)
        if ptype == "adult":
            for _ in range(count):
                psgr_list.append(Adult())
        elif ptype == "child":
            for _ in range(count):
                psgr_list.append(Child())
        else:
            for _ in range(count):
                psgr_list.append(Adult())

    # 좌석 타입 매핑
    seat_map = {
        "STND": SeatType.STND,
        "SPFC": SeatType.SPFC,
        "STND_ALL": SeatType.STND_ALL,
        "STND_PARTIAL": SeatType.STND_PARTIAL,
        "SPFC_ALL": SeatType.SPFC_ALL,
        "SPFC_PARTIAL": SeatType.SPFC_PARTIAL,
    }
    seat = seat_map.get(seat_type.upper(), SeatType.STND)

    reservation = srt.reserve(resno, pnrno, seat, psgr_list)

    return {
        "ok": True,
        "reservation": {
            "resno": reservation.resno,
            "pnrno": reservation.pnrno,
            "total_price": reservation.total_price,
            "total_seat_count": reservation.total_seat_count,
            "statio": reservation.station,
            "depart_date": reservation.depart_date,
            "depart_time": reservation.depart_time,
            "arrive_date": reservation.arrive_date,
            "arrive_time": reservation.arrive_time,
            "status": reservation.status,
        }
    }


def handle_reservations(data):
    srt = get_srt()
    paid_only = data.get("paid_only", False)
    reservations = srt.get_reservations(paid_only=paid_only)

    result = []
    for r in reservations:
        result.append({
            "resno": r.resno,
            "pnrno": r.pnrno,
            "total_price": r.total_price,
            "total_seat_count": r.total_seat_count,
            "depart_date": r.depart_date,
            "depart_time": r.depart_time,
            "arrive_date": r.arrive_date,
            "arrive_time": r.arrive_time,
            "station": r.station,
            "status": r.status,
            "paid": r.paid,
        })

    return {"ok": True, "reservations": result}


def handle_cancel(data):
    srt = get_srt()
    reservation = data.get("reservation") or data.get("resno")
    if not reservation:
        return {"ok": False, "error": "reservation 또는 resno를 입력해주세요"}
    result = srt.cancel(reservation)
    return {"ok": True, "cancelled": result}


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

    result = ACTIONS[action](data)
    print(json.dumps(result, ensure_ascii=False, default=str))


if __name__ == "__main__":
    main()
