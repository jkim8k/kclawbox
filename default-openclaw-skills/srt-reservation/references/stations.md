# Station Notes

Every station listed here is a confirmed SRT (수서고속철도) station. Do not tell the user that any of these stations is "not served by SRT". If you are unsure, verify with `srt_api.py` (a `search` call is enough) before correcting the user.

## Canonical Names For srt_api.py

`srt_api.py` accepts the canonical Korean station name. The wrapper also accepts a small set of English aliases (case-insensitive, ignoring spaces/dashes), but Korean is the safest input. When a user types in English, prefer to pass the matching Korean name to the API.

| Korean (canonical) | English alias |
| --- | --- |
| 수서 | Suseo |
| 동탄 | Dongtan |
| 평택지제 | PyeongtaekJije |
| 천안아산 | CheonanAsan |
| 오송 | Osong |
| 공주 | Gongju |
| 대전 | Daejeon |
| 김천(구미) | GimcheonGumi |
| 서대구 | Seodaegu |
| 동대구 | Dongdaegu |
| 신경주 | SinGyeongju |
| 경주 | Gyeongju |
| 울산(통도사) | Ulsan / UlsanTongdosa |
| 부산 | Busan |
| 익산 | Iksan |
| 정읍 | Jeongeup |
| 광주송정 | GwangjuSongjeong |
| 나주 | Naju |
| 목포 | Mokpo |
| 포항 | Pohang |
| 여수EXPO | YeosuExpo |
| 여천 | Yeocheon |
| 순천 | Suncheon |
| 남원 | Namwon |
| 곡성 | Gokseong |
| 구례구 | Guryegu |
| 전주 | Jeonju |
| 진주 | Jinju |
| 밀양 | Miryang |
| 마산 | Masan |
| 창원 | Changwon |
| 창원중앙 | ChangwonJungang |
| 진영 | Jinyeong |

## Normalization Rules

- Keep the user's intended station, but disambiguate when a city has multiple rail stations.
- If the user says only a city name and that is ambiguous, ask which station they want.
- For round-trip plans, confirm whether the return station pair is the exact reverse of the outbound trip.
- When you call `srt_api.py`, prefer the Korean form from this table to avoid alias drift.
