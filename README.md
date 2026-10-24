# SpectruLenPor — Smart glasses for spectrum analysis and detection of chemical elements and compounds

**النظارة الذكية لتحليل الطيف واكتشاف العناصر والمركبات الكيميائية**

Flutter (Android) app + ESP32-CAM firmware + UV/IR sensors for smart scientific
glasses: the glasses capture (camera + UV/IR sensors) and stream over
Bluetooth, the **phone does all orchestration** (per the project design),
**Moondream3 Cloud** is the primary vision analyst, a local Moondream engine
is the offline fallback, an OpenRouter LLM only presents the analysis nicely,
and everything is narrated with **bilingual streamed voice output**
(Arabic / English) with hazard alerts.

> Project by **Malak Adel Sayed Hassan** · Grade 1 secondary, Class 3/1 ·
> Ashmounin Secondary School · Budget: **2,500–6,000 EGP**

---

## Architecture (v3 — Moondream3-cloud-first)

```
النظارة (المستشعرات)  ⇒  ESP32-CAM  ⇒  الهاتف  ⇒  المساعد الصوتي
(glasses/sensors)        (data)        (phone)      (AI voice)

[ESP32-CAM + OV2640 + UV sensor (GPIO12) + IR sensor (GPIO13)]
        │  BLE: JPEG frames (~1 fps) + telemetry "$UV:1234;IR:567" @5Hz
        ▼
[ANDROID PHONE — this app]
        ├─ 0. Phone-camera source — demo mode, works with NO hardware
        ├─ 1. BluetoothCameraService    frames + sensor packets + commands
        ├─ 2. MoondreamService          ★ PRIMARY VISION — Moondream3 Cloud
        │        POST api.moondream.ai/v1/caption  (streamed, SSE chunks)
        │        POST api.moondream.ai/v1/query    (deep chemistry analysis)
        │        model moondream3.1-9B-A2B · base64 data-URL images
        ├─ 3. Vision fallback cascade   local Moondream GGUF (JNI/llama.cpp)
        │        → ONNX Runtime Mobile → ML Kit labeling + OCR
        ├─ 4. OpenRouterService         presenter-only LLM chain (streamed,
        │        gemma-4-26b → inkling-small → nemotron-3-nano reasoning)
        ├─ 5. OpenRouterTtsService      ★ STREAMED fish-audio TTS
        │        fish-audio/s2.1-pro-free:free · bytes piped into just_audio
        │        as they download (first sound ≈ immediately)
        └─ 6. Hazard engine             keywords (AR/EN) + UV/IR thresholds
```

**Division of labor (latency design):**

| Stage | Engine | Latency |
|---|---|---|
| Analyze (vision) | **Moondream3 Cloud** (`moondream3.1-9B-A2B`) | first caption chunk ≈0.5–1 s (SSE) |
| Describe instantly | Android native TTS (offline) | ~0 ms after caption |
| Present nicely | OpenRouter chain — presenter only, `max_tokens≈380` | first token ≈1 s, spoken per sentence |
| Narrate deeply | **fish-audio/s2.1-pro-free:free** via OpenRouter `/audio/speech` | streamed — playback starts on first chunks |
| Offline fallback | local Moondream GGUF → ONNX → ML Kit | 0.3–3 s, no network |

The LLM **never** invents the analysis — it rephrases Moondream3's factual
description (+ ONNX top-k, UV/IR telemetry) into clear spoken language, and
adds a `Warning:` line that triggers the red hazard banner.

### Why this stays fast
* Moondream cloud **caption** (`length: short`) is the hot path; the deep
  `query` runs fire-and-forget and never blocks speech.
* One frame at a time (1–4 fps throttle), 224-px-class JPEGs over BLE.
* Per-sentence native TTS while the LLM streams; fish-audio narration is
  **byte-streamed** into `just_audio` (`StreamAudioResponse`, no full-file wait).
