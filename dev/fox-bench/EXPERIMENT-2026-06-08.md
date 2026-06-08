# 실험 보고서 — 여우 로컬 모델 업그레이드 타당성 & 특화 벤치마크 구축

- **일자**: 2026-06-08
- **대상**: kclawbox-fox 로컬 모델 (현행 `qwen3.6:latest`)
- **질문**: 현재 GPU로 더 좋은 모델을 올릴 수 있나? QAT는? 그리고 그걸 **여우답게** 어떻게 검증하나?
- **결론(요약)**: **현행 qwen3.6 유지.** gemma4 QAT는 교체 이득이 없고(정확도 동급·속도 손해), 다운사이즈(26b)는 SRT 에이전트 실행에서 위험(중복예약·환각). 검증 과정에서 **여우 특화 실행 벤치마크 `fox-bench`를 v0.2까지 구축**(재사용 자산).

---

## 1. 현황 분석 (ground truth)

### 1.1 운영 상태 (`fox-status`)
대부분 PASS. 단 1건 FAIL: `pipe:raw-capture` (rawTurns 0 / sessionTurns 13, 92분 지연). 모델 분석과 별개의 운영 이슈로 분리.

### 1.2 GPU
- **2× RTX 4090 (각 24GB, 총 ~48GB)**.
- 측정 시점 qwen3.6 로드 = 약 36GB(가중치 ~21–23GB + 256K 컨텍스트 KV 캐시 ~13GB), 양 GPU 분산. 유휴 시 언로드(~360MB).
- 여유 ~12–14GB. 다른 컨테이너(cosmos/wan)는 측정 시 GPU 미점유.

### 1.3 현행 모델 정체 (정밀 확인)
`ollama show` + `/api/show` 결과:
- 아키텍처 `qwen35moe`, **36.0B total**, **expert_count 256 / expert_used_count 8 (~3B active)**, block 40, embedding 2048, **vision 포함**, ctx 262144, **Q4_K_M**.
- → **Qwen3.6-35B-A3B 계열 MoE**가 맞음. (사용자가 떠올린 gemma4-26B-A4B 아님.)
- production 샘플링: temperature 1.0, presence_penalty 1.5, top_p 0.95, top_k 20.

---

## 2. QAT 조사

- **QAT(Quantization-Aware Training)**: 학습 중 int4를 시뮬레이션해 4비트로도 BF16 대비 Elo 몇 점 이내 유지. 현행 Q4_K_M(사후 PTQ)보다 같은 4비트에서 손실이 적음. 대표 사례 = Google **Gemma 3/4**(int4로 VRAM 54GB→14GB, 품질 거의 보존).
- **Qwen3.6에는 공식 QAT 빌드 없음** — Qwen은 QAT가 아니라 Unsloth Dynamic 2.0 / imatrix / APEX 같은 PTQ 계열만 제공.
- 따라서 "여우에 QAT 적용" = **계열을 Gemma4로 교체**해야 함:
  - `gemma4:31b-it-qat` (dense, ~18GB, 256K, vision)
  - `gemma4:26b-a4b-it-qat` (MoE 4B active, ~16GB, 256K, vision) — 정확한 태그는 `26b-a4b-it-qat`.
- 벤치 비교상 Qwen3.6가 코딩·에이전트·지식에서 우위, 한국어(CJK)도 통상 Qwen 우세. **QAT의 이점은 "BF16급 품질을 적은 VRAM으로"** → GPU를 비워야 할 때(멀티모델·이미지)의 카드이지, 지금처럼 VRAM 여유 있는 단일 동반자 품질 향상 목적엔 부적합.

---

## 3. 벤치마크 설계의 진화 (왜 이렇게 됐나)

여우를 "여우답게" 평가하려고 4번 갈아엎음. 각 단계가 다음의 결함을 드러냄.

| 단계 | 접근 | 왜 버렸나 |
| --- | --- | --- |
| (폐기) 합성 30문항 | 한국어/추론/요약 일반 QA | "기사요약은 뻔하다" — 여우 특화 아님 |
| v0.1 코어 24 | 실제 스킬(SRT/대토론회/기억/라우팅)의 **tool-call 정합성 + 정직성** | 방향은 맞으나 SRT가 단발 JSON이라 쉬움 |
| v0.1 SRT 단발 20 | 실제 SRT API로 그라운딩(실 열차번호) | 세 모델 ~95% — "현실에선 더럽게 안 되는데?" → **너무 쉬움** |
| (검증) production 샘플링 | temp1.0·presence1.5·think로 재현 | qwen 17/18 — **샘플링 탓 아님, 과제난도 탓** |
| **v0.2 시뮬레이터 + 관측QA** | frozen 월드(재고+기존예약) 위에서 **예약 실행**, 중복·매진·환각 강제 | **드디어 변별됨** |

핵심 통찰: **단발 JSON 작성은 작은 모델도 잘함. 실제로 깨지는 건 멀티스텝 에이전트 실행**(검색결과 소비 → 열차 선택 → 매진/중복/환각 판단). 사용자 요구(① 매번 실 API 호출 금지 ② 시뮬레이션 ③ 중복 예약 방지)를 반영해 `srt_sim.py`(모의 백엔드, frozen 월드)로 **실 API 없이 결정론 채점**.

