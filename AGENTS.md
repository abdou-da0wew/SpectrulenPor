# AGENTS.md — contributor & coding-agent handbook

<img src="https://cdn.jsdelivr.net/npm/@phosphor-icons/core@2.1.1/assets/regular/wrench.svg" width="15" align="absMiddle" alt="wrench icon"> How to work in this repository as a human contributor or an automated coding agent: environment, commands, conventions, boundaries, and the merge workflow.

---

## What this repo is

**SpectruLenPor** (`com.spectraglass.app`) — a bilingual EN/AR Flutter Android app + ESP32-CAM BLE smart-glasses platform for real-time YOLO26-Nano detection and grounded chemical/spectral analysis. Read [`CONTEXT.md`](CONTEXT.md) first for facts and invariants, and [`README.md`](README.md) for the big picture. [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) is the deep spec.

## Environment

| Requirement | Value |
|---|---|
| Flutter | stable ≥ 3.47 (3.47.9 verified) |
| Dart | ≥ 3.13 |
| Android toolchain | JDK 17, compileSdk 36, minSdk 31 — only needed for APK builds |
| Python | 3.9+ for `tooling/` scripts |

One-command Flutter installs (Windows PowerShell / Linux) are documented in [`README.md`](README.md#install-flutter-in-one-command).

## Everyday commands

```bash
flutter pub get          # resolve deps
flutter analyze          # must stay at 0 errors (warnings/infos: fix or justify)
flutter test             # must stay green — 92 tests as of v5.5.1
flutter run              # launch on a device
flutter build apk --release
flutter build web --release   # UI-shell build; native tiers are Android-only
```

Corpus maintenance:

```bash
python3 tooling/backfill_cas_pubchem.py            # CAS dry-run report
python3 tooling/backfill_cas_pubchem.py --write    # apply verified CAS values
python3 tooling/export_yolo26_mobile.py --help     # YOLO export ladder
```

## Non-negotiable conventions

1. **No emoji anywhere** — not in code, comments, UI strings, docs, or commit messages. Icons are Material Icons in-app (`Icons.*`) and [Phosphor icons](https://github.com/phosphor-icons/core) via jsDelivr CDN (`https://cdn.jsdelivr.net/npm/@phosphor-icons/core@2.1.1/assets/regular/<name>.svg`) in Markdown. Verify an icon URL returns HTTP 200 before embedding it.
2. **Badges are shields.io `flat-square`** style. Dynamic badges only for facts GitHub can see (last commit, issues); static badges for measured facts.
3. **Honesty policy for benchmarks**: never write a number you did not measure. Mark rows `Measured`, `Implemented — pending device`, or `Not tested here`. The benchmark table in `README.md` is the single source of truth.
4. **Zero-guessing data discipline**: CAS numbers come from `tooling/backfill_cas_pubchem.py` (PubChem, checksum-validated) — never hand-typed. AI prompts must keep the target-limited / zero-guessing / citation-discipline rules intact; if you touch `openrouter_service.dart` or `moondream_service.dart`, re-run the prompt-related tests.
5. **Secrets never enter git**: keys resolve Prefs → `assets/config/secrets.json` (gitignored) → `--dart-define`. Never log tokens; redact any `ghp_…` token in command output before pasting it anywhere.
6. **L10n completeness**: every user-facing string goes into `app_en.arb` AND `app_ar.arb`; the l10n test fails on empty keys or untranslated Arabic.
7. **Tests before PR**: `flutter analyze` and `flutter test` must pass. New services need at least happy-path + failure-path tests.
8. **Docs update with code**: behavior changes update the relevant doc in the same PR (`ARCHITECTURE.md`, `firmware/README.md`, `tooling/README.md`), and append a dated entry to [`WORKLOG.md`](WORKLOG.md).

## Branch & merge workflow

The project uses a short-lived branch → PR → merge flow (history: PR #3, #4, #5):

1. Branch from latest `main`: `git checkout -b <area>/<vN.N.N-topic> main`
2. Commit with conventional prefixes: `feat(...)`, `fix(...)`, `docs(...)`, `chore(...)`.
3. Push, open a PR against `main`, keep it in one logical unit, merge with a merge commit (not squash) so the feature + fix chain stays readable.

## Where things live

| Area | Path | Notes |
|---|---|---|
| UI (EN/AR RTL) | `lib/screens/`, `lib/widgets/`, `lib/l10n/` | state via `RecognitionState` + provider |
| Vision pipeline | `lib/services/vision_gate.dart`, `local_vision_service.dart`, `yolo_detector.dart` | on-device tiers |
| Cloud AI | `lib/services/moondream_service.dart`, `openrouter_service.dart`, `openrouter_tts_service.dart` | strict prompt rules |
| Native Android | `android/app/src/main/kotlin/com/spectraglass/app/` | `YoloInferenceChannel`, `AppDatabaseChannel`, `FlashlightChannel`, `MoondreamChannel` |
| BLE glasses | `lib/services/bluetooth_camera_service.dart` + `firmware/` | shared GATT contract, must stay in sync |
| Persistence | `lib/services/internal_db_service.dart`, `android/.../AppDatabaseChannel.kt` | 9 tables, SQLite WAL, memory/file fallback |
| Knowledge corpus | `assets/docs/` + `lib/services/docs_search_service.dart` | 119 elements / 110 compounds / GHS |
| Tooling | `tooling/` | YOLO export, CAS backfill, classifier conversion |
| Tests | `test/` | models, services, l10n, widgets |

## Diagrams & screenshots

Architecture visuals are built with the [diagram-design](https://github.com/cathrynlavery/diagram-design) editorial system as self-contained HTML in [`docs/diagrams/`](docs/diagrams/) and exported to PNG for README embedding. In-app screenshots are captured by serving a `flutter build web` output and screenshotting a headless browser at a 412×915 phone viewport — keep the method reproducible, and never paste mockups in place of real screens.
