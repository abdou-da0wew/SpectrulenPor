# WORKLOG.md — dated engineering log

Reverse-chronological record of what was built, fixed, and verified. One entry per merged change-set.

## 2026-11-05 — v5.5.1+16 · hardware lock, pipeline swimlane, glasses screenshot, web camera fix (PR #12)

- **Hardware decision locked** (user-confirmed): the glasses end is the AI-Thinker **ESP32-CAM (ESP32-S + OV2640)** flashed via the **ESP32-CAM-MB** micro-USB programmer shield, procured from Maker Selectronics (Egypt). Links recorded in `CONTEXT.md` (new "Locked hardware decision" section), `README.md` BOM (MB shield ~120 EGP replaces the FTDI line; mount/wiring adjusted to keep the ≈ 1,750 EGP total), and `firmware/README.md` (new "Official hardware" + one-plug flashing procedure; FTDI path kept as fallback).
- **Capture/analysis pipeline swimlane** added in the same diagram-design editorial system: `docs/diagrams/pipeline.html` (self-contained HTML, passes geometry + self checks) rendered to `docs/diagrams/pipeline.png`; embedded in `README.md` and `docs/ARCHITECTURE.md` next to the existing architecture figure.
- **Glasses (BLE) source screenshot** captured (`docs/screenshots/02_glasses_ble.png`) — disconnected-state UI; added to the README gallery.
- **Web camera fix**: `PhoneCameraService.start` now guards `lockCaptureOrientation` and `startImageStream` with `kIsWeb` — camera_web throws `CameraException(NotSupportedError)` for both, so the browser preview died at startup. This is what makes the reproducible web-screenshot pipeline show the live feed.
- Reconciliation: branch rebased onto the PR #7-#11 documentation/CI line; their README/AGENTS/CONTEXT/WORKLOG/BENCHMARKS versions kept, the unique additions above merged in; duplicate local artifacts (own architecture render, redundant screenshots) dropped in favor of the merged ones.

## 2026-11-05 — v5.5.1 · analyzer zeroed out, CI green (PR #8)

- CI's first runs failed: `flutter analyze` was exiting 1 — the repo carried **10 real warnings** (my earlier severity scan was wrong) plus 78 info lints, and warnings are fatal by default.
- Fixed all 10 warnings properly: renamed `stripMarkdownForTest` → public `stripMarkdownForTts` (it is production API used by the native-TTS fallback — the `@visibleForTesting` annotation was simply wrong), removed two unnecessary `!`, dropped the unused `_kvR` fixed-point constant, added a rationale `ignore_for_file` for just_audio's experimental streamed-source API, and one for the smoke tool's sink test-hook.
- `dart fix --apply` cleaned 69 stale info lints across 24 files.
- Migrated deprecated APIs: `RadioListTile` group-value/onChanged → `RadioGroup<int>` ancestor (Settings model-chain picker), `speech_to_text` named listen params → `SpeechListenOptions`, `BuildContext`-across-async-gap guarded with a `mounted` check; `tts_sink_web.dart` keeps `dart:html` behind a rationale ignore (package:web migration tracked in the roadmap).
- Result: `flutter analyze` = **No issues found** (exit 0), 93 tests passing, `flutter build web --release` clean.
- CI note: GitHub Actions jobs for this account fail at runner startup with zero steps and no logs - verified with a bare `echo hi` smoke job (diagnosis PR, smoke file removed afterwards). `ci.yml` stays committed; the badge is static until the owner clears the account-level block (Settings -> Actions / billing).

## 2026-11-05 — v5.5.1+16 · documentation overhaul (PR #7)

