# SpectruLenPor Benchmark Framework

This directory defines repeatable performance and accuracy measurements for the Flutter app, native Android runtime, speech engines, OpenRouter models, and vision pipeline.

## Layers

1. **AndroidX Macrobenchmark** (android/macrobenchmark): real-device cold/warm startup timing, frame timing/jank, and memory measurements against a non-debuggable release-equivalent benchmark build type. AndroidX writes per-iteration metrics and Perfetto traces.
2. **In-app Benchmark Lab** (Settings → Data → Benchmark Lab): deterministic Arabic/English speech-correction golden corpus, p50/p95 latency, WER/CER, OpenRouter fixed-answer latency/pass-rate smoke tests, Supertonic ONNX synthesis latency/real-time factor, and Android runtime/device snapshot.
3. **Dataset scoring** (tool/benchmark/score_corpus.py): WER/CER for paired STT transcripts and IoU/precision/recall/AP@0.50 for labelled vision predictions.

The in-app OpenRouter score is deliberately called a fixed-answer task pass rate. It is not general model accuracy. Likewise, model runtime telemetry is not a substitute for labelled-dataset accuracy.

## Build the dedicated benchmark artifacts

From the repository root:

    cd android
    ./gradlew :app:assembleBenchmark :macrobenchmark:assembleBenchmark

Expected artifacts:

- Target app: app/build/outputs/apk/benchmark/app-benchmark.apk
- Instrumentation runner: macrobenchmark/build/outputs/apk/benchmark/macrobenchmark-benchmark.apk

The benchmark target is release-equivalent and non-debuggable. It is signed with the local debug key for repeatable local testing; do not distribute it as a production release.

## Run on a connected Android device

Enable USB debugging, connect the device, verify adb devices -l, then run:

    cd android
    ./gradlew :macrobenchmark:connectedBenchmarkAndroidTest

The tests measure:

- Cold app launch: StartupTimingMetric + MemoryUsageMetric
- Warm app launch: StartupTimingMetric + MemoryUsageMetric
- Repeated home gestures: FrameTimingMetric + MemoryUsageMetric

Macrobenchmark requires a profileable, non-debuggable target. The app manifest includes profileable android:shell="true" and the app includes ProfileInstaller. A physical device is strongly preferred; emulator graphics, thermal, and camera behavior are not representative of real glasses use.

## In-app measurements

Open Settings → Data → Benchmark Lab.

- Local suite: Android runtime snapshot + 12 bilingual correction golden cases; reports exact-match rate, WER, CER, p50/p95 latency, and throughput.
- OpenRouter: three bounded answer checks, time-to-first-token, total latency, and selected/fallback model ID.
- Supertonic: on-device English and Arabic ONNX synthesis latency, audio duration, output size, and real-time factor. It only runs after the model pack is installed.

JSON reports are saved under the app documents directory in benchmark-reports/, with a latest.json pointer. Use the copy button in the app to copy the full report.

## STT and vision accuracy corpora

Do not invent accuracy scores when no ground truth exists. The sample manifests under corpora/ define the expected schema.

- For STT, transcribe the paired WAV files with the selected engine, write each hypothesis into the manifest, then run the scorer. Report Arabic and English separately.
- For vision, run YOLO on each image, write predicted class IDs, confidence scores, and pixel-space [x1,y1,x2,y2] boxes into the manifest, then run the scorer. The scorer reports per-class AP@0.50 and aggregate precision/recall.
- For TTS naturalness/pronunciation, keep paired reference audio and collect blinded human ratings. Latency/RTF alone cannot establish speech quality.

Example:

    python3 tool/benchmark/score_corpus.py stt benchmarks/corpora/stt/manifest.example.json
    python3 tool/benchmark/score_corpus.py vision benchmarks/corpora/vision/manifest.example.json

## Reproducibility checklist

Record device model, Android API, app version/Git SHA, battery level, thermal state, active camera source, active model IDs, model pack revisions, and whether model sessions were cold or already loaded. Run at least 5–10 iterations and compare p50/p95, not a single best run. Keep the same device, build type, corpus version, lighting, distance, and thermal conditions when comparing revisions.
