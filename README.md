# SpectruLenPor (v5.5.0) — Smart Scientific Glasses for Spectrum Analysis & Chemical Element/Compound Identification

**النظارة الذكية لتحليل الطيف واكتشاف العناصر والمركبات الكيميائية**

SpectruLenPor is a bilingual (**English / العربية RTL**) Flutter Android application + ESP32-CAM BLE smart-glasses platform for real-time object detection, UV/IR spectrum telemetry, grounded chemical & scientific identification, Google-Search-style inline `[n]` citations, automated claim fact-checking, auto-updating structured scientific memory, and persistent session & diagnostics storage.

> **Project Credits**
> - **Student Researcher:** Malak Adel Sayed Hassan · Grade 1 Secondary, Class 3/1 · Ashmounin Secondary School
> - **Software & Systems Developer:** Abdoul-Rahman Ayman Mohamed
> - **Hardware Target Budget:** 2,500–6,000 EGP (actual BOM ≈ 1,750 EGP)
> - **Current Release:** `v5.5.0+15` (`com.spectraglass.app`)

---

## Key Capabilities in v5.5

1. **Local On-Device YOLO26-Nano Vision (`assets/models/yolo26n.onnx`)**
   - Runs **100% locally** on Android via `onnxruntime-android:1.22.0` (`YoloInferenceChannel.kt` on `com.spectraglass/yolo`).
   - Bundled in the APK (`5.04 MB`, Ultralytics `8.4.0`, ONNX IR v10 / Opset 22, `end2end=True`, FP32 `[1, 3, 640, 640] -> [1, 300, 6]`), automatically extracted/verified to `filesDir/models/yolo26n.onnx` on first startup, with built-in HTTPS auto-download recovery (`ensureModel`).
2. **Cloud-Only Models Policy Toggle (Except Local YOLO26-Nano)**
   - Configurable in **Settings → Cloud-Only Policy & Local YOLO26-Nano** (and via the AppBar indicator).
   - When enabled, **YOLO26-Nano remains local on-device** for live interactive bounding boxes while VLM (**Moondream3 Cloud**), LLM (**OpenRouter** chain), and **Cloud TTS** execute strictly in the cloud—skipping non-YOLO local fallbacks (local GGUF, ONNX classifier, ML Kit).
3. **Full-Viewport Camera Preview, Target Lock-On Reticle & Strict Dual Capture**
   - Full-bleed edge-to-edge camera preview (`SizedBox.expand` + `FittedBox(fit: BoxFit.cover)`) at `ResolutionPreset.high` with matching `BoxFit.cover` coordinate projection in `BoundingBoxOverlay`—never shrunk or letterboxed.
   - Tapping any YOLO bounding box locks a custom animated target marker (glowing dusty-mauve double frame, corner L-brackets, center crosshair reticle, and `SELECTED · <label> <pct>%` pill).
   - **Strict user-gated dual capture**: `cleanJpeg` (unobstructed frame) and `withBoxesJpeg` (frame painted with corner brackets, target reticle, and `SELECTED` banner) are captured **only** when a bounding box is selected and the user presses **Capture 2 Frames & Analyze**.
4. **Scientific Knowledge Base, 3 Search Modes, Citations & Fact-Checking**
   - **Bundled offline corpus (`assets/docs/`)**:
     - **119 Periodic Table elements** (`periodic_table.json`) with full atomic, electronic, and physical properties (including automatic K → °C conversions).
     - **110 chemical compounds & lab/everyday materials** (`common_compounds.json`) with formulas, CAS numbers, molar masses, properties, uses, and hazards.
     - **GHS01–GHS09 hazard classes & laboratory PPE protocols** (`lab_safety.json`).
   - **Live cloud scientific sources** (cached with TTL in the internal DB): **PubChem** (`pubchem.ncbi.nlm.nih.gov`), **Wikipedia REST API** (`en.wikipedia.org` / `ar.wikipedia.org`), and **DuckDuckGo Instant Answer Web Search**.
   - **3 selectable RAG search modes (`DocsSearchMode`)**:
     - **`strict`** — exact symbol, chemical formula, CAS number, and canonical title matching.
     - **`detailed`** — full multi-property scientific cards + cloud chemistry/encyclopedia references.
     - **`semantic`** — expands YOLO object classes (e.g., `bottle` → PET / borosilicate glass / water; `fork` → 304 stainless steel / Fe / Cr / Ni) + trigram fuzzy matching + cloud search.
   - **Inline `[n]` citations & automated fact-checking**: Every initial report **and** every follow-up chat turn attaches clickable `[n]` citation pills, a Google-AI-Overviews-style **Sources & Fact Check** card, and sentence-level `FactCheckerService` verification (`Verified` / `Unverified`) using **Material Icons exclusively (zero emojis)**.
