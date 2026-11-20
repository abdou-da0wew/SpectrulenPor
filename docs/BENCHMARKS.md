# SpectruLenPor — Benchmarks & verification status

One rule: **a number either was measured, or it is marked pending.** Nothing in this file is estimated. Re-run the reproduction commands after any pipeline change and update this table in the same PR.

- **CI note:** the committed analyze/test workflow previously failed at runner startup without logs because of an account-level Actions block. These commissioning checks are local and do not claim a new CI pass.
- **Software environment:** Flutter `3.47.1 stable`, Dart `3.13.1`, Linux x64. The latest integration and hardware checkpoint is dated 2026-11-20; the exact test snapshot matters because several follow-up edits landed after the most recent full-suite run.
- **Current verification boundary:** the full Flutter suite has not been rerun after the final two test/speech fixes, and a full-project `flutter analyze` attempt did not complete. The current state is recorded below and in [WORKLOG.md](../WORKLOG.md).

## Software verification (measured)

| Metric | Result | How to reproduce |
|---|---|---|
| Latest full Flutter run (2026-11-20 checkpoint) | **218 passed, 4 skipped, 13 failed** | Two follow-up fixes landed afterward (optional ESP probe skip and TTS markdown cleanup); the full suite was not rerun, so this is not a post-fix result |
| Focused TTS + speech text-correction tests | **13 passed** | Rerun after the TTS sanitizer fix; `test/services/openrouter_tts_service_test.dart` and `test/services/speech_text_corrector_test.dart` |
| Full-project static analysis | **Not confirmed** | Latest `flutter analyze` attempt did not complete; no clean analyzer result is claimed |
| Latest firmware host C protocol suite | **3/3 passed** | Latest 2026-11-20 checkpoint; protocol host tests |
| Latest UDP testbench suite | **139 passed** | Latest 2026-11-20 checkpoint; Python UDP HIL/testbench suite |
| Firmware Python suite | **Passed; exact count not recorded in the latest checkpoint** | The current work log records a pass but does not carry forward a verified total |
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

Historical 2026-11-15 snapshots remain useful for regression provenance but are not the current verification status. The earlier 304-Python / 190-Flutter / zero-analyzer report belongs to that older source snapshot; do not carry those figures forward as current green checks. Focused test counts are subsets, not additional suite totals. Host scheduling and Flutter plugin stubs do not establish real radio/FreeRTOS scheduling, Android scans or camera throughput.

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

The detailed build/flash inventory below is historical commissioning evidence from the ESP32-CAM/CH340 fixture. The latest UDP V2 soak observations are from 2026-11-20 and supersede older throughput claims. Linux firmware results do not verify the Android application. See [hardware validation](firmware-hardware-validation.md) for fixture details and evidence boundaries.

| Current UDP V2 physical measurement (2026-11-20) | Result | Interpretation |
|---|---|---|
| 60-second AMPDU-on soak | 210 decoded frames, about **3.50 FPS**, no incomplete frames or protocol errors | One successful run; later sustained runs were inconsistent |
| Latest 60-second AMPDU-off soak | About **1.5 FPS**, one incomplete frame and one control timeout | Latest measured profile; not stable enough to call reliable |
| Requested streaming target | **20–30 FPS** | Not achieved; the current setup remains far below target |
| Reliable SVGA/XGA sustained cadence | Not established | Requires further RF, camera and sender work |

These are measurements from a particular board, AP, firmware profile and test window. They are not guaranteed application performance.

| Metric | Value / target | Status |
|---|---|---|
| Reviewed source-fix release (2026-11-15, historical) | Firmware 3.2.0, 977,840 bytes, ESP-IDF 5.5.1 | Zero compiler warnings/errors and independent four-region flash verification; later builds and UDP V2 work supersede this image |
| Unflashed release-source safety build | Firmware 3.2.0, 976,848 bytes, ESP-IDF 5.5.1 | Zero compiler warnings/errors, no TX wrappers, NVS-init safeguard included; **not flashed**, predates sender correction |
| Camera-DMA build03 gates | Zero compiler warnings/errors, matching legacy config/partitions | ELF wrapper call paths verified; failed host injection retained and assessed; later four-region flash verified |
| Earlier trace build used by run02 | Firmware 3.2.0 lwIP trace diagnostic, 992,752 bytes | Retained image and four verified flash regions; reached IP/listener and partial UDP receipt without decoding |
| Historical host firmware C checks (2026-11-15) | 578 command, 11 JPEG, 8,974 UDP checks | Retained pre-UDP-V2 regression run; latest protocol suite is reported above as 3/3 test groups |
| Missing-AP exhaustion | Exactly 20 attempts and 20 reason-201 failures; 40-second post-exhaustion observation | Measured; no BLE initialization or fresh advertisement |
| Missing-AP credentials after reset | WiFi-only boot; retry cycle restarted at attempts 1 and 2 | Measured; credentials retained |
| Historical BLE QVGA JPEG frame rate | 0.96 received fps across 3 decoded frames; 1,000 ms scheduling interval | Earlier firmware snapshot only. BLE is now commissioning-only and no longer carries JPEG frames. |
| Earlier UDP JPEG delivery baseline (pre-UDP-V2) | 800x600 JPEG decoded; 5/5 stream frames in an earlier profile | Historical test only. It used the earlier fragment/redundancy transport and does not represent current V2 throughput or reliability. |
| Latest comprehensive pre-V2 UDP probe | All 5 stream frames decoded, controls and reset persistence verified | Historical result from the earlier transport; not a current V2 performance claim. |
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

Earlier temporary raw hardware captures are no longer available for revalidation. Image hashes, historical summaries and retained evidence are distinguished in [hardware validation](firmware-hardware-validation.md). The pre-UDP-V2 5/5 decoded-frame result belongs to an earlier transport and does not establish current delivery. The latest UDP V2 physical results are the November 20 soak measurements above: the AMPDU-on run reached about 3.5 FPS, while the latest AMPDU-off run reached about 1.5 FPS with one incomplete frame and a control timeout. Sustained delivery is therefore still unreliable and the 20–30 FPS target remains unmet. Firmware host-test passes do not establish Android transport performance or optional sensor operation. No raw NVS dump/comparison was executed.

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
