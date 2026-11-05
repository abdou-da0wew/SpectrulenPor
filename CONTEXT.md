# CONTEXT.md — project facts & invariants

<img src="https://cdn.jsdelivr.net/npm/@phosphor-icons/core@2.1.1/assets/regular/book-open.svg" width="15" align="absMiddle" alt="book icon"> The stable facts an agent or contributor must know before changing anything. If code contradicts a line here, fix the code or fix this file — in the same PR.

---

## Identity

| Fact | Value |
|---|---|
| App name | SpectruLenPor |
| Package | `com.spectraglass.app` |
| Current version | `5.5.1+16` (see `pubspec.yaml`, `assets/version.json`) |
| BLE advertised name | `SpectruLenPor-ESP32` |
| Platform | Android 12+ (`minSdk 31`, `compileSdk`/`targetSdk 36`); a stubbed Flutter web build exists for UI work |
| Languages | English + Arabic (full RTL) |
| HTTP user agent | `SpectruLenPor/5.5.1 (https://spectraglass.app)` |

## The three design rules (invariants)

1. **Glasses dumb, phone smart.** The ESP32-CAM end streams QVGA JPEG + UV/IR telemetry only. All inference, redaction, retrieval, reasoning, and speech run on the phone. Never move processing onto the glasses.
2. **Detection local & instant; analysis user-gated.** YOLO26-Nano runs on every gated frame on-device. No cloud call, no capture, unless `selectedBox != null` AND the user taps *Capture 2 Frames & Analyze*.
3. **Zero guessing.** VLM describes only the selected box (`whatsAround` pinned empty); LLM cites only attached `[n]` sources; CAS numbers only via the checksum-validated PubChem backfill; the fact-checker annotates every claim `Verified` / `Unverified`.

## Hardware decision (locked)

The glasses use the **AI-Thinker ESP32-CAM (ESP32-S + OV2640)** flashed via the **ESP32-CAM-MB** micro-USB shield, procured from Maker Selectronics (Egypt):

- ESP32-CAM module: `https://makerselectronics.com/product/esp32-cam-esp32-s-wifibluetooth-with-ov2640-camera-module/`
- ESP32-CAM-MB programmer: `https://makerselectronics.com/product/esp32-cam-mb-micro-module-esp32-cam/`

Sensors: GUVA-S12SD UV → `GPIO12` (ADC2 — mind the MTDI strapping-pin caveat; prefer ADC1 `GPIO32/33` when rewiring, and a ~10 kΩ pull-down), analog IR → `GPIO13`, onboard flash LED → `GPIO4`. Prototype budget ≈ 1,750 EGP of a 2,500–6,000 EGP target.

## Key thresholds & constants

| Constant | Value | Where |
|---|---|---|
| VisionGate torch ON / OFF | mean luma < 38 / ≥ 70 (hysteresis, no flicker) | `vision_gate.dart` |
| Frame staleness guard | 2.5 s; 8×8 luma-signature scene-change clears boxes instantly | `yolo_detector.dart` |
| Privacy blur margin | +15% outside the selected box | `home_screen.dart` isolate painter |
| UV / IR hazard thresholds | ≥ 72% / ≥ 80% full scale | `spectrum_reading.dart` |
| BLE reconnect backoff | 1 → 16 s exponential | `bluetooth_camera_service.dart` |
| Response cache TTL | per-source TTL in `response_cache` | `internal_db_service.dart` |
| Model | `yolo26n.onnx` 5,040,902 bytes, Ultralytics 8.4.0, `end2end`, 80 COCO classes, `[1,3,640,640] → [1,300,6]` | `assets/models/` |
| Execution providers | startup benchmark: CPU vs NNAPI+FP16 vs XNNPACK, fastest working wins | `YoloInferenceChannel.kt` |
| LLM fallback chain | `google/gemma-4-26b-a4b-it:free` → `liquid/inkling-small:free` → `nvidia/nemotron-3-nano-30b:free` | `openrouter_service.dart` |
| TTS | Fish Audio streamed first, native Android TTS fallback | `openrouter_tts_service.dart` |

## Knowledge corpus

| File | Contents |
|---|---|
| `assets/docs/periodic_table.json` | 119 elements — atomic, electronic, physical properties |
| `assets/docs/common_compounds.json` | 110 compounds/materials — formulas, CAS (108 checksum-valid, 2 true mixtures correctly none), molar mass, properties, uses, hazards |
| `assets/docs/lab_safety.json` | 9 GHS pictograms (GHS01–GHS09), general PPE, emergency contacts |

CAS lookup by normalized registry number (`7732-18-5`, `7732 18 5`) returns the compound as the top local hit in every RAG mode; compound citation snippets include `CAS: <number>` so the LLM cites real registry numbers.

## Persistence (9 tables, SQLite WAL + fallback)

`chat_sessions`, `chat_messages`, `response_cache`, `app_logs`, `crash_hang_reports`, `telemetry_events`, `pipeline_traces`, `user_data`, `user_activity`. Native channel `com.spectraglass/db` (`AppDatabaseChannel.kt`); pure-Dart memory/file fallback via `DbFileStore` when native is unavailable (web, tests).

Column-name contract: history/diagnostics read the `ts` column; telemetry rows record what the sensors actually emit — do not invent `uv_mw_cm2`-style columns without writing them.

## BLE GATT contract (app ⇄ firmware, must stay in sync)

Service `0000ffe0-…`, TX `ffe1` notify (chunked `FFD8…FFD9` JPEG + `$UV:<int>;IR:<int>\n`), RX `ffe2` write: `0x00` pause, `0x01` resume (~1 fps), `0x02` single frame, `0x03`/`0x04` flashlight off/on. Firmware source: `firmware/esp32cam_glasses_firmware.ino`; app side: `bluetooth_camera_service.dart`.

## Benchmark honesty

The README benchmark table is authoritative. Measured in CI-like sandbox: 92 tests passing, analyzer 0 errors, web build clean. Implemented but device-specific (never quote numbers for them): EP startup benchmark, on-device FPS, local Moondream GGUF, BLE end-to-end. Not runnable in sandbox: release APK build.

## Glossary

| Term | Meaning |
|---|---|
| VisionGate | luminance/texture quality gate with auto-torch hysteresis, drops obstructed frames |
| EP | ONNX Runtime execution provider |
| Dual capture | `cleanJpeg` + `withBoxesJpeg` (marked with reticle/brackets/banner) |
| AnchorContext | immutable per-capture metadata + Moondream structured summary injected into prompts |
| ConversationContext | auto-updating structured memory merged from `<context_update>` blocks |
| RAG modes | `strict` (exact symbol/formula/CAS/title), `detailed` (full cards + cloud), `semantic` (YOLO class → materials + fuzzy + cloud) |
| Export ladder | staged mobile-inference migration plan in `docs/YOLO26_MOBILE_OPTIMIZATION.md` |
