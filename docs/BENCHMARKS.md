# SpectruLenPor — Benchmarks & verification status

One rule: **a number either was measured, or it is marked pending.** Nothing in this file is estimated. Re-run the reproduction commands after any pipeline change and update this table in the same PR.

- **Environment for "Measured" rows:** Flutter `3.47.9 stable` (framework rev `c197ca5199`), Linux x64 CI-style sandbox, repository `main` at `v5.5.1+16`, 2026-11-05.

## Software verification (measured)

| Metric | Result | How to reproduce |
|---|---|---|
| Unit + widget test suite | **93 passing, 0 failing** | `flutter test` |
| Static analysis | **0 issues** ("No issues found") — 10 warnings fixed, 69 stale lints auto-fixed via `dart fix`, deprecated `Radio` group-value and `speech_to_text` listen APIs migrated | `flutter analyze` |
| Flutter Web release build | Compiles clean; ~84 s cold compile of `lib/main.dart` | `flutter build web --release` |
| CAS corpus integrity | 108/110 valid CAS (checksum-tested in tests); mixtures flagged | `flutter test test/services/docs_search_and_fact_checker_test.dart` |
| PubChem backfill safety | `SKIP-FLAG 2 / entries changed 0` for flagged mixtures | `python3 tooling/backfill_cas_pubchem.py --only "Stainless|Borosilicate"` |

## Model & corpus (verified from artifacts)

| Metric | Value |
|---|---|
| `assets/models/yolo26n.onnx` size | `5,040,902` bytes (~5.04 MB) |
| Input / output tensors | FP32 `[1,3,640,640]` → `[1,300,6]` (`end2end=True`, 80 COCO classes, Opset 22) |
| Bundled corpus | 119 elements · 110 compounds (108 with CAS) · 9 GHS pictograms |
| APK footprint of corpus + model | Model 5.04 MB + JSON corpora (see `assets/docs/`) |

## On-device inference (implemented — measurements pending)

The EP race is implemented in `YoloInferenceChannel.kt`: at session start it benchmarks CPU, NNAPI+FP16, and XNNPACK, keeps the fastest working session, and exposes `executionProvider`, `epBenchmarkMs` and `inputSize` through channel status. **No device timings have been recorded yet.**

| Metric | Status |
|---|---|
| EP benchmark (CPU vs NNAPI+FP16 vs XNNPACK) wall time | Pending — run on target phone |
| YOLO26-Nano p50 / p95 latency per frame | Pending |
| Steady-state preview FPS with inference active | Pending |
| Memory delta of the ONNX session | Pending |

Reproduction plan (once hardware is available):

1. `flutter run --release` on an Android 12+ phone.
2. Open Diagnostics → pipeline traces, filter `span_name = 'yolo.infer'`.
3. Record `epBenchmarkMs` per provider and p50/p95 `yolo.infer` durations; paste into this file with the device model, Android version, and build date.

## Connectivity & peripherals (design targets — pending hardware runs)

| Metric | Design target | Status |
|---|---|---|
| BLE QVGA JPEG frame rate | 5 Hz (`ffe0/ffe1` GATT notify) | Not yet measured on hardware |
| UV/IR telemetry cadence | `$UV:..;IR:..` @ 5 Hz | Not yet measured on hardware |
| BLE reconnect | 1→16 s capped exponential backoff | Unit-tested logic; hardware test pending |

## AI service latencies (pending production keys)

| Metric | Status |
|---|---|
| Moondream3 `analyzeSelected` round trip | Pending |
| OpenRouter first-token latency (per chain model) | Pending |
| Fish Audio TTS time-to-first-audio | Pending |

`tool/real_api_smoke_test.dart` exists for exactly these runs — execute it with real keys and record results here.

## Historical build cost

| Item | Value |
|---|---|
| Prototype hardware BOM | ≈ 1,750 EGP (of the 2,500–6,000 EGP target budget) |
| Software & AI stack | 0 EGP (Flutter, ONNX Runtime, SQLite, free cloud tiers) |
