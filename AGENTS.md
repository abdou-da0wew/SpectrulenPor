# AGENTS.md — ground rules for AI coding agents

This file orients any AI agent (Claude Code, Codex, Cursor, Copilot, etc.) working in the SpectruLenPor repository. Read it fully before changing code.

## What this project is

A bilingual (English / Arabic RTL) Flutter Android app (`com.spectraglass.app`, package `smart_glass_app`) plus ESP32-CAM smart-glasses firmware. The app runs YOLO26-Nano fully on-device for live object detection, then produces grounded, cited, fact-checked chemistry answers through cloud VLM/LLM services. It is a student research project — correctness of scientific data matters more than feature velocity.

## Non-negotiable rules

1. **Never fabricate scientific data.** CAS registry numbers, element properties, hazard classifications: only values that come from the bundled corpus or a verified external query (PubChem). The backfill tool enforces checksum validation and Common Chemistry anchoring — do not bypass it, and never hand-write a CAS into `assets/docs/common_compounds.json`. Mixtures carry `cas_skip: true` + `cas_note`; leave them that way.
2. **No emojis.** Not in UI code, not in strings, not in docs or comments. In-app iconography is Material Icons (`Icons.*`); documentation uses committed Phosphor SVGs under `docs/assets/icons/`.
3. **Bilingual parity.** Every user-facing string goes through `lib/l10n/` ARBs. An English key must have a real (not machine-translated-looking placeholder) Arabic counterpart; the test suite enforces non-empty keys in both locales and that Arabic differs from English.
4. **Privacy defaults.** Detection stays on-device. The Cloud-Only policy toggle must never disable local YOLO. Do not add telemetry, do not send frame data anywhere except the explicit user-gated Capture & Analyze flow.
5. **The AI must not narrate beyond the box.** Moondream captions describe only the selected bounding box. Prompt edits in `moondream_service.dart` / `openrouter_service.dart` must preserve the strict target-scoping and zero-guessing rules in both languages.

## Commands

```bash
flutter pub get          # after changing pubspec
flutter analyze          # must stay 0 errors / 0 warnings
flutter test             # must stay all-green (93 tests as of v5.5.1)
flutter test test/services/docs_search_and_fact_checker_test.dart   # corpus + RAG suite
flutter run              # device run
flutter build web --release   # web UI-review build (native channels stub out)
python3 tooling/backfill_cas_pubchem.py        # CAS dry-run report (no writes without --write)
```

There is no Android SDK in the primary dev sandbox — do not assume `flutter build apk` works everywhere; CI runs analyze + test only.

## Architecture map (where things live)

| Area | File |
|---|---|
| App bootstrap, locale, routes | `lib/main.dart` (routes: `/`, `/settings`, `/history`, `/diagnostics`) |
| Recognition state machine, frame pipeline, box clearing | `lib/models/recognition_state.dart` |
| Quality gate + torch hysteresis | `lib/services/vision_gate.dart` |
| YOLO detector facade | `lib/services/yolo_detector.dart` |
| Native ONNX inference (EP race, letterbox, NMS) | `android/.../YoloInferenceChannel.kt` via MethodChannel `com.spectraglass/yolo` |
| Privacy blur + capture compose | `lib/screens/home_screen.dart` (`_paintBoxesIsolate`) |
| Moondream VLM (strict captions) | `lib/services/moondream_service.dart` |
| OpenRouter LLM chain + SSE streaming | `lib/services/openrouter_service.dart` |
| RAG: 3-mode search, CAS matching, corpus formatting | `lib/services/docs_search_service.dart` |
| Fact checking | `lib/services/fact_checker_service.dart` |
| TTS cascade (Fish Audio → native) | `lib/services/openrouter_tts_service.dart`, `native_tts_service.dart` |
| 9-table DB + fallback engine | `lib/services/internal_db_service.dart`, `android/.../AppDatabaseChannel.kt` (`com.spectraglass/db`) |
| BLE glasses transport + spectrum parser | `lib/services/bluetooth_camera_service.dart` |
| Corpus JSONs | `assets/docs/periodic_table.json` (119), `common_compounds.json` (110), `lab_safety.json` (GHS01–09) |
| Secrets resolution | `lib/config/app_secrets.dart` (Prefs → `assets/config/secrets.json` → `--dart-define`) |

## Corpus editing rules

- `common_compounds.json` entries: keep `name` first, `cas` right after `name` (the backfill tool preserves this order). Field order and 2-space indent are load-bearing for clean diffs.
- After any corpus change, run the CAS dry-run and the full test suite; tests pin known values (e.g. Water `7732-18-5`, hydrates must not collapse to anhydrous CAS, mixtures must never inherit a component CAS such as iron `7439-89-6` for steel).
- Element data uses Kelvin (`melt_K`, `boil_K`) with conversion done in the formatter — do not pre-convert.

## Testing expectations

- New services get unit tests; user-facing widgets get widget tests where feasible. Tests must pass with network disabled (`allowNetwork: false` patterns exist in `docs_search_and_fact_checker_test.dart`).
- Database-dependent tests use the `file_json` fallback engine — do not make tests require Android SQLite.
- If you change the YOLO channel contract, update `test/` and the docs (`docs/ARCHITECTURE.md`, `tooling/README.md`) in the same PR.

## Git workflow

- Branch from fresh `main`, one logical change-set per PR, merge with the merge method (no squash), delete branches after merge.
- Bump `pubspec.yaml` version + `assets/version.json` when the release changes; stamp the short sha into `version.json` in a follow-up commit.
- Commit message convention: `type(scope): summary` — e.g. `fix(v5.5.2): ...`, `feat(v5.5.2): ...`, `docs: ...`.
- Never commit real API keys (`assets/config/secrets.json` is git-ignored; only the `.example.json` template is tracked).

## Documentation duties

User-visible behavior changes update, in the same PR: `README.md` status/benchmark rows when applicable, `docs/ARCHITECTURE.md` for pipeline/schema changes, `WORKLOG.md` (append a dated entry), and `docs/BENCHMARKS.md` if a number changed from pending to measured. Docs contain no emojis and use Phosphor icons from `docs/assets/icons/`.
