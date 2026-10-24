# SpectruLenPor — Smart glasses for spectrum analysis and detection of chemical elements and compounds

**النظارة الذكية لتحليل الطيف واكتشاف العناصر والمركبات الكيميائية**

Flutter (Android) app + ESP32-CAM firmware + UV/IR sensors for smart scientific
glasses: the glasses capture (camera + UV/IR sensors) and stream over
Bluetooth, the **phone does all processing** (per the project design), a
specialized ONNX Runtime Mobile model produces the analysis, an LLM only
presents it nicely, and everything is narrated with **bilingual voice output**
(Arabic / English) with hazard alerts.

> Project by **Malak Adel Sayed Hassan** · Grade 1 secondary, Class 3/1 ·
> Ashmounin Secondary School · Budget: **2,500–6,000 EGP**

---

## Architecture (matches the paper)

```
النظارة (المستشعرات)  ⇒  ESP32-CAM  ⇒  الهاتف  ⇒  المساعد الصوتي
(glasses/sensors)        (data)        (phone)      (AI voice)

[ESP32-CAM + OV2640 + UV sensor (GPIO12) + IR sensor (GPIO13)]
        │  BLE: JPEG frames (~1 fps) + telemetry "$UV:1234;IR:567" @5Hz
        ▼
[ANDROID PHONE — all processing, this app]
        ├─ 0. Phone-camera source — demo mode, works with NO hardware
        ├─ 1. BluetoothCameraService   frames + sensor packets + commands
        ├─ 2. OnnxVisionService        SPECIALIZED MODEL (the analyst)
        │        ONNX Runtime Mobile · int8-quantized · 4 threads ·
        │        full graph optimization · background-isolate preprocessing
        ├─ 3. LocalVisionService       ONNX → Moondream2 (JNI/llama.cpp) → ML Kit
        ├─ 4. Hazard engine            keywords (AR/EN) + UV/IR thresholds
        ├─ 5. NativeTtsService         speaks the label INSTANTLY (offline)
        └─ 6. OpenRouterService        LLM presentation pass (short prompt,
                 streaming, sentence-by-sentence TTS — first audio ≈1s)
```

**Division of labor (latency design):**

| Stage | Engine | Latency |
|---|---|---|
| Analyze (fact/label) | Specialized ONNX model, on-device | <100 ms |
| Describe instantly | Android TTS (offline) | ~0 ms after analysis |
| Present nicely | OpenRouter LLM — presenter only, `max_tokens≈380` | first token ≈1s, spoken per sentence |
| Hard reasoning (optional) | Moondream2 VLM via native llama.cpp | seconds, off the hot path |

The LLM **never** invents the analysis — it rephrases the specialized model's
top-3 predictions + UV/IR telemetry into clear spoken language, and adds a
`Warning:` line that triggers the red hazard banner.

---

## What makes the app real & working today

* **Phone camera mode (default)** — install, open, point at anything: the
  pipeline runs end-to-end on the phone camera (ONNX/ML Kit → TTS → OpenRouter).
  No ESP32 hardware needed to demo.
* **Glasses mode** — one tap switches the source to the BLE glasses feed.
* **Bilingual, RTL** — one-tap EN ⇄ العربية toggle (app bar + settings);
  Arabic narration uses `ar-EG`; UI flips direction automatically.
* **Spectrum panel** — live UV/IR gauges from the glasses, state-of-matter
  chip (solid/liquid/gas parsed from the AI analysis), ONNX top-3 confidence
  bars.
* **Hazard alerts** — red pulsing banner + repeated voice warning when the AI
  reply or sensors signal danger (toxic / flammable / corrosive / UV & IR
  thresholds). Arabic keywords supported.
* **Flashlight** — app-bar torch button: drives the glasses' onboard flash
  LED over BLE (0x03/0x04) or the phone torch in phone mode — for dim labs.
* **Latency transparency** — the app shows its own time-to-first-audio-token.

---

## Repository layout

