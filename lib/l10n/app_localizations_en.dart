// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'SpectruLenPor';

  @override
  String get appTagline =>
      'Smart glasses for spectrum analysis and detection of chemical elements and compounds';

  @override
  String get glassesNotConnected => 'Glasses not connected';

  @override
  String get scanning => 'Scanning for glasses…';

  @override
  String get connecting => 'Connecting…';

  @override
  String get connected => 'Connected';

  @override
  String get btError => 'Bluetooth error';

  @override
  String get connectGlasses => 'Connect glasses';

  @override
  String get disconnect => 'Disconnect';

  @override
  String get waitingFrame =>
      'Waiting for a frame… (use phone camera to test without glasses)';

  @override
  String get phoneCamera => 'Phone camera';

  @override
  String get glassesCam => 'Glasses';

  @override
  String get localVision => 'Local vision — instant';

  @override
  String get idleLabel => 'Idle — waiting for next frame.';

  @override
  String get deepReasoning => 'AI analysis';

  @override
  String get deepHint =>
      'Point at a substance, then tap \"Analyze now\" for full spectrum-based analysis.';

  @override
  String get describeNow => 'Analyze now';

  @override
  String get analyzing => 'Analyzing…';

  @override
  String get soundOn => 'Sound on';

  @override
  String get muted => 'Muted';

  @override
  String get settings => 'Settings';

  @override
  String get spectrum => 'Spectrum channels';

  @override
  String get uvChannel => 'UV';

  @override
  String get irChannel => 'IR';

  @override
  String get noSensorData =>
      'No sensor telemetry yet — UV/IR readings appear when the glasses stream them.';

  @override
  String get stateMatter => 'State of matter';

  @override
  String get stateUnknown => 'Unknown';

  @override
  String get stateSolid => 'Solid';

  @override
  String get stateLiquid => 'Liquid';

  @override
  String get stateGas => 'Gas';

  @override
  String get hazardClear => 'No hazard detected';

  @override
  String get hazardDetected => 'Hazard detected!';

  @override
  String get hazardSpeech =>
      'Warning! Hazardous material detected. Step back carefully.';

  @override
  String get flashlight => 'Flashlight';

  @override
  String get waitingSensors => 'Waiting for sensor data…';

  @override
  String get credits =>
      'SpectruLenPor · Malak Adel Sayed Hassan · Grade 1 secondary, Class 3/1 · Ashmounin Secondary School';

  @override
  String get visionSourceMoondream => 'Moondream3 cloud';

  @override
  String get visionSourceLocalMoondream => 'Local Moondream';

  @override
  String get visionSourceOnnx => 'ONNX model';

  @override
  String get visionSourceMlkit => 'ML Kit';

  @override
  String get visionSourceIdle => 'Idle';

  @override
  String get visionSourceError => 'Vision error';

  @override
  String get moondreamApiKeyLabel => 'Moondream API key';

  @override
  String get moondreamApiKeyHint => 'Get one at docs.moondream.ai → cloud';

  @override
  String get moondreamCloudEnabled =>
      'Cloud vision enabled (moondream3.1-9B-A2B)';

  @override
  String get moondreamCloudDisabled =>
      'No Moondream key — using local Moondream / ML Kit fallback';

  @override
  String get openRouterApiKeyLabel => 'OpenRouter API key';

  @override
  String get openRouterApiKeyHint => 'Free key: openrouter.ai/keys';

  @override
  String get openRouterLlmKeyLabel => 'OpenRouter LLM key';

  @override
  String get openRouterLlmKeyHint =>
      'Powers the gemma → inkling → nemotron chain';

  @override
  String get openRouterTtsKeyLabel => 'OpenRouter TTS key';

  @override
  String get openRouterTtsKeyHint => 'Powers the streamed fish-audio narration';

  @override
  String get diagnosticsHeader => 'Diagnostics';

  @override
  String get diagnosticsCloud => 'Moondream cloud';

  @override
  String get diagnosticsLastModel => 'Last model';

  @override
  String get diagnosticsReasoningTokens => 'Reasoning tokens';

  @override
  String get diagnosticsTts => 'TTS engine';

  @override
  String get fishAudioTts => 'Streamed fish-audio TTS';

  @override
  String get fishAudioTtsSubtitle =>
      'High-quality streamed narration (OpenRouter /audio/speech)';

  @override
  String get ttsNative => 'Native Android TTS (offline)';

  @override
  String get ttsNativeSubtitle => 'Lowest latency, no network';

  @override
  String get testVoice => 'Test voice';

  @override
  String get visionPriorityHeader => 'Vision source priority';

  @override
  String get upstreamFallbackHeader =>
      'OpenRouter text+reasoning fallback chain';

  @override
  String get modelGemma26 => 'google/gemma-4-26b-a4b-it:free — primary';

  @override
  String get modelInkling => 'thinkingmachines/inkling-small:free — fallback 1';

  @override
  String get modelNemotron =>
      'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free — fallback 2';

  @override
  String get reasoningTokensLabel => 'Capture reasoning tokens';

  @override
  String get reasoningTokensHint =>
      'Reports reasoning tokens via chunk.usage.completionTokensDetails.reasoningTokens';

  @override
  String latencyFirstToken(int ms) {
    return '⏱ first audio token: $ms ms';
  }

  @override
  String get aboutBody =>
      'SpectruLenPor v5.3.0 — YOLO26-Nano on-device object detection + Moondream3 cloud vision + OpenRouter gemma→inkling→nemotron reasoning chain + streamed fish-audio TTS + Wikipedia + PubChem + DuckDuckGo citations + Google AI Overviews-style inline [n] citations + fact-checking + auto-updating structured context + chat with mic.\n\nPipeline: phone camera / ESP32-CAM → YOLO26-Nano bounding boxes → user taps box → dual capture (clean + boxes) → Moondream analyzeSelected → LLM scientific context with citations + fact-checking → auto-narrate → chat session with auto-updating context.\n\nMalak Adel Sayed Hassan · Grade 1 secondary, Class 3/1 · Ashmounin Secondary School · Budget: 2,500–6,000 EGP.';
}
