# CONTEXT.md — project context

Everything an agent or a new contributor needs to understand the *why* behind SpectruLenPor, in one file.

## Mission

Build working smart glasses + companion app for real-time chemical and material identification, as a student research project at **Ashmounin Secondary School** (Menoufia, Egypt), within a **2,500–6,000 EGP** hardware budget. The prototype (≈ 1,750 EGP) mounts an ESP32-CAM with UV/IR sensors into an eyeglass frame; a phone runs the intelligence.

## Locked hardware decision

The glasses end is the **AI-Thinker ESP32-CAM (ESP32-S + OV2640)** flashed via the **ESP32-CAM-MB** micro-USB programmer shield, procured from Maker Selectronics (Egypt) — locked November 2026:

- ESP32-CAM module: <https://makerselectronics.com/product/esp32-cam-esp32-s-wifibluetooth-with-ov2640-camera-module/>
- ESP32-CAM-MB programmer (CH340 USB-UART, one-plug flashing + 5 V power + serial monitor): <https://makerselectronics.com/product/esp32-cam-mb-micro-module-esp32-cam/>

The MB shield replaces the generic FTDI adapter in the BOM and removes the manual `GPIO0`-to-GND flashing jumper. Pinout and BLE contract: [`firmware/README.md`](firmware/README.md).

## The scenario the product is designed for

A student walks through a chemistry lab or daily environment, points the camera (phone or glasses) at an object — a beaker, a reagent bottle, a metal spoon — and gets, in under a minute and in Arabic or English:

1. Live bounding boxes drawn fully offline on the phone (YOLO26-Nano ONNX).
2. A grounded, box-scoped description of exactly the selected object (never "explain the whole table").
3. Scientific detail anchored to a curated corpus: formula, CAS registry number, density, melting/boiling points, uses, hazards, GHS pictogram advice.
4. Clickable `[n]` citations and per-claim verification badges.
5. Voice narration in the user's language.

## Glossary

| Term | Meaning |
|---|---|
| **VisionGate** | Pre-inference quality gate: 64×64 mean-luma ≥ 38 and Laplacian texture ≥ 45, else frames are not analyzed; auto-torch assists in dark labs with on ≥ 38 / off ≥ 70 hysteresis |
| **EP race** | At YOLO session start the app benchmarks CPU, NNAPI+FP16 and XNNPACK execution providers and keeps the fastest |
| **Instant box clearing** | 8×8 luminance-signature scene-change detector wipes stale boxes immediately on fast camera sweeps; a 2.5 s expiry guard backstops |
| **Dual capture** | User-gated `cleanJpeg` + `withBoxesJpeg` pair; the clean frame is Moondream's input, the painted frame is the user's record; outside the selected box everything is blurred (+15 % margin) in the sent frame |
| **Cloud-Only policy** | Toggle that forces VLM/LLM/TTS to the cloud and skips non-YOLO local fallbacks; local YOLO stays local regardless |
| **RAG modes** | `strict` (exact symbol/formula/CAS/title), `detailed` (full property cards + cloud refs), `semantic` (YOLO label → materials expansion + fuzzy + web) |
| **CAS discipline** | Registry numbers come only from PubChem (checksum-validated, Common Chemistry anchored); mixtures say "not applicable" via `cas_note` |
| **`<context_update>`** | Structured JSON the LLM appends each turn; `ChatSession` merges it into running conversation memory and persists it |
| **HangWatchdog** | UI-stall detector feeding `crash_hang_reports` with a 40-entry breadcrumb ring |

## Data inventory

- `assets/docs/periodic_table.json` — 119 elements, 26 fields each (atomic, electronic, physical, historical; Kelvin temperatures).
- `assets/docs/common_compounds.json` — 110 compounds/materials: formula, CAS (108 verified via PubChem; 2 mixtures flagged), state, color, density, melting/boiling °C, summary, uses, hazards.
- `assets/docs/lab_safety.json` — GHS01–GHS09 pictogram classes with handling guidance.
- `assets/models/yolo26n.onnx` — 5.04 MB, FP32 `[1,3,640,640] → [1,300,6]`, 80 COCO classes, end2end NMS, Ultralytics 8.4.0 export.
- Internal DB (9 tables): `chat_sessions`, `chat_messages`, `response_cache`, `app_logs`, `crash_hang_reports`, `telemetry_events`, `pipeline_traces`, `user_data`, `user_activity`.

## External services (all optional)

| Service | Use | Missing-key behavior |
|---|---|---|
| Moondream3 Cloud | Box-grounded VLM captions | Cascades to local fallbacks (GGUF → ONNX classifier → ML Kit) when Cloud-Only is off; explicit error when on |
| OpenRouter | LLM reasoning chain (`gemma-4-26b → inkling-small → nemotron-3-nano`) + streamed Fish Audio TTS | Clear user-visible error; local TTS still works |
| PubChem / Wikipedia / DuckDuckGo | Live lookups, TTL-cached in `response_cache` | Corpus-only mode, no failure |

## Constraints that shape the design

- **Budget:** every hardware choice is the cheapest workable part; the app must run on the student's existing phone.
- **Privacy:** frames leave the device only for the explicit analyze step; detection, storage and diagnostics are local.
- **Offline-first degradation:** every cloud dependency has a local fallback or a graceful, user-visible failure — the app never silently pretends to succeed.
- **Bilingual RTL:** Arabic is a first-class locale (`Zain` typography, RTL-aware layouts, mirrored app bar); docs and UI never mix emoji placeholders into text.

## Current state (v5.5.1+16, November 2026)

- Audit round complete (PR #4): TTL-cache wipe bug, history/telemetry column mismatches, TTS silent failures, BLE reconnect, SSE stall guard, release-signing templates, font declarations.
- CAS backfill complete (PR #5, #6): 108/110 compounds verified from PubChem, mixtures guarded against single-component CAS poisoning.
- Documentation overhaul (PR #7): README rebuilt with real screenshots, diagram-design visualizations, honest implementation/benchmark matrix, AGENTS/CONTEXT/WORKLOG added, CI running analyze + test.

## What is deliberately *not* done yet

On-device benchmark numbers (detection latency, EP timings), a flashed/bench-tested ESP32-CAM prototype, live production-key validation of TTS/VLM/LLM, and a production release keystore. `docs/BENCHMARKS.md` tracks exactly which numbers are measured vs pending — never guess them, measure them.