```
smart_glass_app/
├── pubspec.yaml                      # onnxruntime, flutter_localizations, …
├── lib/
│   ├── main.dart                     # providers + locale (ValueNotifier) + routes
│   ├── models/
│   │   ├── frame_data.dart           # one frame (JPEG) from either source
│   │   ├── spectrum_reading.dart     # UV/IR telemetry, state-of-matter, hazard keywords
│   │   └── recognition_state.dart    # central state machine (Provider)
│   ├── services/
│   │   ├── bluetooth_camera_service.dart  # BLE client + telemetry parse + commands
│   │   ├── phone_camera_service.dart      # phone camera source (YUV→JPEG isolate)
│   │   ├── onnx_vision_service.dart       # ★ ONNX Runtime Mobile specialized model
│   │   ├── local_vision_service.dart      # ONNX → Moondream → ML Kit cascade + OCR
│   │   ├── openrouter_service.dart        # streaming presenter pass (EN/AR)
│   │   ├── native_tts_service.dart        # Android TTS (ar-EG / en-US)
│   │   └── openrouter_tts_service.dart    # optional premium TTS endpoint
│   ├── screens/ (home, settings)
│   ├── widgets/ (camera preview, spectrum card, hazard banner, …)
│   └── utils/   (app_theme, strings — full EN/AR table)
├── android/app/src/main/
│   ├── AndroidManifest.xml           # BLE 12+, location, internet, TTS
│   ├── kotlin/com/spectraglass/app/  # MainActivity + MoondreamChannel.kt
│   └── cpp/                          # moondream_jni.cpp + CMakeLists.txt
├── firmware/esp32cam_glasses_firmware.ino  # v2.0: frames + UV/IR telemetry + flash LED
└── tooling/convert_mobilenet_onnx.py       # export + int8-quantize + labels
```

---

## 1. Build the phone app

```bash
flutter pub get
flutter run            # phone camera mode works immediately
flutter build apk --release
```

Android 7+ (API 24). First launch requests camera + nearby-devices permissions.

### Add the specialized ONNX model (recommended)

The app ships with ML Kit as fallback, but the *specialized* analysis path
needs the quantized model:

```bash
pip install torch torchvision onnx onnxruntime
python tooling/convert_mobilenet_onnx.py --output_dir ../smart_glass_app/assets/models
flutter build apk
```

To make it truly *scientific*, fine-tune MobileNetV2 on your own lab-equipment
/ chemical-bottle dataset (folders per class, ~200 photos each) and re-run the
same script — the Dart side needs zero changes.

## 2. Flash the glasses (ESP32-CAM)

1. Arduino IDE + esp32 boards package. Board: *AI Thinker ESP32-CAM*.
2. Open `firmware/esp32cam_glasses_firmware.ino`, flash (GPIO0→GND during upload).
3. Wire sensors: UV analog out → **GPIO12**, IR analog out → **GPIO13**
   (both ADC2, 12-bit 0–4095). Flash LED is the onboard GPIO4.
4. The glasses advertise as **`SpectruLenPor-ESP32`**.

BLE protocol:

| UUID / byte | Meaning |
|---|---|
| Service `ffe0` · TX `ffe1` (notify) · RX `ffe2` (write) | GATT contract |
| `FFD8 … FFD9` chunks | JPEG frame reassembly |
| `$UV:1234;IR:567\n` | UV/IR telemetry packet (5 Hz) |
| `0x01 / 0x00 / 0x02` | stream on / off / single frame |
| `0x03 / 0x04` | flashlight ON / OFF |

## 3. Moondream native build (optional VLM upgrade)

The Dart side already calls the platform channel; to build the native engine:

```bash
cd android/app/src/main/cpp
git clone --depth 1 --recursive https://github.com/ggerganov/llama.cpp
```

1. Wire `CMakeLists.txt` via `android/app/build.gradle.reference` (merge into
   your generated app/build.gradle, namespace `com.spectraglass.app`).
2. Push `moondream2-Q4_K_M.gguf` + `mmproj-model-f16.gguf` to the device.
3. In app code: `LocalVisionService.instance.enableMoondream('/path/to/model.gguf')`.
4. Build (arm64-v8a). First inference loads the model (~10 s), then ~1.5–3 s
   per caption.

Until deployed, the cascade is: **ONNX → (Moondream when present) → ML Kit**,
so nothing blocks without it.

---

## Cost (from the project paper — EGP)

| Item | Price (EGP) |
|---|---|
| ESP32-CAM module (AI-Thinker + OV2640) | ~600 |
| UV sensor (GUVA-S12SD) + IR sensor (analog) | ~350 |
| FTDI / USB-TTL flashing adapter | ~200 |
| TP4056 charging module + lithium battery | ~250 |
| Glasses frame + mount + wiring | ~350 |
| Processing (existing Android phone) | 0 |
| **Software & AI** (Flutter, ONNX Runtime, ML Kit, llama.cpp, OpenRouter free tier) | **0** |
| **Total** | **≈ 1,750 EGP** (fits the 2,500–6,000 EGP budget with spare for iteration) |

## Roadmap (mirrors the paper)

- [x] Phone-camera demo mode · bilingual voice · hazard alerts · flashlight
- [x] ONNX Runtime Mobile specialized-model pipeline
- [x] UV/IR telemetry + state-of-matter + hazard thresholds
- [ ] UV/IR spectral dispersion unit (mini) for element fingerprints
- [ ] Cloud session sync + analysis history
- [ ] Voice commands ("ما هذه؟" / "read that label")
- [ ] Titanium frame prototype
