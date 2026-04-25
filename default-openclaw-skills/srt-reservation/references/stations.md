# Station Notes

Use these names consistently in summaries and booking briefs.

Every station in this list is a confirmed SRT (수서고속철도) station. Do not tell the user that any of these stations is "not served by SRT". If you are unsure, verify on https://etk.srail.kr/ before correcting the user.

Common SRT stations users may mention in English:

- Suseo
- Dongtan
- PyeongtaekJije
- CheonanAsan
- Osong
- Daejeon
- GimcheonGumi
- Dongdaegu
- Gyeongju
- Ulsan
- Busan
- Gongju
- Iksan
- Jeongeup
- GwangjuSongjeong
- Naju
- Mokpo

Normalization rules:

- Keep the user's intended station, but disambiguate when a city has multiple rail stations.
- If the user says only a city name and that is ambiguous, ask which station they want.
- For round-trip plans, confirm whether the return station pair is the exact reverse of the outbound trip.
