---
name: srt-reservation
description: Help with SRT train booking in Korea. Use when the user asks to search SRT schedules, compare trains, prepare an SRT booking, join a waitlist, or complete a reservation between Korean stations such as Suseo, Dongtan, PyeongtaekJije, Dongdaegu, Busan, Ulsan, or Mokpo.
metadata:
  short-description: SRT train booking workflow (drives the SRTrain Python wrapper)
---

# SRT Reservation

Use this skill for SRT ticket workflows in Korea.

## Important: This Skill Is Not Self-Contained

**SKILL.md alone cannot run an SRT booking.** This is a tool-driven skill. It depends on:

- the PyPI package `SRTrain` (installed in the kclawbox image at build time)
- the helper script that ships next to this file: `srt_api.py`
- the user's own SRT account credentials (`SRT_ID` and `SRT_PW`, never invented)

Do not attempt to satisfy a booking request by reasoning out timetables, fares, or seat counts from memory. Always go through `srt_api.py`. If the script is missing or `SRTrain` is not importable, switch to fallback mode and tell the user the runtime is broken.

## Live Booking Tool: srt_api.py

`srt_api.py` is a JSON-in / JSON-out CLI you drive via shell:

```bash
echo '<json>' | python3 "$(dirname this skill's SKILL.md)/srt_api.py"
```

In runtime the absolute path is typically `/data/openclaw/.openclaw/workspace/skills/srt-reservation/srt_api.py`. Verify with `ls` before the first call.

### Actions

`login` - authenticate with SRT credentials. Required before reserve / reservations / cancel.
```json
{"action":"login","id":"<srt_id>","pw":"<srt_password>"}
```
If `id`/`pw` are omitted, the script falls back to env vars `SRT_ID` / `SRT_PW`.

`search` - list trains. `dep` and `arr` are Korean station names (the SRTrain library only accepts Korean; the wrapper also accepts a small English alias set listed in `references/stations.md`). `time` is `HHMM` and acts as a lower bound (the API returns trains at or after that minute).
```json
{"action":"search","dep":"평택지제","arr":"수서","date":"20260428","time":"0758","available_only":true}
```
Returns `{ok, trains:[{train_number, train_name, dep_date, dep_time, dep_station_name, arr_time, arr_station_name, general_seat_state, special_seat_state, general_seat_available, special_seat_available, reserve_standby_available}, ...]}`.

`reserve` - book a specific train. Identify the train via `train_number` (and the same `dep`/`arr`/`date` you used for search; the wrapper re-runs the search internally to obtain a fresh train object).
```json
{"action":"reserve","dep":"평택지제","arr":"수서","date":"20260428","train_number":"301","seat_type":"GENERAL_FIRST","passengers":[{"type":"adult","count":1}]}
```
`seat_type` is one of `GENERAL_FIRST` (default - take a general seat, fall back to special), `GENERAL_ONLY`, `SPECIAL_FIRST`, `SPECIAL_ONLY`. The aliases `GENERAL`, `SPECIAL`, `STND`, `SPFC` are also accepted.

Returns `{ok, reservation:{reservation_number, train_name, dep_date, dep_time, dep_station_name, arr_time, arr_station_name, total_cost, seat_count, paid, payment_date, payment_time}}`. The `reservation_number` is what you pass to `cancel`.

`reservations` - list current reservations.
```json
{"action":"reservations","paid_only":false}
```

`cancel` - cancel a reservation by `reservation_number`.
```json
{"action":"cancel","reservation_number":12345678}
```

### Error Shape

Every action returns either `{"ok": true, ...}` or `{"ok": false, "error": "<message>"}`. Treat `ok=false` as a hard failure - report the error verbatim, do not retry blindly.

## Workflow

1. Collect the trip requirements (see Required Trip Inputs).
2. Normalize the itinerary into a booking-ready summary.
3. Verify `srt_api.py` exists; verify `SRTrain` imports (a single dry `search` call is enough).
4. If SRT login is needed for the requested action, ensure the user has provided credentials. Never invent or guess credentials.
5. Search → present options → confirm with user → reserve.
6. Show a final confirmation block with the reservation result.

## Required Trip Inputs

Collect these before treating the request as booking-ready:

- trip type: one-way or round-trip
- departure station
- arrival station
- departure date
- departure time window
- passenger counts

Ask for these when relevant:

- preferred seat class: standard or first/special
- seat preferences: aisle/window, quiet car, adjacent seats
- flexibility: earlier/later trains, alternate stations, waitlist allowed
- return leg details for round-trip requests

## Operating Rules

- Never claim live availability, fare, or booking success unless `srt_api.py` returned `ok=true` for that exact action.
- Never complete a reservation without explicit user confirmation of the chosen train.
- If the user gives incomplete requirements, ask only for the missing fields.
- Keep station names in Korean or English consistent with `references/stations.md`.
- Do not invent rules about which stations the SRT does or does not serve. Every station listed in `references/stations.md` is a confirmed SRT station.
- Do not store credentials in the conversation transcript. If the user gives them once for a login, use them for that session only.

## Search And Comparison Workflow

When the request is booking-ready:

1. Restate the itinerary in one compact line.
2. Call `search` for the requested time window.
3. Present up to three strong options with:
   - departure and arrival times
   - duration
   - seat class
   - fare
   - status: available, sold out, waitlist, or unverified
4. If nothing matches, widen the time window only after stating that you are doing so.

## Booking Workflow

Before final action, show a confirmation block that includes:

- stations
- date and time
- passenger counts
- chosen train (with `resno` and `pnrno`)
- seat class
- total fare
- whether the result is a direct booking or a waitlist

Then ask for a clear yes/no confirmation and only call `reserve` after.

## Fallback Mode

Only fall back to a manual brief if `srt_api.py` is missing, the `SRTrain` import fails, or the SRT site is genuinely unreachable. In that case produce a manual booking brief:

- exact stations
- exact date
- preferred departure window
- passenger counts
- preferred train options
- whether waitlist is acceptable

Tell the user exactly what is broken (missing script, missing package, network error) so they can fix the runtime instead of accepting a degraded experience.

## References

- Read [references/checklist.md](references/checklist.md) when you need a compact intake template.
- Read [references/stations.md](references/stations.md) when you need common station names and normalization guidance.
