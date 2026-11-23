# Contributing to SpectruLenPor

Thanks for your interest in improving this student research project.

Project author: Malak Adel Sayed Hassan. Software and firmware developer and
original code author: **Abdoul-Rahman Ayman** (`abdou-da0wew`).

## How to contribute

1. Fork / branch from a fresh `main`.
2. Read `AGENTS.md` first — it lists the non-negotiable rules (no fabricated scientific data, no emojis anywhere, bilingual EN/AR parity for user-facing strings, privacy defaults).
3. Keep every PR one logical change-set; run and pass before opening:

   ```bash
   flutter pub get
   flutter analyze   # 0 errors / 0 warnings
   flutter test      # all green
   ```

4. CI runs `flutter analyze` + `flutter test` on every push and PR — both must pass.
5. Update docs in the same PR when behavior changes (`README.md` status rows, `docs/ARCHITECTURE.md`, `docs/BENCHMARKS.md`, `WORKLOG.md` with a dated entry).

## Areas where help is most useful

- On-device benchmark runs (detection latency, EP timings) recorded in `docs/BENCHMARKS.md`.
- ESP32-CAM firmware bench testing against real hardware.
- Arabic (RTL) translation and UX review.
- LiteRT/INT8 export ladder work (see `docs/YOLO26_MOBILE_OPTIMIZATION.md`).

## Scientific data policy

Corpus values (CAS numbers, element properties, hazard classes) must come from the bundled corpus or a verified PubChem query via `tooling/backfill_cas_pubchem.py`. Never hand-edit a CAS into the JSON.

## License note

The project currently has no open-source license (all rights reserved by the authors). By contributing you agree that your work is offered under the terms the authors eventually choose for the repository.

## Project authorship

Malak Adel Sayed Hassan is the project author. Abdoul-Rahman Ayman (`abdou-da0wew`) is the main software and firmware developer and author of the original application and firmware code. Third-party libraries and upstream components retain their
own authorship and license notices.

## Commit message co-author hook

This repository includes a commit-message hook that preserves the DiveeAgent co-author trailer. Enable it in each clone with:

```bash
git config core.hooksPath .githooks
```

The hook adds the trailer only when it is missing, so repeated runs do not create duplicates.