- Rebuilt `README.md`: shields badges, Phosphor icon headers (committed SVGs, zero emojis), in-app screenshots, diagram-design architecture + scientific-RAG visualizations, honest implemented-vs-untested matrix, real benchmark table, target devices, one-command Flutter install for Windows/Linux, docs index.
- Added `AGENTS.md` (agent ground rules), `CONTEXT.md` (mission, glossary, data inventory, constraints), `WORKLOG.md` (this file), `docs/BENCHMARKS.md` (measured vs pending numbers).
- Rewrote `docs/ARCHITECTURE.md` around the current pipeline and CAS discipline.
- Added `.github/workflows/ci.yml` — `flutter analyze` + `flutter test` on every push/PR.
- Captured in-browser phone-layout screenshots of the real app on Flutter Web (Pixel-7-sized headless Chrome, fake lab-scene camera feed): home gate, live detection view, settings, RAG modes, history, diagnostics, Arabic RTL home. Capture scripts committed under `tooling/`.
- Rendered diagrams to PNG with the [diagram-design](https://github.com/cathrynlavery/diagram-design) editorial system; editable HTML sources in `docs/diagrams/`.
- Verified: 93 tests passing, `flutter analyze` 0 errors / 0 warnings, `flutter build web --release` clean.

## 2026-11-05 — v5.5.1+16 · mixture CAS guard (PR #6)

- Caught in a PubChem dry-run that `Stainless steel (304 austenitic)` resolved through a name variant to elemental iron (CID 23925) — a future `--write` would have stamped the alloy with iron's CAS `7439-89-6`.
- `common_compounds.json`: the two true mixtures (borosilicate glass, 304 stainless steel) now carry `cas_skip: true` + human-readable `cas_note`.
- `tooling/backfill_cas_pubchem.py`: entries flagged `cas_skip` are skipped before any query — they can never be poisoned by a re-run.
- `DocsSearchService._formatCompoundDetailed`: emits `CAS: not applicable - <cas_note>` so the model is told why there is no registry number.
- Version bump to `5.5.1+16` in `pubspec.yaml` + sha-stamped `assets/version.json`.
- Tests: 93 passing (2 new: corpus flag contract + detailed-mode CAS/cas_note snippets).

## 2026-11-04 — v5.5.1 · PubChem CAS backfill (PR #5)

- New `tooling/backfill_cas_pubchem.py`: resolves every compound name on PubChem (PUG REST + PUG-View), accepts a CAS only from the curated CAS Common Chemistry record or a single checksum-valid synonym, refuses ambiguous records, rate-limited ~3.3 req/s with backoff.
- Backfilled **108 of 110** compounds in `common_compounds.json`; polymers without PubChem records (PET, PP, PC, cellulose) verified out-of-band and pinned via `--set`.
- `DocsSearchService` now matches CAS-formatted queries and includes `CAS: <number>` in every compound snippet surfaced to the AI.
- Latent test-debt cleanup.

## 2026-11-04 — v5.5.1 · audit round 1 (PR #4)

- `AppDatabaseChannel.kt`: `evictExpiredCache` passed a String where-arg to the INTEGER `expires_at` column — TTL cache rows were wiped on every startup; now binds a `Long`.
- History/Diagnostics screens: aligned reads with the real `ts` column (4 tables) and dropped references to non-existent telemetry columns (`uv_mw_cm2`, `ir_mw_cm2`, `ambient_lux`).
- TTS: `cloudOnly` + missing key no longer fails silently — explicit user-visible error; native fallback uses sane fixed rate/pitch/volume and strips markdown.
- BLE: automatic reconnect with capped exponential backoff after glasses disconnect.
- OpenRouter SSE: idle-timeout watchdog covers the whole stream (headers → last chunk), not just the first byte.
- Release: signing config template (keystore via `key.properties`, never committed) + R8 rules.
- Fonts: bundled TTFs declared under `flutter: fonts:` so offline `google_fonts` resolves them.
- Dead code removal: ML Kit object-detection layer, unused widgets, disabled ONNX backend file, unused l10n keys.

## 2026-11-04 — v5.5.1 · vision accuracy & UX (PR #3)

- YOLO mobile speed/accuracy: execution-provider race (CPU vs NNAPI+FP16 vs XNNPACK) at session start; image size parsed from the ONNX graph; latest-frame pipeline (always infer the newest frame, drop stale work).
- Instant stale-box clearing on fast camera sweeps via 8×8 luminance-signature scene-change detection + 2.5 s box expiry guard.
- Privacy blur: everything outside the selected capture box is blurred (+15 % safety margin) in the frame sent to Moondream.
- Flashlight: auto-on in dark labs with on/off hysteresis (on < 38 luma, off ≥ 70).
- Moondream3: strict box-bound caption protocol (WHAT/STATE/TEXT/HAZARD tags) — captions describe only the selected object.
- OpenRouter prompts: hardened zero-guessing discipline, target scoping and citation rules in EN + AR.
- TTS: Fish Audio first through the config layer, native Android fallback with sane parameters.
- Citations UI: Google-AI-Overviews-style source chips (brand avatar + source name + `[n]` + favicon).
- Docs: added `docs/YOLO26_MOBILE_OPTIMIZATION.md` and `tooling/export_yolo26_mobile.py` (LiteRT/INT8, CoreML, ExecuTorch ladder).

## 2026-10-28 — v5.5.0+15 · initial public build

- Baseline feature set: on-device YOLO26-Nano staging + inference, phone camera & BLE ESP32-CAM sources, VisionGate, dual capture, Moondream3, OpenRouter chain with `[n]` citations, fact checking, `ConversationContext`, 9-table SQLite WAL database, Fish Audio + native TTS, bilingual EN/AR RTL UI, ESP32-CAM firmware source, bundled 119-element + 110-compound + GHS corpus.
