# SpectruLenPor — Benchmarks & verification status

One rule: **a number either was measured, or it is marked pending.** Nothing in this file is estimated. Re-run the reproduction commands after any pipeline change and update this table in the same PR.

- **CI note:** the committed analyze/test workflow previously failed at runner startup without logs because of an account-level Actions block. These commissioning checks are local and do not claim a new CI pass.
- **Software environment:** Flutter `3.47.1 stable`, Dart `3.13.1`, framework revision `6655482ec06e547f90abf8ae7590466f4415978d`, Linux x64, 2026-11-15. Results cover successive uncommitted snapshots. The latest Python source-fix runs retain raw logs, timestamps and source identities; the earlier 247 results have inline-only provenance. Software passes do not establish deployment or hardware/Android/sensor verification. Web compile time and corpus/backfill rows retain the earlier 2026-11-05 measurements.

## Software verification (measured)

| Metric | Result | How to reproduce |
|---|---|---|
| Unit + widget test suite | **190 passing, 0 failing, 0 skipped** | `flutter test --no-pub --reporter expanded --concurrency 2`; complete post-fix run, raw logs/timestamps and unchanged source identities retained |
| Static analysis | **0 issues** ("No issues found") | `flutter analyze --no-pub`; complete post-fix run under unchanged analyzer configuration |
| Latest retained host Python suites | **180 firmware + 124 testbench = 304 passing**, zero failures/errors/skips | From `firmware/`: unittest discovery with `test_*.py` in `tests/` and `testbench/tests/`; source-fix raw logs, timestamps and unchanged source identities retained |
| Earlier reported host Python suites | **146 firmware + 101 testbench = 247 passing**, inline-only provenance | No retained raw log or exact execution timestamp for this historical run |
| Earlier retained host Python suites | **117 firmware + 101 testbench = 218 passing**, zero failures/errors/skips | Retained cleanup/safety snapshot, predates later standalone-signal and sender changes |
| Repeated CLI/NVS regressions | **17 CLI + 4 actual-`app_main` tests passed** | Subsets already included in the 218 Python tests; not extra counts |
| Actual UDP sender regressions | **8 passing** | Compiles actual sender with strict warnings; included in reported firmware suite, not additional suite counts |
| Camera-DMA actual-source host checks | **3 header-order checks + 10 safety cases passed; 1 safety case failed** | Failed transient case retained; review identifies direct stub register mutation, not a demonstrated pinned-driver restart path; no electrical-monitoring claim |
| Disconnected-backend CLI SIGTERM smoke | **Exit 0, empty frame HTTP 204** | No hardware connected or live camera verified |
| Dashboard browser checks | **5 groups passed, zero browser errors**, earlier snapshot | Actual disconnected backend; EN/AR/RTL, layouts, reports, security and intercepted mobile-flow forwarding |
| OpenCV HTTP consumer | **3 empty reads**, OpenCV 4.10.0, fresh post-fix smoke | Actual disconnected backend, no hardware access, GUI or decoded live image |
| Flutter Web release build | Compiles clean; ~84 s cold compile of `lib/main.dart` | Historical 2026-11-05 measurement; `flutter build web --release` |
| CAS corpus integrity | 108/110 valid CAS (checksum-tested in tests); mixtures flagged | `flutter test test/services/docs_search_and_fact_checker_test.dart` |
| PubChem backfill safety | `SKIP-FLAG 2 / entries changed 0` for flagged mixtures | `python3 tooling/backfill_cas_pubchem.py --only "Stainless|Borosilicate"` |

Historical `software-final-20261115` results remain retained: 105 firmware/HIL + 90 testbench = 195 passing Python tests, 147 Flutter tests and protocol checks. The earlier 247 reported results are recorded in `diagnostics/standalone-signals-reported-20261115/results.json` with no independently retained raw log or exact execution timestamp. The approved source-review fixes required new combined suites: `review-software-20261115T174518Z-bc9ccc55` retains 304 Python passes, 190 Flutter passes/zero analyzer issues and fresh strict-warning/ASan/UBSan protocol checks. Focused 62 Python, 30 firmware host-C and 63 Flutter tests are subsets, not additional counts. Negative reproductions, the interrupted non-passing Flutter run and rejected deployment/smoke checkers remain retained separately. Host scheduling and Flutter plugin stubs do not establish real radio/FreeRTOS scheduling, scans or updated hardware retry exhaustion.

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

## Connectivity & peripherals

Firmware measurements below use the attached ESP32-CAM/CH340 fixture and ESP-IDF 5.5.1 on 2026-11-15. Linux firmware results do not verify the Android application. See [hardware validation](firmware-hardware-validation.md) for the image hash and evidence boundaries.

