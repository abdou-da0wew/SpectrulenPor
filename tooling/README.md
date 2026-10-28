# Vision Model Tooling (`tooling/`)

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
