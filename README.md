# SpectrulenPor — Smart Scientific Glasses

Flutter (Android) app + ESP32-CAM firmware for smart glasses that help visually
impaired users (and lab students) identify what is in front of them: the glasses
stream frames over Bluetooth, the phone runs local vision for instant labels,
OpenRouter free-tier models add deep reasoning, and everything is narrated
with text-to-speech.

> Project: *Smart glasses for analyzing substances and laboratory equipment*
> Elaf Al-Tai · Supervised by Dr. Khaled Sibakat · Computer Science 2025/2026

---

## Architecture

```
[Glasses: ESP32-CAM + OV2640]
        │  BLE GATT notifications (JPEG chunks, ~1 fps, QVGA)
        ▼
[Android phone — this Flutter app]
        │
        ├─ 1. BluetoothCameraService   reassembles JPEG chunks
        ├─ 2. LocalVisionService       ML Kit labeling + OCR (instant, offline)
        │        (optional: Moondream2 GGUF via platform channel)
        ├─ 3. NativeTtsService         speaks the label immediately
        │
        └─ 4. OpenRouterService        sends the TEXT label upstream
                 (google/gemini-2.5-flash:free …)
                 ├─ streams markdown deep-reasoning into the UI
                 └─ OpenRouterTtsService reads it aloud (optional)
```

Key design decisions (from the project notes):

* **Text-only upstream** — the phone sends only the local vision *description*
  (a sentence) to OpenRouter, never the image. This keeps requests tiny, works
  with free text-only models, and keeps latency low.
* **1 fps default throttling** — the BLE link and battery cannot sustain 30 fps;
  frames are throttled (1–4 fps, adjustable in Settings).
* **Dual TTS** — Android native TTS for instant labels (offline, zero latency);
  optional OpenRouter-compatible `/audio/speech` endpoint for premium narration
  of the deep-reasoning text.

---

## Repository layout

```
smart_glass_app/
├── pubspec.yaml                  # dependencies
├── lib/
│   ├── main.dart                 # app bootstrap + Provider wiring
│   ├── models/
│   │   ├── frame_data.dart       # one BLE-reassembled JPEG frame
│   │   └── recognition_state.dart# central state machine (Provider)
│   ├── services/
│   │   ├── bluetooth_camera_service.dart # ESP32-CAM BLE client
│   │   ├── local_vision_service.dart     # ML Kit + Moondream hook
│   │   ├── openrouter_service.dart       # streaming deep reasoning
│   │   ├── native_tts_service.dart       # Android TTS (offline)
│   │   └── openrouter_tts_service.dart   # optional premium TTS
│   ├── screens/
│   │   ├── home_screen.dart      # main UI
│   │   └── settings_screen.dart  # API key / model / TTS / fps
│   ├── widgets/                  # camera preview, label chip, info card…
│   └── utils/
│       └── app_theme.dart        # dusty-mauve/lavender brand palette
├── android/app/src/main/AndroidManifest.xml
└── firmware/
    └── esp32cam_glasses_firmware.ino   # ESP32-CAM BLE streaming sketch
```

---

## 1. Build the phone app

```bash
flutter pub get
flutter run                # debug on a connected Android device
flutter build apk --release
```

Minimum Android 6 (API 23). The app requests on first launch: Bluetooth scan /
connect, nearby-devices location (Android 6–11), and camera (dev fallback).

### Configure

1. Open the app → **Settings** (gear icon, top right).
2. Paste your free **OpenRouter API key** (`openrouter.ai/keys`).
3. Pick an upstream model (Gemini 2.5 Flash free is the default).
4. Optionally enable **OpenRouter TTS** and set a voice.

## 2. Flash the glasses (ESP32-CAM)

1. Install the Arduino IDE + **esp32 by Espressif** boards package.
2. Board: *AI Thinker ESP32-CAM*. Connect via FTDI (5 V, GPIO0→GND to flash).
3. Open `firmware/esp32cam_glasses_firmware.ino`, flash, open Serial Monitor.
4. The glasses advertise as **`SpectraGlass-ESP32`**.

BLE protocol (matches `bluetooth_camera_service.dart`):

| UUID | Role |
|---|---|
| Service `ffe0` | GATT service |
| Char `ffe1` | notify — JPEG chunk stream |
| Char `ffe2` | write — `0x01` stream on, `0x00` off, `0x02` single frame |

Frames are QVGA (320×240) JPEG, quality 14, sent in 500-byte chunks; the phone
reassembles on JPEG SOI/EOI markers.

## 3. Run the pipeline

1. Tap **Connect glasses** — the app scans and connects automatically.
2. The preview fills in as frames arrive (~1 fps).
3. Each classified frame is spoken immediately and (if enabled) forwarded
   upstream; the deep-reasoning card streams in below with *What it is /
   Why it matters / Practical tips / Explore*.
4. **Describe now** forces an instant capture + analysis — useful with the
   stream paused (saves battery).

---

## Enabling Moondream2 (optional, advanced)

`LocalVisionService` ships with ML Kit for instant labels. To upgrade the local
path to a full VLM:

1. Put `moondream2-Q4_K_M.gguf` + the mmproj file on the device.
2. Implement a platform channel (`com.spectraglass/llama`) wrapping
   llama.cpp with vision (`llava_init` + mmproj), then call it inside
   `describeWithMoondream()` — the placeholder marks the exact spot.
3. Toggle it from code: `LocalVisionService.instance.enableMoondream(path)`.

Everything else in the app (prompting, upstream, TTS) already treats the local
result as a plain sentence, so no further changes are needed.

## Cost notes (from the project budget)

* ESP32-CAM module: ~24,000 IQD
* Processing (phone, existing): ~6,000 IQD budget line
* Everything else: open-source (Flutter, ML Kit, llama.cpp, OpenRouter free tier)

## Roadmap (mirrors the project notes)

- [ ] UV / IR sensor fusion alongside the camera
- [ ] Cloud session sync ("analysis history" account)
- [ ] Voice commands ("what is this?", "read that sign")
- [ ] Arabic-language narration (native TTS locale switch)
- [ ] Continuous accuracy benchmarking on lab equipment datasets