| Metric | Value / target | Status |
|---|---|---|
| Currently flashed reviewed release | Firmware 3.2.0, 977,840 bytes, ESP-IDF 5.5.1 | Zero compiler warnings/errors, no diagnostic instrumentation; source/configuration/partition gates and independent four-region flash verification passed, NVS excluded; latest saved-profile probe still failed |
| Unflashed release-source safety build | Firmware 3.2.0, 976,848 bytes, ESP-IDF 5.5.1 | Zero compiler warnings/errors, no TX wrappers, NVS-init safeguard included; **not flashed**, predates sender correction |
| Camera-DMA build03 gates | Zero compiler warnings/errors, matching legacy config/partitions | ELF wrapper call paths verified; failed host injection retained and assessed; later four-region flash verified |
| Earlier trace build used by run02 | Firmware 3.2.0 lwIP trace diagnostic, 992,752 bytes | Retained image and four verified flash regions; reached IP/listener and partial UDP receipt without decoding |
| Host firmware C tests | 578 command, 11 JPEG, 8,974 UDP checks | Fresh retained post-fix strict-warning/ASan/UBSan run |
| Missing-AP exhaustion | Exactly 20 attempts and 20 reason-201 failures; 40-second post-exhaustion observation | Measured; no BLE initialization or fresh advertisement |
| Missing-AP credentials after reset | WiFi-only boot; retry cycle restarted at attempts 1 and 2 | Measured; credentials retained |
| BLE QVGA JPEG frame rate | 0.96 received fps across 3 decoded frames; 1,000 ms scheduling interval | Measured in a partial Linux HIL run; not an Android benchmark |
| UDP SVGA JPEG frame rate | 100 ms scheduling target; throughput unmeasured | **Working**: real 800x600 JPEG decoded over WiFi-only UDP. Dynamic TX buffers (64), 3× fragment redundancy, 10ms pacing, 256KB socket buffers. Comprehensive test verified: 5/5 stream frames, UDP controls (flash/stream/pause), reset persistence, dashboard API (7/7 endpoints 200/204). Zero send failures. |
| Latest comprehensive UDP probe | All 5 stream frames decoded, all controls work, reset persistence verified | `ok: true`, zero send failures, zero cleanup errors, zero credential writes/erasures. JPEG: ~11,600 bytes, 800x600 RGB. |
| Historical camera-DMA probe | Association at -71 dBm, 4/5 ping replies; 1 echo + 9 orphan JPEG fragments | No sequence zero, accepted fragments or decoded image; sender deadline/`ENOMEM`; failed evidence retained |
| Camera acquisition pause/drain markers | RX/EOF snapshots off; 10-second requested drain; resume call logged | No queued starts or later capture requested; hardware suppression/reacquisition and continuous electrical state unverified |
| Earlier legacy-PHY probe | Association at -74 dBm, 5/5 ping replies; 1 echo + 16 JPEG fragments including sequence zero | 11/33 fragments accepted before expiry, no decoded image; `HIL_UDP_FRAME_TIMEOUT`; zero credential writes/erasures, cleanup errors empty |
| TX-only AMPDU-off comparison | Association at -71 dBm, 1/5 ping replies; 2 datagrams | Zero accepted fragments or decoded images; failed; RX aggregation unchanged |
| TX-completion baseline | Association at -71 dBm, 4/5 ping replies; echo + JPEG sequences 6/10/15 | Zero accepted fragments or decoded images; 19/20 callbacks in JPEG-burst window failed, no per-fragment callback mapping claimed |
| Earlier driver run02 WiFi and UDP attempt | Fresh WiFi-only boot, association at -72 dBm, IP/listener; 2 JPEG datagrams, sequences 24/25 of 33 | One single-frame request; no sequence zero or accepted fragments; `HIL_UDP_FRAME_TIMEOUT`; zero credential writes/erasures, cleanup errors empty |
| Earlier driver run01 WiFi attempt | One fresh WiFi-only boot; reasons 2/205/201/201/2/201/4 | `HIL_WIFI_CONNECT_TIMEOUT`; no IP/listener, image requests or datagrams; no driver/socket TX records; separate historical evidence |
| Trace run02 WiFi and UDP receipt | Fresh WiFi-only boot and IP/listener; 1 echo + 13 JPEG datagrams, 62 fragments advertised | One single-frame request; no sequence 0, zero reassembler-accepted fragments; zero credential writes/erasures; no cleanup errors |
| Earlier trace run01 WiFi connection | 7 attempts within the probe window; reasons 201/204/205 | Failed before DHCP address/listener; zero UDP image requests; separate historical evidence |
| Live dashboard/API/OpenCV delivery | Pending | No decoded UDP image or complete real-network contract |
| AS7265x telemetry cadence | `$UV:..;IR:..` scheduled every 500 ms in setup | Sensor unavailable; not measured; legacy UV is the 410 nm channel |
| Android BLE reconnect | 1 to 16 s capped exponential backoff | Real-phone test pending; no ADB device attached |

Earlier temporary raw hardware captures are no longer available for revalidation. Image hashes, historical summaries and retained evidence are distinguished in [hardware validation](firmware-hardware-validation.md). UDP JPEG delivery has been fixed and fully verified on the reviewed uninstrumented release via comprehensive hardware testing: 5/5 stream frames decoded, all UDP controls work, reset persistence verified, dashboard API verified (7/7 endpoints). Zero send failures, zero cleanup errors, zero credential writes/erasures. Historical failed probes (camera-DMA, legacy-PHY, static-TX) remain retained as evidence of what did not work. Firmware delivery flag verified on real hardware; mobile-contract, Android and sensor remain unverified. No raw NVS dump/comparison was executed.

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