* Free-tier friendly: Moondream allows 2 req/s; OpenRouter chain auto-falls
  through gemma → inkling → nemotron on 429/5xx/timeout.

---

## What makes the app real & working today

* **Phone camera mode (default)** — install, open, point at anything: the
  pipeline runs end-to-end on the phone camera (Moondream cloud → TTS →
  OpenRouter). No ESP32 hardware needed to demo.
* **Glasses mode** — one tap switches the source to the BLE glasses feed.
* **Bilingual with real l10n** — proper Flutter `gen-l10n` (ARB files at
  `lib/l10n/app_en.arb` + `app_ar.arb` → generated `AppLocalizations`),
  one-tap EN ⇄ العربية toggle, RTL layout mirroring, `ar-EG` narration.
* **Spectrum panel** — live UV/IR gauges from the glasses, state-of-matter
  chip (solid/liquid/gas parsed from the AI analysis), ONNX top-3 bars.
* **Hazard alerts** — red pulsing banner + voice warning when the AI reply
  or sensors signal danger (toxic / flammable / corrosive / UV & IR
  thresholds). Bilingual keywords. Native TTS speaks alerts even offline.
* **Flashlight** — app-bar torch button: drives the glasses' onboard flash
  LED over BLE (0x03/0x04) or the phone torch in phone mode — for dim labs.
* **Latency transparency** — the app shows its own time-to-first-audio-token
  and the last Moondream TTFT reported by the API.

---

## Repository layout

```
smart_glass_app/
├── pubspec.yaml                      # onnxruntime, just_audio, l10n generate:true …
├── l10n.yaml                         # Flutter l10n (ARB → AppLocalizations)
├── lib/
│   ├── main.dart                     # providers + locale (ValueNotifier) + routes
│   ├── l10n/
│   │   ├── app_en.arb                # ★ translation source (template)
│   │   ├── app_ar.arb                # ★ Arabic translations
│   │   └── app_localizations.dart    # generated (regenerates on pub get)
│   ├── models/
│   │   ├── frame_data.dart           # one frame (JPEG) from either source
│   │   ├── spectrum_reading.dart     # UV/IR telemetry, state-of-matter, hazard keywords
│   │   └── recognition_state.dart    # central state machine (Provider)
│   ├── services/
│   │   ├── moondream_service.dart         # ★ Moondream3 Cloud API (primary vision)
│   │   │                                  #   /caption /query /detect + SSE streaming
│   │   │                                  #   + local GGUF fallback via platform channel
│   │   ├── local_vision_service.dart      # cloud → local GGUF → ONNX → ML Kit cascade
│   │   ├── bluetooth_camera_service.dart  # BLE client + telemetry parse + commands
│   │   ├── phone_camera_service.dart      # phone camera source (YUV→JPEG isolate)
│   │   ├── onnx_vision_service.dart       # ONNX Runtime Mobile specialized model
│   │   ├── openrouter_service.dart        # ★ presenter chain: gemma→inkling→nemotron
│   │   │                                  #   streamed + reasoning-token capture
│   │   ├── openrouter_tts_service.dart    # ★ streamed fish-audio TTS (just_audio)
│   │   └── native_tts_service.dart        # Android TTS (ar-EG / en-US)
│   ├── screens/ (home, settings)
│   ├── widgets/ (camera preview, spectrum card, hazard banner, …)
│   └── utils/   (app_theme — user palette)
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
flutter pub get        # regenerates AppLocalizations from lib/l10n/*.arb
flutter run            # phone camera mode works immediately
flutter build apk --release
```

Android 7+ (API 24). First launch requests camera + nearby-devices permissions.

### Add the API keys (2 minutes)

The three demo keys live in **`assets/config/secrets.json`** — a gitignored
build asset (GitHub push-protection blocks committed API keys). This machine
already has it; on a fresh clone:

```bash
cp assets/config/secrets.example.json assets/config/secrets.json
# then paste your keys into the JSON
```

