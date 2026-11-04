# YOLO26-Nano on Mobile — Speed & Accuracy Optimization Guide (SpectruLenPor)

This document is the deep-dive companion to the v5.5.1 accuracy/speed work. It
explains **what was already implemented in the app**, **why the raw-ONNX-on-CPU
approach was slow**, and **the full upgrade ladder** from "ONNX on CPU" to
"NPUs and INT8" — with exact export commands (`tooling/export_yolo26_mobile.py`).

---

## 1. What the app already does now (v5.5.1)

| Layer | Change | Effect |
|---|---|---|
| Execution provider auto-benchmark | `YoloInferenceChannel.kt` now benchmarks **CPU**, **NNAPI + FP16** and **XNNPACK** sessions with the real model at startup (2 warmup runs each) and keeps the fastest working one | On Snapdragon/MediaTek devices the NNAPI EP typically offloads convs to the GPU/DSP — 2–6× faster than plain CPU; if NNAPI partitioning is slow on a given SoC, the benchmark simply keeps CPU. Zero-risk: every EP failure falls back |
| Parameterized input size | `inputSize` parsed from the model graph (`session.inputInfo`), replacing the hard-coded 640 | Drop in a 512/960/1024-exported model and pre/post-processing just works |
| Latest-frame pipelining | `RecognitionState._runYoloDetection` never queues: while one inference runs, newer frames supersede queued ones (newest wins); boxes stay until replaced | No stale-box lag after fast pans; UI always shows the most recent analysis |
| Instant scene-change invalidation | `VisionGateResult.signature` = 8×8 block-mean luma (computed for free in the existing 64×64 gate pass); `RecognitionState` compares consecutive signatures and **drops all boxes + selection instantly** when mean diff > 15 | A 180° camera swing clears old boxes on the very next gated frame — they never appear over the new scene |
| Staleness guard | Boxes older than 2.5 s without a detection result are cleared | Disconnected glasses / stalled inference can't leave ghost boxes |
| Blocked/blank frame clearing | Lens-covered, blank or undecodable frames clear boxes immediately | No overlays over a pocketed lens |
| Auto-torch hysteresis | Torch engages below luma 38, releases only above **70** (was: release at ≥38 → on/off flicker) | Torch turns off when frames are bright again, without oscillating at the boundary |
| Higher default fps | Detection loop default 2 fps (was 1), max 4 | Faster box refresh at modest battery cost; combine with the EP win |

**Status surface:** Settings → engine status now shows `executionProvider`
(`cpu` / `nnapi_fp16` / `xnnpack`), `epBenchmarkMs` and `inputSize`.

---

## 2. Why "ONNX" was not the mistake — running it CPU-only was

Raw ONNX is just a graph format. The performance problem was that the session
was opened with **no execution provider configuration**, so
`onnxruntime-android` executed everything on 4 CPU threads and never touched
the GPU/NPU/DSP. The fixes, in increasing effort:

1. **NNAPI EP + FP16 (implemented)** — `addNnapi(EnumSet.of(NNAPIFlags.USE_FP16))`
   lets ORT partition the graph and run supported ops on accelerator-backed
   drivers. FP16 halves memory bandwidth; detection is tolerance-robust to it.
   *Caveats:* NNAPI is deprecated in Android 15+ (still functional); end-to-end
   NMS ops (TopK/NonMaxSuppression) usually stay on the CPU partition — that's
   fine, the conv backbone is the expensive part. Some SoCs partition badly —
   hence the benchmark instead of a blind switch.
2. **XNNPACK EP (implemented as a candidate)** — optimized CPU kernels,
   especially for ARM; often 1.2–1.8× over the default CPU path.
3. **INT8 quantization (tooling provided)** — `quantize=8` with a calibration
   dataset. ~4× smaller, big integer-domain speedups on NPUs via NNAPI, minor
   mAP loss (~0.5–2% typical). Verify mAP on your validation set before
   shipping.
4. **LiteRT (TFLite) migration (path documented)** — `format="litert"` +
   the LiteRT interpreter with GPU/NNAPI delegates is the first-class Android
   acceleration path. Requires adding a TFLite runtime + a new inference
   channel (`YoloLiteRtChannel.kt`) and switching pre/post-processing to the
   TFLite head layout. Worth it if NNAPI-through-ORT underperforms on your
   target devices.
5. **ExecuTorch / XNNPACK (export supported)** — best for future native C++
   builds or non-Android edge targets.

---

## 3. Accuracy at nano scale