5. **Auto-Updating Structured Anchored `ConversationContext`**
   - Every LLM system prompt embeds both the visual `AnchorContext` and the structured `ConversationContext` (`objectIdentified`, `userGoal`, `chemicalFormula`, `stateOfMatter`, `physicalProperties`, `chemicalProperties`, `composition`, `formation`, `commonUses`, `hazards`, `sceneContext`, `labFindings`, `safetyProtocols`, `relatedCompounds`, `establishedFacts`, `openQuestions`, `referencedEntities`, `userNotes`, `turnCount`).
   - At the end of each turn, the AI emits `<context_update>{...}</context_update>`, which `ChatSession` strips from visible Markdown, merges non-destructively into running memory, and persists to the database.
6. **9-Table Internal SQLite WAL Database & Diagnostics Suite**
   - Native Android SQLite WAL database (`AppDatabaseChannel.kt` on `com.spectraglass/db`, `spectrulenpor_internal.db`) with automatic persistent file/memory fallback (`InternalDatabaseService`):
     - `chat_sessions` & `chat_messages` (full chat history + dual JPEG paths + resume/delete in `HistoryScreen`)
     - `response_cache` (TTL + hit-count caching for PubChem, Wikipedia, and WebSearch)
     - `app_logs` (`INFO` / `WARN` / `ERROR` + stack traces)
     - `crash_hang_reports` (`FlutterError.onError`, `PlatformDispatcher.instance.onError`, 40-entry breadcrumb ring, and `HangWatchdog` UI-stall detector)
     - `telemetry_events` (BLE UV/IR/ambient spectrum readings)
     - `pipeline_traces` (millisecond execution spans across YOLO, Moondream, DocsSearch, OpenRouter, and FactChecker)
     - `user_data` (pinned lab notes & settings) & `user_activity` (chronological user actions).

---

## System Architecture (v5.5)

```
[ESP32-CAM + OV2640 + UV (GPIO12) + IR (GPIO13) + Flash LED (GPIO4)]
        │  BLE GATT (ffe0 / ffe1 notify / ffe2 write): QVGA JPEGs + "$UV:..;IR:.." @ 5 Hz
        ▼
[ANDROID APP — SpectruLenPor v5.5]
  ├─ Camera Sources: Phone Camera (HD native texture, BoxFit.cover) OR BLE Smart Glasses
  ├─ VisionGate: Brightness & texture check + auto-torch assist in dark labs
  ├─ Local YOLO26-Nano (com.spectraglass/yolo · onnxruntime-android 1.22.0)
  │    └─ Interactive BoundingBoxOverlay + animated target reticle + SELECTED badge
  ├─ User Action: Select target box ──► Press "Capture 2 Frames & Analyze"
  │    ├─ Frame 1: cleanJpeg (unobstructed color/texture view)
  │    └─ Frame 2: withBoxesJpeg (painted target brackets, crosshair reticle & SELECTED banner)
  ├─ Moondream3 Cloud VLM (api.moondream.ai · analyzeSelected on paired frames)
  ├─ DocsSearchService (Strict | Detailed | Semantic)
  │    ├─ Local: 119 Elements + 110 Compounds + GHS01–GHS09 Safety
  │    └─ Cloud (TTL-cached): PubChem PUG REST + Wikipedia (EN/AR) + WebSearch
  ├─ OpenRouter Reasoning Chain (gemma-4-26b → inkling-small → nemotron-3-nano)
  │    ├─ System Prompt = Visual AnchorContext + Auto-Updating ConversationContext + [n] Sources
  │    └─ Emits Markdown with inline [n] + trailing <context_update>{...}</context_update>
  ├─ FactCheckerService: Claim-by-claim lexical & numeric verification against [n] sources
  ├─ Audio Narration: Streamed fish-audio/s2.1-pro-free:free TTS or offline Android TTS
  └─ InternalDatabaseService (com.spectraglass/db · SQLite WAL, 9 tables + HangWatchdog)
```