---

## 4. 결과 (qwen3.6 현행 vs gemma4-31b-qat vs gemma4-26b-a4b-qat)

조건: 여우와 분리한 별도 ollama 0.30.6, 기본 temp 0.2 / think off / ctx 8192. 여우 본체·GPU 무영향.

| 벤치 | 측정 | qwen3.6 (현행) | gemma4-31b-qat | gemma4-26b-a4b-qat |
| --- | --- | --- | --- | --- |
| 코어 (auto 16) | 스킬·정직성 | 13 | 15 | 14 |
| SRT 단발 20 | NL→JSON 작성 | 19 | 20 | 19 |
| SRT 관측-소비 10 | 결과 소비·선택 | 9 | 10 | 8 |
| **SRT 시뮬레이터 10** | **실행·중복·매진·환각** | **10** | **10** | **7** |
| 속도(장문 코어) | — | **3.1s/문항** | 17.3s/문항 | (중간) |
| 속도(SRT 단문) | — | 2.1s | 3.7s | 1.9s |

### 모델별 실패 분석
- **gemma4-26b-a4b (작은 MoE) — 위험한 실패**:
  - 시뮬 SIM1: 보유 중인 657을 **중복 예약** 시도(시뮬레이터 차단).
  - 시뮬 SIM5: OBSERVATION에 없는 **670번 환각** 예약 시도.
  - 시뮬 SIM6 / 관측 O10: **시각 제약 무시**(범위 밖 열차 선택).
- **qwen3.6 (현행)**: 시뮬 10/10. 약점은 ① 영어입력 역명 환각("Suseo"→"서초", 코어 S3) ② 상대시각 상한 무시(관측 O10: 13~17시 '가장 늦은'에서 1908발 선택) ③ 연도 기본값 2024 편향. 모두 **하네스로 보강 가능**(역명 한국어 정규화·날짜 주입은 이미 됨).
- **gemma4-31b**: 가장 안정(시뮬 10/10, 관측 10/10)이나 **장문 5.6배 느림** + 한국어 장황(SOUL "간결" 위반).

### 정직성·환각저항 (여우 최대 리스크)
세 모델 모두 우수: 안 돌린 토론 결과 날조 거부, 없는 혈액형/SRT 자격증명 거부, 403 실패 정직 보고, 전 열차 매진/특실 매진/대기불가를 정확히 거절·대안 제시. **이 축에선 교체 이득 없음.**

---

## 5. 결론 및 권고

1. **현행 `qwen3.6` 유지.** SRT 에이전트 실행(시뮬 10/10)·속도·간결성에서 종합 우위. 교체 동기 없음.
2. **다운사이즈(26b) 금지.** 중복예약·열차 환각 등 SRT에서 실사용 위험.
3. **gemma4 QAT 보류 카드.** GPU를 비워야 할 때(멀티모델·이미지 입력)에만 재검토. 품질 목적 교체는 비권장.
4. **하네스 보강 제안**(모델 교체 대신): ▸SRT 역명 한국어 강제 정규화 ▸SRT 프롬프트에 "오늘 날짜" 명시 ▸상대시각(상한 포함) 파싱을 스킬 측에서 보조.
5. (별건) `pipe:raw-capture` FAIL 점검 필요.

---

## 6. 산출물 & 재현

- **자산**: `dev/fox-bench/` (v0.2) — 벤치 4종(`fox_bench`/`srt_bench`/`srt_obs_bench`/`srt_sim_bench`), 모의 백엔드 `srt_sim.py`, 러너/채점기, 결과 스냅샷. 사용법은 `README.md`.
- **재현**: 별도 ollama(`docker run --gpus all -p 11436:11434 ollama/ollama:latest`)에 모델 받고
  `FOXBENCH_HOST`/`FOXBENCH_FILE` 지정 → `fox_run.py` → `fox_grade.py`. **실 SRT API 미사용**(시뮬레이터로 결정론 채점).
- **데이터 그라운딩**: 문제 작성 시점에만 실 SRT `search`(읽기전용, 무자격증명)로 실 열차번호/매진분포 확보 후 frozen.
- **임시 리소스(미정리)**: `bench-ollama` 컨테이너 + `/tmp/bench-ollama` 모델 복사본(~57GB). 여우 본체 무영향.

## 6.5 단일 GPU 전환 — 분석 반전 & 결정 (2026-06-08 후반)

사용자가 **GPU 1장만 사용**을 요청 → 24GB 제약에서 결론이 뒤집힘. 단일 24GB GPU 실측:

