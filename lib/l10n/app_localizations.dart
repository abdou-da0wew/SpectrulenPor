import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';
import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ar')
  ];

  /// App brand name
  ///
  /// In en, this message translates to:
  /// **'SpectruLenPor'**
  String get appName;

  /// Official project title (EN)
  ///
  /// In en, this message translates to:
  /// **'Smart glasses for spectrum analysis and detection of chemical elements and compounds'**
  String get appTagline;

  /// No description provided for @glassesNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Glasses not connected'**
  String get glassesNotConnected;

  /// No description provided for @scanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning for glasses…'**
  String get scanning;

  /// No description provided for @connecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get connecting;

  /// No description provided for @connected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get connected;

  /// No description provided for @btError.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth error'**
  String get btError;

  /// No description provided for @connectGlasses.
  ///
  /// In en, this message translates to:
  /// **'Connect glasses'**
  String get connectGlasses;

  /// No description provided for @disconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get disconnect;

  /// No description provided for @waitingFrame.
  ///
  /// In en, this message translates to:
  /// **'Waiting for a frame… (use phone camera to test without glasses)'**
  String get waitingFrame;

  /// No description provided for @phoneCamera.
  ///
  /// In en, this message translates to:
  /// **'Phone camera'**
  String get phoneCamera;

  /// No description provided for @glassesCam.
  ///
  /// In en, this message translates to:
  /// **'Glasses'**
  String get glassesCam;

  /// No description provided for @localVision.
  ///
  /// In en, this message translates to:
  /// **'Local vision — instant'**
  String get localVision;

  /// No description provided for @idleLabel.
  ///
  /// In en, this message translates to:
  /// **'Idle — waiting for next frame.'**
  String get idleLabel;

  /// No description provided for @deepReasoning.
  ///
  /// In en, this message translates to:
  /// **'AI analysis'**
  String get deepReasoning;

  /// No description provided for @deepHint.
  ///
  /// In en, this message translates to:
  /// **'Point at a substance, then tap \"Analyze now\" for full spectrum-based analysis.'**
  String get deepHint;

  /// No description provided for @describeNow.
  ///
  /// In en, this message translates to:
  /// **'Analyze now'**
  String get describeNow;

  /// No description provided for @analyzing.
  ///
  /// In en, this message translates to:
  /// **'Analyzing…'**
  String get analyzing;

  /// No description provided for @soundOn.
  ///
  /// In en, this message translates to:
  /// **'Sound on'**
  String get soundOn;

  /// No description provided for @muted.
  ///
  /// In en, this message translates to:
  /// **'Muted'**
  String get muted;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @spectrum.
  ///
  /// In en, this message translates to:
  /// **'Spectrum channels'**
  String get spectrum;

  /// No description provided for @uvChannel.
  ///
  /// In en, this message translates to:
  /// **'UV'**
  String get uvChannel;

  /// No description provided for @irChannel.
  ///
  /// In en, this message translates to:
  /// **'IR'**
  String get irChannel;

  /// No description provided for @noSensorData.
  ///
  /// In en, this message translates to:
  /// **'No sensor telemetry yet — UV/IR readings appear when the glasses stream them.'**
  String get noSensorData;

  /// No description provided for @stateMatter.
  ///
  /// In en, this message translates to:
  /// **'State of matter'**
  String get stateMatter;

  /// No description provided for @stateUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get stateUnknown;

  /// No description provided for @stateSolid.
  ///
  /// In en, this message translates to:
  /// **'Solid'**
  String get stateSolid;

  /// No description provided for @stateLiquid.
  ///
  /// In en, this message translates to:
  /// **'Liquid'**
  String get stateLiquid;

  /// No description provided for @stateGas.
  ///
  /// In en, this message translates to:
  /// **'Gas'**
  String get stateGas;

  /// No description provided for @hazardClear.
  ///
  /// In en, this message translates to:
  /// **'No hazard detected'**
  String get hazardClear;

  /// No description provided for @hazardDetected.
  ///
  /// In en, this message translates to:
  /// **'Hazard detected!'**
  String get hazardDetected;

  /// No description provided for @hazardSpeech.
  ///
  /// In en, this message translates to:
  /// **'Warning! Hazardous material detected. Step back carefully.'**
  String get hazardSpeech;

  /// No description provided for @flashlight.
  ///
  /// In en, this message translates to:
  /// **'Flashlight'**
  String get flashlight;

  /// No description provided for @waitingSensors.
  ///
  /// In en, this message translates to:
  /// **'Waiting for sensor data…'**
  String get waitingSensors;

  /// No description provided for @credits.
  ///
  /// In en, this message translates to:
  /// **'SpectruLenPor · Malak Adel Sayed Hassan · Grade 1 secondary, Class 3/1 · Ashmounin Secondary School'**
  String get credits;

  /// No description provided for @visionSourceMoondream.
  ///
  /// In en, this message translates to:
  /// **'Moondream3 cloud'**
  String get visionSourceMoondream;

  /// No description provided for @visionSourceLocalMoondream.
  ///
  /// In en, this message translates to:
  /// **'Local Moondream'**
  String get visionSourceLocalMoondream;

  /// No description provided for @visionSourceOnnx.
  ///
  /// In en, this message translates to:
  /// **'ONNX model'**
  String get visionSourceOnnx;

  /// No description provided for @visionSourceMlkit.
  ///
  /// In en, this message translates to:
  /// **'ML Kit'**
  String get visionSourceMlkit;

  /// No description provided for @visionSourceIdle.
  ///
  /// In en, this message translates to:
  /// **'Idle'**
  String get visionSourceIdle;

  /// No description provided for @visionSourceError.
  ///
  /// In en, this message translates to:
  /// **'Vision error'**
  String get visionSourceError;

  /// No description provided for @moondreamApiKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'Moondream API key'**
  String get moondreamApiKeyLabel;

  /// No description provided for @moondreamApiKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Get one at docs.moondream.ai → cloud'**
  String get moondreamApiKeyHint;

  /// No description provided for @moondreamCloudEnabled.
  ///
  /// In en, this message translates to:
  /// **'Cloud vision enabled (moondream3.1-9B-A2B)'**
  String get moondreamCloudEnabled;

  /// No description provided for @moondreamCloudDisabled.
  ///
  /// In en, this message translates to:
  /// **'No Moondream key — using local Moondream / ML Kit fallback'**
  String get moondreamCloudDisabled;

  /// No description provided for @openRouterApiKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'OpenRouter API key'**
  String get openRouterApiKeyLabel;

  /// No description provided for @openRouterApiKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Free key: openrouter.ai/keys'**
  String get openRouterApiKeyHint;

  /// No description provided for @openRouterLlmKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'OpenRouter LLM key'**
  String get openRouterLlmKeyLabel;

  /// No description provided for @openRouterLlmKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Powers the gemma → inkling → nemotron chain'**
  String get openRouterLlmKeyHint;

  /// No description provided for @openRouterTtsKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'OpenRouter TTS key'**
  String get openRouterTtsKeyLabel;

  /// No description provided for @openRouterTtsKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Powers the streamed fish-audio narration'**
  String get openRouterTtsKeyHint;

  /// No description provided for @diagnosticsHeader.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics'**
  String get diagnosticsHeader;

  /// No description provided for @diagnosticsCloud.
  ///
  /// In en, this message translates to:
  /// **'Moondream cloud'**
  String get diagnosticsCloud;

  /// No description provided for @diagnosticsLastModel.
  ///
  /// In en, this message translates to:
  /// **'Last model'**
  String get diagnosticsLastModel;

  /// No description provided for @diagnosticsReasoningTokens.
  ///
  /// In en, this message translates to:
  /// **'Reasoning tokens'**
  String get diagnosticsReasoningTokens;

  /// No description provided for @diagnosticsTts.
  ///
  /// In en, this message translates to:
  /// **'TTS engine'**
  String get diagnosticsTts;

  /// No description provided for @fishAudioTts.
  ///
  /// In en, this message translates to:
  /// **'Streamed fish-audio TTS'**
  String get fishAudioTts;

  /// No description provided for @fishAudioTtsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'High-quality streamed narration (OpenRouter /audio/speech)'**
  String get fishAudioTtsSubtitle;

  /// No description provided for @ttsNative.
  ///
  /// In en, this message translates to:
  /// **'Native Android TTS (offline)'**
  String get ttsNative;

  /// No description provided for @ttsNativeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Lowest latency, no network'**
  String get ttsNativeSubtitle;

  /// No description provided for @testVoice.
  ///
  /// In en, this message translates to:
  /// **'Test voice'**
  String get testVoice;

  /// No description provided for @visionPriorityHeader.
  ///
  /// In en, this message translates to:
  /// **'Vision source priority'**
  String get visionPriorityHeader;

  /// No description provided for @upstreamFallbackHeader.
  ///
  /// In en, this message translates to:
  /// **'OpenRouter text+reasoning fallback chain'**
  String get upstreamFallbackHeader;

  /// No description provided for @modelGemma26.
  ///
  /// In en, this message translates to:
  /// **'google/gemma-4-26b-a4b-it:free — primary'**
  String get modelGemma26;

  /// No description provided for @modelInkling.
  ///
  /// In en, this message translates to:
  /// **'thinkingmachines/inkling-small:free — fallback 1'**
  String get modelInkling;

  /// No description provided for @modelNemotron.
  ///
  /// In en, this message translates to:
  /// **'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free — fallback 2'**
  String get modelNemotron;

  /// No description provided for @reasoningTokensLabel.
  ///
  /// In en, this message translates to:
  /// **'Capture reasoning tokens'**
  String get reasoningTokensLabel;

  /// No description provided for @reasoningTokensHint.
  ///
  /// In en, this message translates to:
  /// **'Reports reasoning tokens via chunk.usage.completionTokensDetails.reasoningTokens'**
  String get reasoningTokensHint;

  /// No description provided for @latencyFirstToken.
  ///
  /// In en, this message translates to:
  /// **'⏱ first audio token: {ms} ms'**
  String latencyFirstToken(int ms);

  /// No description provided for @aboutBody.
  ///
  /// In en, this message translates to:
  /// **'SpectruLenPor — YOLO26-Nano on-device object detection + Moondream3 cloud vision + OpenRouter gemma→inkling→nemotron reasoning chain + streamed fish-audio TTS + Wikipedia + PubChem + DuckDuckGo citations + Google AI Overviews-style inline [n] citations + fact-checking + auto-updating structured context + chat with mic. (See Version card in Settings for the current build + git SHA.)\n\nPipeline: phone camera / ESP32-CAM → YOLO26-Nano bounding boxes → user taps box → dual capture (clean + boxes) → Moondream analyzeSelected → LLM scientific context with citations + fact-checking → auto-narrate → chat session with auto-updating context.\n\nMalak Adel Sayed Hassan (student) · Abdoul-Rahman Ayman Mohamed (developer) · Grade 1 secondary, Class 3/1 · Ashmounin Secondary School · Budget: 2,500–6,000 EGP.'**
  String get aboutBody;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['ar', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AppLocalizationsAr();
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