For deep implementation details, tensor layouts, and database schemas, see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## Repository Structure

```
SpectrulenPor/
├── README.md                         # Project overview, setup & usage guide
├── pubspec.yaml                      # v5.5.0+15 dependencies, bundled fonts, docs & yolo26n.onnx
├── l10n.yaml                         # Flutter gen-l10n configuration (EN + AR RTL)
├── docs/
│   └── ARCHITECTURE.md               # Deep technical spec (ONNX, RAG modes, Context, SQLite DB)
├── assets/
│   ├── models/yolo26n.onnx           # Bundled YOLO26-Nano ONNX model (5.04 MB, 80 classes)
│   ├── docs/
│   │   ├── README.md                 # Scientific corpus documentation
│   │   ├── periodic_table.json       # 119 chemical elements (atomic/electronic/physical)
│   │   ├── common_compounds.json     # 110 compounds & lab/everyday materials
│   │   └── lab_safety.json           # GHS01–GHS09 hazard classes & PPE rules
│   ├── fonts/                        # Bundled Jaro, Rubik, Space Mono & Zain (zero runtime fetch)
│   ├── config/secrets.example.json   # API key template
│   └── version.json                  # Build/version fallback metadata
├── lib/
│   ├── main.dart                     # DB init, crash/hang hooks, service bootstrap & routes
│   ├── config/app_secrets.dart       # Key resolution (Prefs → secrets.json → --dart-define)
│   ├── l10n/                         # app_en.arb, app_ar.arb & AppLocalizations
│   ├── models/                       # RecognitionState, ConversationContext, Citation, SpectrumReading…
│   ├── services/                     # YoloDetector, InternalDatabaseService, DocsSearchService,
│   │                                 # PubChem, Wikipedia, WebSearch, FactChecker, Moondream,
│   │                                 # OpenRouter, ChatSession, BLE/PhoneCamera, TTS, Mic…
│   ├── screens/                      # HomeScreen, ChatScreen, SettingsScreen,
│   │                                 # HistoryScreen, DiagnosticsDbScreen
│   ├── widgets/                      # BoundingBoxOverlay, CameraPreviewWidget, SpectrumCard…
│   └── utils/                        # AppColors / buildAppTheme & AppTypography
├── android/app/src/main/
│   ├── kotlin/com/spectraglass/app/  # MainActivity, YoloInferenceChannel, AppDatabaseChannel,
│   │                                 # FlashlightChannel, MoondreamChannel
│   └── cpp/                          # Optional local llama.cpp JNI bridge (moondream_jni.cpp)
├── firmware/
│   ├── README.md                     # Hardware wiring & BLE GATT protocol docs
│   └── esp32cam_glasses_firmware.ino # ESP32-CAM sketch (JPEG stream + UV/IR + deferred capture)
├── tooling/
│   ├── README.md                     # ONNX inspection & custom quantization guide
│   └── convert_mobilenet_onnx.py     # Optional custom classifier export + INT8 quantization
├── tool/real_api_smoke_test.dart     # Live cloud API smoke test script
└── test/                             # Unit & widget test suites (models, services, l10n, UI)
```

---

## Getting Started

### 1. Prerequisites
- **Flutter SDK** `>= 3.19.0` (Dart `>= 3.3.0 < 4.0.0`)
- **Android Studio / SDK** (`compileSdk 36`, `minSdk 31`, JDK 17)

### 2. Configure API Keys
Copy the template and add your cloud keys (never committed to Git):