| 모델 @ 컨텍스트 | 적재 | 처리 |
| --- | --- | --- |
| qwen3.6 @ 256K (현행) | 29GB | **19% CPU 오프로드**(느림) |
| qwen3.6 @ 64K | 24GB | 5% CPU 오프로드 |
| qwen3.6 @ 32K | 23GB | 100% GPU (빠듯) |
| gemma4-31b-qat @ 256K | 23GB | 45% CPU 오프로드 |
| gemma4-31b-qat @ 64K | 21GB | 17% CPU 오프로드 |
| **gemma4-31b-qat @ 32K** | **19GB** | **100% GPU (여유 5GB)** |
| gemma4-26b-a4b-qat @ 256K | 15GB | **100% GPU** (단, SRT 시뮬 7/10 위험) |

**반전**: 48GB에선 "qwen 유지"가 답이었으나, **24GB 1장에선 qwen3.6가 256K로 안 들어가 CPU로 샌다**(느려짐). 전부-GPU로 쓰려면 qwen은 ~32K로 줄여야 하고 23/24GB로 빠듯.

**결정 (사용자 지시): `gemma4-31b-qat` 전격 교체 + GPU 1장.**
- 근거: 24GB 1장에서 gemma4-31b-qat는 ~32K 컨텍스트로 **전부-GPU·여유 5GB**, SRT 시뮬 10/10·코어 15/16로 품질도 최상위. 26b는 256K가 들어가지만 에이전트 실행이 위험(7/10).
- 컨텍스트 트레이드오프: 256K→32K(전부-GPU 유지). 텔레그램 동반자 + 기억 회상 주입 기준 32K는 충분.

### 적용 변경 (production)
- `.env`: `OLLAMA_MODEL=gemma4:31b-it-qat`, `CUDA_VISIBLE_DEVICES=0`, `OLLAMA_CONTEXT_LENGTH=32768`
- `docker-compose.yml`: 위 두 env 전달 추가
- ollama: Dockerfile이 최신 tarball 설치 → `docker compose build`로 gemma4 지원 버전 확보(구 0.21.2는 412로 gemma4 pull 불가)
- gemma4 블롭은 여우 볼륨에 사전 복사(부팅 시 18GB 재다운로드 회피)
- 재빌드 + 재생성으로 적용

### 적용 결과 (검증 완료)
- `ollama 0.30.6`, `OLLAMA_MODEL=gemma4:31b-it-qat`, `CUDA_VISIBLE_DEVICES=1`, `OLLAMA_CONTEXT_LENGTH=32768`.
- **GPU0에 blender(2.6GB)+데스크톱이 있어** 거기 핀하면 19% CPU 오프로드 발생 → **디스플레이 없는 GPU1로 핀**해서 해결.
- 실측: `gemma4:31b-it-qat 19GB, 100% GPU, CONTEXT 32768`, GPU1 단독(22.5GB/24GB), GPU0 미사용.
- **`fox-status`: PASS** (서비스·설정핀·L2/L3·크론 전부 녹색, raw-capture도 복구).
- 빌드 이슈: `ollama.com/download` 307→GitHub 리다이렉트가 간헐 504 → Dockerfile ARG를 **버전 고정 GitHub URL(v0.30.6)**로 변경(재현성↑).

## 6.6 후속: 컨텍스트 절단 버그 → **최종 모델 gemma4-26b-a4b-qat**

31b@32K 적용 직후 **대화가 문장 중간에 끊기는** 현상 발생. trajectory 분석으로 원인 확정(타임아웃·루프가드 아님):
- `usage.input=97,273` 토큰을 넣으려 했으나 ollama 호출은 `input 32,672 + output 96 = 32,768`(=`OLLAMA_CONTEXT_LENGTH`)에서 멈춤 → 프롬프트가 잘리고 출력 96토큰 만에 한계 도달.
- 여우 전형 프롬프트(회상+이력+스킬문서)는 **median 60K, 최대 ~160K 토큰** → 32K 캡은 대부분의 턴을 자르는 회귀.

**단일 24GB에서 "풀 컨텍스트 + 전부-GPU"를 동시에 만족하는 건 26b-a4b뿐**(256K=15GB 100% GPU; 31b는 256K=45% 오프로드, qwen은 안 들어감). → **gemma4-26b-a4b-qat로 최종 변경, `OLLAMA_CONTEXT_LENGTH=262144`**.
- 트레이드오프 수용: SRT 시뮬 7/10(에이전트 엣지케이스 약간 위험)이지만, 31b가 매 턴 대화를 자르는 것보다 낫고 풀컨텍스트·전부-GPU·빠름.
- 검증: `gemma4:26b-a4b-it-qat 15GB 100% GPU ctx 262144`, GPU1 단독, `fox-status` PASS.
- 교훈: **컨텍스트 캡은 모델 선택과 분리해 실제 프롬프트 분포로 정해야 한다**(여우는 대용량 컨텍스트 의존).

## 7. 후속 과제 (다음 버전)
- 라우팅 문항에 실제 스킬 카탈로그 주입판(현재는 카탈로그 미제공 → "직감" 평가에 가까움).
- 대토론회 라이브 1회 완주 채점(manifest verified) 추가.
- 멀티턴 에이전트 루프판(현재는 단일턴 + 시뮬레이터 실행 채점).
- 주관 문항 자동 LLM-judge 도입.
