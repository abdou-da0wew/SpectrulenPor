# WORKLOG.md — dated engineering log

<img src="https://cdn.jsdelivr.net/npm/@phosphor-icons/core@2.1.1/assets/regular/list-checks.svg" width="15" align="absMiddle" alt="log icon"> Reverse-chronological record of shipped changes. One entry per merged PR, plus notable investigations. Facts only — no placeholders, no "to be determined" sections.

---

## 2026-11-05 — docs overhaul, hardware lock, diagram system (v5.5.1+16)

- **Hardware decision recorded**: the smart-glasses end uses the AI-Thinker **ESP32-CAM (ESP32-S + OV2640)** flashed via the **ESP32-CAM-MB** micro-USB programmer, procured from Maker Selectronics (Egypt). Links recorded in `README.md`, `CONTEXT.md`, and `firmware/README.md`; the BOM adds the MB shield (~120 EGP, replacing the generic FTDI adapter line).
- **README rewritten** end to end: badge row (shields.io flat-square), Phosphor icon usage everywhere, six real in-app screenshots captured from a headless-browser phone-layout session of the actual app (`docs/screenshots/`), a real benchmark table with explicit `Measured` / `Implemented — pending device` / `Not tested here` marks, target devices, repository status, one-command Flutter install for Windows + Linux, build guide, and updated authors/structure/roadmap.
- **Architecture visualizations** created with the [diagram-design](https://github.com/cathrynlavery/diagram-design) editorial skill: `docs/diagrams/architecture.html` + `pipeline.html` (self-contained HTML, inline SVG) exported to PNG for README embedding. Both pass the skill's geometry + self checks (0 findings).
- **New agent docs**: `AGENTS.md` (contributor/agent handbook), `CONTEXT.md` (facts & invariants), `WORKLOG.md` (this log).
- **Real measurements recorded**: `flutter test` = 92/92 passing (~32 s); `flutter analyze` = 0 errors, 10 warnings, 78 infos; `flutter build web --release` compiles clean (~108 s).
- **Web-compat fix**: `PhoneCameraService.start` guarded orientation lock and image-stream start with `kIsWeb` (camera_web throws `CameraException(NotSupportedError)` for both; preview still renders) — makes the live preview usable in a browser and is what enables the reproducible screenshot pipeline.
- **Version aligned**: `pubspec.yaml` and `assets/version.json` bumped to `5.5.1+16` to match the `SpectruLenPor/5.5.1` user-agent strings shipped in the audit rounds.

## 2026-11-05 — PubChem CAS backfill + latent-bug & test-debt cleanup (PR #5, merged)

- `tooling/backfill_cas_pubchem.py`: PubChem PUG REST/PUG-View backfill with CAS check-digit validation, citation-frequency dominance, ambiguity refusal, and verified polymer pins. 108/110 compounds carry CAS; the two true mixtures (borosilicate glass, 304 stainless steel) correctly have none.
- `DocsSearchService`: CAS-normalized queries resolve the compound as the top local hit in every mode; compound citation snippets include `CAS: <number>` so the grounded LLM cites real registry numbers.
- Latent-bug cleanup: TTS cloud-only silence handling, BLE reconnect backoff, SSE stall guard, release signing config, bundled-font declarations; test debt paid down.

## 2026-11-04 — audit round 1 fixes (PR #4, merged)

- `AppDatabaseChannel.kt`: TTL eviction passed a `String` where-arg against the INTEGER `expires_at` column — the cache was wiped on every startup; now passes `Long`.
- History/Diagnostics screens aligned to the real `ts` column (4 tables) and the telemetry schema actually written by the firmware parser.
- GHS corpus completeness (9 pictograms load — confirmed by test output `119 elements, 110 compounds, 9 hazard pictograms`).
- `flutter: fonts:` declarations fixed so bundled fonts resolve on all targets.

## 2026-11-04 — YOLO speed/accuracy & UX round (PR #3, merged)

- Mobile execution-provider benchmark at session start (CPU vs NNAPI+FP16 vs XNNPACK), latest-wins frame pipelining.
- Instant box clearing via 8×8 luma-signature scene detection + 2.5 s staleness guard.
- Cloud capture privacy: everything outside the selected box blurred (+15% margin) before upload.
- Flashlight auto-torch with hysteresis (< 38 on, ≥ 70 off).
- Moondream3 protocol strictly box-limited (WHAT/STATE/TEXT/HAZARD; `whatsAround` pinned empty).
- OpenRouter prompt overhaul: target limitation, zero guessing, citation discipline in EN/AR.
- Fish Audio streamed TTS with native fallback; citation UI pill styling.
- Export ladder documented in `docs/YOLO26_MOBILE_OPTIMIZATION.md` (`tooling/export_yolo26_mobile.py`).

## 2026-10-28 — v5.5.0+15 baseline

- Initial release state: full-viewport camera + BLE glasses streaming, local YOLO26-Nano staging/auto-download, cloud-only policy toggle, interactive boxes with strict dual capture, 119-element/110-compound/GHS corpus, 3 RAG modes, `[n]` citations + fact-checking, auto-updating `ConversationContext`, 9-table SQLite WAL database, bilingual EN/AR UI with bundled fonts.