```bash
cp assets/config/secrets.example.json assets/config/secrets.json
```

```json
{
  "moondream": "<your Moondream API key — docs.moondream.ai>",
  "openrouter_llm": "<your OpenRouter LLM key — openrouter.ai/keys>",
  "openrouter_tts": "<your OpenRouter TTS key — openrouter.ai/keys>"
}
```

Keys can also be entered live inside **Settings** or passed at build time via `--dart-define`:

```bash
flutter build apk --release \
  --dart-define=MOONDREAM_API_KEY=... \
  --dart-define=OPENROUTER_LLM_KEY=... \
  --dart-define=OPENROUTER_TTS_KEY=...
```

### 3. Run & Test

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

---

## Smart Glasses Hardware & Firmware (`firmware/`)

1. Flash `firmware/esp32cam_glasses_firmware.ino` to an **AI-Thinker ESP32-CAM** board.
2. Connect analog **UV sensor (GUVA-S12SD)** to `GPIO12` and **IR sensor** to `GPIO13` (`GPIO4` drives the onboard flash LED).
3. Power on (`SpectruLenPor-ESP32`) and tap **Smart Glasses → Connect Glasses** in the app.
4. See [`firmware/README.md`](firmware/README.md) for the complete pinout and BLE GATT specification.

---

## Typography & Design System

- **Brand Palette (`AppColors`)**: Alabaster Grey (`#E5E3E1`), Dust Grey (`#D4D3CD`), Silver (`#C2BEC0`), Dusty Mauve (`#A67E98`), Dusty Lavender (`#825376`), Deep Plum Ink (`#3A2434`).
- **Bundled Offline Fonts (`assets/fonts/`)**:
  - **Jaro** — English brand/display headers
  - **Rubik** — English UI controls, badges, and body text
  - **Space Mono** — Scientific properties, code, citations, telemetry, and diagnostics
  - **Zain** — Complete Arabic (`ar`) RTL typography across display, body, and paragraphs
- **Iconography**: 100% vector Material Icons (`Icons.*`) across every screen, badge, citation chip, and status indicator—zero emojis.

---

## Hardware Bill of Materials (EGP)

| Component | Estimated Cost (EGP) |
|---|---|
| AI-Thinker ESP32-CAM + OV2640 camera module | ~600 |
| GUVA-S12SD UV sensor + analog IR sensor | ~350 |
| FTDI / USB-to-TTL programming adapter | ~200 |
| TP4056 Li-ion charging module + rechargeable cell | ~250 |
| Eyeglass frame mount, enclosure & wiring | ~350 |
| Android smartphone (existing user device) | 0 |
| Software & AI stack (Flutter, ONNX Runtime, SQLite, Moondream/OpenRouter free tiers) | 0 |
| **Total Prototype Cost** | **≈ 1,750 EGP** *(within 2,500–6,000 EGP target)* |

---

## Completed Engineering Roadmap

- [x] Full-viewport edge-to-edge phone camera & BLE ESP32-CAM glasses streaming
- [x] Local on-device YOLO26-Nano (`yolo26n.onnx`) with first-startup staging & HTTPS auto-download
- [x] Cloud-only models setting (keeping YOLO26-Nano local on-device)
- [x] Interactive bounding boxes with animated target lock-on marker & strict user-gated dual JPEG capture (`cleanJpeg` + `withBoxesJpeg`)
- [x] Bundled 119 elements + 110 compounds/materials + GHS01–GHS09 safety corpus
- [x] Live PubChem, Wikipedia (EN/AR), and DuckDuckGo Web Search with `strict`, `detailed`, and `semantic` RAG modes
- [x] Google-Search-style `[n]` inline citations & automated claim-level fact-checking
- [x] Auto-updating structured `ConversationContext` (`<context_update>`) injected into every LLM system prompt
- [x] 9-table Android SQLite WAL Internal Database (`HistoryScreen` + `DiagnosticsDbScreen` + `HangWatchdog`)
- [x] Bilingual EN / AR (RTL) UI + streamed `fish-audio` & native offline TTS