Resolution order per key: **Settings (SharedPreferences) → secrets.json →
`--dart-define` → '' (offline mode)**. Two separate OpenRouter keys are used
so LLM chat rate limits never stall the voice:

1. **Moondream** (primary vision): [docs.moondream.ai → cloud](https://docs.moondream.ai/)
2. **OpenRouter LLM key** (gemma → inkling → nemotron chain): [openrouter.ai/keys](https://openrouter.ai/keys)
3. **OpenRouter TTS key** (streamed fish-audio narration): same site

Or inject at build time instead of the JSON:

```bash
flutter build apk --release \
  --dart-define=MOONDREAM_API_KEY=... \
  --dart-define=OPENROUTER_LLM_KEY=... \
  --dart-define=OPENROUTER_TTS_KEY=...
```

Without keys the app still works fully offline through the local cascade
(local Moondream GGUF → ONNX → ML Kit) with native Android TTS.

### Optional: specialized ONNX model (offline classifier)

```bash
pip install torch torchvision onnx onnxruntime
python tooling/convert_mobilenet_onnx.py --output_dir assets/models
flutter build apk
```

Fine-tune MobileNetV2 on your own lab-equipment / chemical-bottle dataset
(folders per class, ~200 photos each) and re-run the same script — the Dart
side needs zero changes.

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

## 3. Local Moondream fallback build (offline VLM)

The cloud tier is primary; when there is no network the app transparently
falls back to an on-device Moondream GGUF through the platform channel:

```bash
cd android/app/src/main/cpp
git clone --depth 1 --recursive https://github.com/ggerganov/llama.cpp
```

1. Wire `CMakeLists.txt` via `android/app/build.gradle.reference` (merge into
   your generated app/build.gradle, namespace `com.spectraglass.app`).
2. Push `moondream2-Q4_K_M.gguf` + `mmproj-model-f16.gguf` to the device.
3. Settings → *Local AI* shows the deployed path; or call
   `LocalVisionService.instance.enableMoondream('/path/to/model.gguf')`.
4. Build (arm64-v8a). First inference loads the model (~10 s), then ~1.5–3 s
   per caption.

Until deployed, the cascade is: **Moondream3 cloud → ONNX → ML Kit**, so
nothing blocks without it.

## 4. Typography (bundled Google Fonts)

All four families ship in `assets/fonts/` (declared under `google_fonts:` in
pubspec — zero runtime fetching, fully offline, deterministic UI):

| Font | Role |
|---|---|
| **Jaro** | the stylish font — brand, app bar, display/headline tiers (EN) |
| **Rubik** | all other normal text (EN) |
| **Space Mono** | long text paragraphs — AI analysis body, About (EN) |
| **Zain** | ALL Arabic text (display, body and paragraphs — full Arabic glyph coverage) |

Mapping lives in `lib/utils/app_typography.dart` and is applied both at the
theme level (`buildAppTheme(locale)`) and per-widget for paragraph text.

## 5. Translations (Flutter l10n)

Strings live in ARB files — edit and rebuild, no code changes:

```
lib/l10n/app_en.arb   ← template (source of truth)
lib/l10n/app_ar.arb   ← العربية (RTL)
```

`flutter pub get` regenerates `AppLocalizations` (configured in
`l10n.yaml`, `generate: true` in pubspec). For non-context code (TTS
prompts), `await AppLocalizations.load(const Locale('ar'))` returns the
Arabic table directly.

## 6. Full test suite (what was verified)

Everything below was executed against the real SDK and real cloud APIs:

**Static + unit + widget — `flutter analyze` clean, `flutter test` 68/68 passing**

| Suite | Covers |
|---|---|
| `test/models/` | SpectrumReading parse/percent/thresholds/matter-state/hazard keywords · FrameData |
| `test/l10n/` | every key non-empty in EN **and** AR, AR≠EN, parameterized `latencyFirstToken`, delegate locales |
| `test/utils/` | font mapping: Jaro/Rubik/SpaceMono (EN) + Zain (AR), theme merge, context helpers |
| `test/services/` | Moondream SSE parsing + 429/401/400-model-downgrade · OpenRouter chain fallback (500→next model), reasoning-token capture (both key casings), startModel pinning · TTS request shape + markdown strip + error swallow · vision cascade ordering (cloud first, gates, templates) |
| `test/models/recognition_state_test.dart` | settings persistence, clamps, demo-key hot-config, frame throttle, sensor hazard banner, flashlight, source switching |
| `test/widgets/` | full app shell: home renders brand/cards, AR flip renders **RTL**, settings shows keys/chain/diagnostics, lazy-list scrolling |

**Real API results (2026-10-25, `tool/real_api_smoke_test.dart` + curl)**

| Check | Result |
|---|---|
| Moondream `/caption` | ✅ 30 ms TTFT — "A red circle is centered on a white background…" |
| Moondream `/query` + reasoning | ✅ structured answer + reasoning trace (object→text normalized) |
| Moondream `/detect` | ✅ 1 box @ (0.34, 0.28)–(0.66, 0.72) |
| Moondream SSE streaming | ✅ `data:{"chunk":…}` frames decoded |
| OpenRouter `gemma-4-26b-a4b-it:free` | ⚠️ 429 upstream-limited → chain falls through |
| OpenRouter `inkling-small:free` | ⚠️ 403 agentic-only → chain falls through |
| OpenRouter `nemotron-3-nano-omni-30b-a3b-reasoning:free` | ✅ streamed reply, **576 reasoning tokens** captured |
| fish-audio `/audio/speech` | ✅ 74–107 KB MP3s (EN + AR), markdown stripped |
| **Audio proof** | ✅ MP3s transcribed back via ASR — EN: *"Warning: This is SpectruLenPor speaking through the streamed fish-audio pipeline"* · AR: *"مرحبًا أنا سبكترو لِن بور مساعدتك للتحليل الطيفي…"* |

**Real browser screenshots (Flutter web build, headless Chromium)**

Captured during the build→serve→screenshot→read→fix loop
(`scripts/preview_server.py` + agent-browser): home EN (Jaro brand title,
Space Mono analysis body), settings EN (pre-filled keys, chain radios,
diagnostics), settings AR + home AR in **full RTL with Zain**, live
EN↔AR toggle, locale persistence across reloads, zero console errors.

## 7. Browser preview (no device needed)

```bash
flutter build web --release
python3 ../scripts/preview_server.py     # serves build/web + CORS-proxies
                                          # /moondream/v1/* and /openrouter/v1/*
# open http://localhost:8090
```

On web the services automatically switch to the relative proxy paths
(`kIsWeb` in `MoondreamService` / `OpenRouterService` / TTS), so the
browser demo calls the same cloud pipeline as the phone build.

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
| **Software & AI** (Flutter, Moondream free tier, OpenRouter free models + fish-audio TTS, ONNX Runtime, llama.cpp) | **0** |
| **Total** | **≈ 1,750 EGP** (fits the 2,500–6,000 EGP budget with spare for iteration) |

## Roadmap (mirrors the paper)

- [x] Phone-camera demo mode · bilingual voice · hazard alerts · flashlight
- [x] Moondream3 Cloud primary vision + local Moondream fallback
- [x] OpenRouter gemma → inkling → nemotron reasoning chain
- [x] Streamed fish-audio TTS (OpenRouter /audio/speech + just_audio)
- [x] Proper Flutter l10n (ARB → AppLocalizations, EN/AR RTL)
- [x] ONNX Runtime Mobile specialized-model pipeline
- [x] UV/IR telemetry + state-of-matter + hazard thresholds
- [ ] UV/IR spectral dispersion unit (mini) for element fingerprints
- [ ] Cloud session sync + analysis history
- [ ] Voice commands ("ما هذه؟" / "read that label")
- [ ] Titanium frame prototype
