# Vision Model Tooling (`tooling/`)

## Build-time version metadata

Use the wrapper for Flutter builds and runs:

- ./tooling/flutter_with_metadata.sh build apk
- ./tooling/flutter_with_metadata.sh build web --release
- ./tooling/flutter_with_metadata.sh run

It injects the package version/build number, current Git commit, branch, dirty
working-tree state, and UTC build timestamp through --dart-define. The
checked-in assets/version.json intentionally contains only the package
version and build number. A direct flutter build that bypasses the wrapper
shows source-control metadata as unavailable instead of displaying a stale
commit or claiming the tree is clean.

## Live OpenRouter model smoke test

The authenticated smoke test sends one streamed scientific-analysis prompt to each configured model independently and asserts that the requested model actually served the response (rather than a later fallback):

```bash
export OPENROUTER_TEST_API_KEY='your-rotated-openrouter-key'
flutter test --no-pub --concurrency=1 test/live_openrouter_models_test.dart
unset OPENROUTER_TEST_API_KEY
```

The test is skipped when the environment variable is absent. Never put an API key in source control, test output, or a command transcript.

## 1. Primary On-Device Object Detector: `assets/models/yolo26n.onnx`

SpectruLenPor ships **YOLO26-Nano** (`assets/models/yolo26n.onnx`, `5,040,902` bytes) pre-bundled in the app assets and executes it locally via `com.microsoft.onnxruntime:onnxruntime-android:1.22.0` (`YoloInferenceChannel.kt`).

- **Input**: `images` — `FLOAT32 [1, 3, 640, 640]` (NCHW RGB `0..1`, `114/255` letterbox pad)
- **Output**: `output0` — `FLOAT32 [1, 300, 6]` (`[x1, y1, x2, y2, score, class_id]`, `end2end=True`, 80 COCO classes)
- **First-Startup Staging & Auto-Download**: On first app launch, `YoloInferenceChannel` copies the bundled asset into `filesDir/models/yolo26n.onnx`, validates size/header integrity, and automatically downloads a fresh copy over HTTPS if missing or corrupted. Users can also re-verify at any time from **Settings → Verify / Stage YOLO26-Nano**.

## 2. Optional Custom Offline Classifier: `convert_mobilenet_onnx.py`

When **Cloud-only models (except YOLO26-Nano)** is turned **OFF**, `LocalVisionService` can optionally consult a custom quantized MobileNetV2 ONNX classifier for specialized labware or reagent-bottle datasets:

```bash
pip install torch torchvision onnx onnxruntime
python3 tooling/convert_mobilenet_onnx.py --output_dir assets/models
```

## 3. CAS Registry Backfill: `backfill_cas_pubchem.py`

Populates the `cas` field of the bundled corpora from **PubChem** (PUG REST + PUG-View). 108 of the 110 compounds in `common_compounds.json` carry a CAS Registry Number; the two true mixtures (borosilicate glass, 304 stainless steel) carry `cas_skip: true` + a `cas_note` and are skipped before any query — a name variant can silently resolve to a single component (e.g. steel → iron), so flagged entries can never be poisoned by a re-run.

```bash
python3 tooling/backfill_cas_pubchem.py                 # dry run, full report
python3 tooling/backfill_cas_pubchem.py --write         # apply changes
python3 tooling/backfill_cas_pubchem.py --file assets/docs/periodic_table.json  # other corpus
python3 tooling/backfill_cas_pubchem.py --limit 5       # smoke test
python3 tooling/backfill_cas_pubchem.py --refresh --write   # re-query everything
python3 tooling/backfill_cas_pubchem.py --set "Glucose=50-99-7" --write  # verified pin
```

**How a CAS is accepted (no-guessing discipline, same as the AI prompts):**

1. PubChem resolves the compound *name* (with parenthetical-synonym variants) to a CID; formula fallback additionally requires the corpus name to appear among the record's synonyms.
2. Primary source: the record's curated **CAS section (PUG-View)** — a candidate backed by a **CAS Common Chemistry** citation wins; among several, it needs **2x citation-frequency dominance** (isotopologue and historical variants always lose that race).
3. Fallback: exactly **one** checksum-valid CAS among all record synonyms; multiple distinct candidates ⇒ reported `AMBIGUOUS`, nothing written.
4. Every candidate passes the official **CAS check-digit** validation before it is written.

Rate-limited to ~3.3 req/s (PubChem's limit is 5) with 429/503/504 exponential-backoff retries. Polymers (PET `25038-59-9`, PP `9003-07-0`, PC `25766-59-0`, cellulose `9004-34-6`) have no PubChem compound records — they were verified out-of-band (Wikipedia infoboxes / Wikidata P231) and pinned via `--set`, which the tool records as `PIN` in its report.

**In-app surfacing** (`DocsSearchService`): a query that normalizes to a bundled CAS (`7732-18-5`, `7732 18 5`) resolves the compound as the **top hit**, and every compound citation snippet now includes `CAS: <number>` (mixtures render `CAS: not applicable - <cas_note>`) so the AI answer pipeline can cite exact registry numbers instead of hallucinating them.

## 4. In-Browser Screenshot Capture: `make_fake_camera_scene.py` + `take_web_screenshots.py`

The README screenshots are real app screens captured by launching the Flutter Web build in a phone-layout headless Chromium (412×915 CSS @2x, touch emulation):

```bash
flutter build web --release
python3 -m http.server 8123 -d build/web &
python3 tooling/make_fake_camera_scene.py     # writes /tmp/lab_scene.y4m (lab desk scene)
python3 tooling/take_web_screenshots.py       # captures docs/screenshots/*.png
```

Chromium's fake camera (`--use-file-for-fake-video-capture`) plays the generated lab-scene video so the live-detection screenshots show a realistic preview; the Arabic RTL shot is taken by tapping the app-bar language toggle in-session. Requires `playwright` (Python) with its Chromium installed.