### 3.1 Input resolution (`imgsz`) — the single biggest lever
| imgsz | Relative speed | Small-object recall | Use when |
|---|---|---|---|
| 320 / 416 | ~3–5× faster than 640 | noticeably worse | max speed, large objects |
| **640** | baseline | baseline | default, general lab scenes |
| 960 / 1024 | ~2–2.6× slower | substantially better on small/distant items | crystals, small labels, thin glassware |

Export at the new size and the app picks it up automatically from the graph
(`inputSize` is read at session creation; letterbox math and coordinate
un-projection derive from it). If you go above ~960 on low-end devices, watch
`epBenchmarkMs` — drop to 640 or switch EP if inference exceeds ~150 ms.

### 3.2 Fine-tune with MuSGD + domain augmentation
YOLO26's MuSGD optimizer (SGD stability + Muon-style updates) improves
generalization at no parameter cost. For the lab-glasses domain:

```bash
yolo detect train model=yolo26n.pt data=lab_glasses.yaml epochs=120 \
  imgsz=640 optimizer=auto lr0=0.001 mosaic=1.0 close_mosaic=10 \
  hsv_s=60 hsv_v=60 degrees=10 flipud=0.3 fliplr=0.5 scale=0.4
```

- `hsv_s/hsv_v` — lab lighting shifts, colored solutions, dim cabinets
- `degrees=10, flipud` — handheld camera held at odd angles / upside-down captures
- `scale=0.4` — objects at very different distances (glasses vs phone camera)
- <1,000 images: fewer epochs, explicit `optimizer=AdamW, lr0=0.001` per the
  Ultralytics small-dataset recipe

Label the *chemical-relevant* classes you actually need; COCO's 80 classes
already cover bottles/cups/forks/scissors/cell phones.

### 3.3 Tiny objects in high-res frames → tiled inference (SAHI)
If you later need to detect a crystal grain in a 4K still, slice the frame
into overlapping tiles and run detection per tile (SAHI library), then
re-project boxes. Not implemented in the live loop (latency), but useful for
the user-gated capture path.

---

## 4. Exact export commands

Everything is wrapped in `tooling/export_yolo26_mobile.py`:

```bash
pip install "ultralytics>=8.4.0" onnx onnxslim

# Full set for the current app (ONNX end2end, fixed 640):
python tooling/export_yolo26_mobile.py --weights yolo26n.pt --imgsz 640

# Accuracy-oriented model for small lab objects + INT8 calibration set:
python tooling/export_yolo26_mobile.py --weights best.pt --imgsz 960 \
    --data lab_glasses.yaml --int8 --only onnx,litert

# iOS / cross-platform artifacts:
python tooling/export_yolo26_mobile.py --only coreml,executorch
```

Raw Ultralytics equivalents:

```python
from ultralytics import YOLO
m = YOLO("yolo26n.pt")
m.export(format="onnx",  imgsz=640, half=True, simplify=True, nms=True, dynamic=False)
m.export(format="litert", imgsz=640, quantize=8, data="coco8.yaml", nms=True)
m.export(format="coreml", imgsz=640, quantize=16, nms=True)
m.export(format="executorch", imgsz=640)
```

Contract the app relies on: **fixed square input** `[1,3,S,S]` (required by the
NNAPI EP), **end-to-end head** `[1,300,6]` rows `[x1,y1,x2,y2,score,class_id]`
(`nms=True`), Ultralytics `names` metadata embedded (labels parsed natively).

---

## 5. Benchmark methodology

1. `adb install` the release APK on the target device (battery > 50%, no
   thermal throttling for 2 min).
2. Settings → "Verify / Stage YOLO26-Nano" re-runs provisioning; then check
   Diagnostics → Traces for `yolo.detect` spans, or read the Settings engine
   row: `executionProvider (epBenchmarkMs)`.
3. Compare `lastInferenceMs` across: EP winner, `imgsz`, FP32 vs INT8 model.
4. Repeat 3× per device class (flagship / mid / low-end). Decide per-device?
   No — the app benchmarks at every startup, so it self-tunes per device.

---

## 6. Deferred / not done (and why)

- **TFLite interpreter integration**: real win, but adds a runtime + a new
  channel + head-format handling; the ORT NNAPI/XNNPACK benchmark closes most
  of the gap first. Revisit if `epBenchmarkMs` stays >150 ms on your fleet.
- **INT8 in-app**: the model file is a drop-in replacement once exported with
  `quantize=8` (pre/post-processing unchanged) — measure mAP, then bundle.
- **GPU EP (OpenCL/Vulkan)**: ORT-android's base AAR doesn't ship a Vulkan EP;
  NNAPI covers the same hardware through vendor drivers.
