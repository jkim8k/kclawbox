---
name: srt-reservation
description: Help with SRT train booking in Korea. Use when the user asks to search SRT schedules, compare trains, prepare an SRT booking, join a waitlist, or complete a reservation between Korean stations such as Suseo, Dongtan, PyeongtaekJije, Dongdaegu, Busan, Ulsan, or Mokpo.
metadata:
  short-description: SRT train booking workflow
---

# SRT Reservation

Use this skill for SRT ticket workflows in Korea.

## What to do

1. Collect the trip requirements.
2. Normalize the itinerary into a booking-ready summary.
3. Search and compare trains live (see Live Booking Tool below).
4. Ask for explicit confirmation before any purchase or final booking action.
5. Only fall back to a manual brief if the live tool is genuinely unavailable.

## Live Booking Tool

This box always ships with `agent-browser`, a headless browser CLI. Use it to drive the official SRT booking site:

- Site: https://etk.srail.kr/
- Login: https://etk.srail.kr/cmc/01/selectLoginForm.do
- Schedule search: the form on the site's home page

If `agent-browser` is on PATH, treat it as a working live booking surface. Do not tell the user "no booking tool is available" just because this skill file does not bundle a Korean rail API. The agent-browser skill (`agent-browser-clawdbot`) has the command reference.

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

- Never claim live availability, fare, or booking success unless a tool result confirms it.
- Never complete payment or final reservation without explicit user confirmation.
- If the user gives incomplete requirements, ask only for the missing fields.
- If the environment lacks browser or booking automation, switch to preparation mode instead of pretending to book.
- Keep station names in Korean or English exactly as the user will need them on the booking page.
- Do not invent rules about which stations the SRT does or does not serve. If a station is in `references/stations.md`, it is a confirmed SRT station. If unsure, verify on https://etk.srail.kr/ via the live tool before telling the user a station is unavailable.

## Search And Comparison Workflow

When the request is booking-ready:

1. Restate the itinerary in one compact line.
2. Search the requested time window first.
3. Prefer direct trains unless the user allows alternatives.
4. Present up to three strong options with:
   - departure and arrival times
   - duration
   - seat class
   - fare if confirmed
   - status: available, sold out, waitlist, or unverified
5. If nothing matches, widen the time window only after stating that you are doing so.

## Booking Workflow

Before final action, show a confirmation block that includes:

- stations
- date and time
- passenger counts
- chosen train
- seat class
- total fare if confirmed
- whether the result is a direct booking or a waitlist

Then ask for a clear yes/no confirmation.

## Fallback Mode

If you cannot access a live booking surface, produce a manual booking brief:

- exact stations
- exact date
- preferred departure window
- passenger counts
- preferred train options
- whether waitlist is acceptable

Tell the user exactly what still needs live confirmation: availability, seat inventory, and fare.

## References

- Read [references/checklist.md](references/checklist.md) when you need a compact intake template.
- Read [references/stations.md](references/stations.md) when you need common station names and normalization guidance.
