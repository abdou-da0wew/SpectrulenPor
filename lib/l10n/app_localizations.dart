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
  /// **'liquid/inkling-small:free — fallback 1'**
  String get modelInkling;

  /// No description provided for @modelNemotron.
  ///
  /// In en, this message translates to:
  /// **'nvidia/nemotron-3-nano-30b-a3b:free — fallback 2'**
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
  /// **'first audio token: {ms} ms'**
  String latencyFirstToken(int ms);

  /// No description provided for @live.
  ///
  /// In en, this message translates to:
  /// **'Live'**
  String get live;

  /// No description provided for @scanningGlasses.
  ///
  /// In en, this message translates to:
  /// **'Scanning glasses…'**
  String get scanningGlasses;

  /// No description provided for @negotiatingStream.
  ///
  /// In en, this message translates to:
  /// **'Negotiating stream…'**
  String get negotiatingStream;

  /// No description provided for @waitingFirstFrame.
  ///
  /// In en, this message translates to:
  /// **'Waiting for first frame…'**
  String get waitingFirstFrame;

  /// No description provided for @btPermissionsRequired.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth permissions required'**
  String get btPermissionsRequired;

  /// No description provided for @turnOnBluetooth.
  ///
  /// In en, this message translates to:
  /// **'Turn on Bluetooth'**
  String get turnOnBluetooth;

  /// No description provided for @btConnectionError.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth connection error'**
  String get btConnectionError;

  /// No description provided for @wifiConfigTitle.
  ///
  /// In en, this message translates to:
  /// **'Set up glasses WiFi'**
  String get wifiConfigTitle;

  /// No description provided for @wifiSsidLabel.
  ///
  /// In en, this message translates to:
  /// **'WiFi network name (SSID)'**
  String get wifiSsidLabel;

  /// No description provided for @wifiPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Password (leave empty for an open network)'**
  String get wifiPasswordLabel;

  /// No description provided for @wifiSaveConnect.
  ///
  /// In en, this message translates to:
  /// **'Save and reboot glasses'**
  String get wifiSaveConnect;

  /// No description provided for @wifiConfigured.
  ///
  /// In en, this message translates to:
  /// **'WiFi profile saved on the glasses'**
  String get wifiConfigured;

  /// No description provided for @wifiConnected.
  ///
  /// In en, this message translates to:
  /// **'Glasses video verified over WiFi'**
  String get wifiConnected;

  /// No description provided for @wifiDisconnected.
  ///
  /// In en, this message translates to:
  /// **'WiFi video disconnected'**
  String get wifiDisconnected;

  /// No description provided for @glassesIpLabel.
  ///
  /// In en, this message translates to:
  /// **'Glasses IPv4 address'**
  String get glassesIpLabel;

  /// No description provided for @startUdpVideo.
  ///
  /// In en, this message translates to:
  /// **'Connect WiFi video'**
  String get startUdpVideo;

  /// No description provided for @stopVideo.
  ///
  /// In en, this message translates to:
  /// **'Disconnect video'**
  String get stopVideo;

  /// No description provided for @refreshStatus.
  ///
  /// In en, this message translates to:
  /// **'Read BLE status'**
  String get refreshStatus;

  /// No description provided for @restartEsp.
  ///
  /// In en, this message translates to:
  /// **'Restart glasses'**
  String get restartEsp;

  /// No description provided for @alreadyConnected.
  ///
  /// In en, this message translates to:
  /// **'Video connected'**
  String get alreadyConnected;

  /// No description provided for @shutdownGlasses.
  ///
  /// In en, this message translates to:
  /// **'Standby'**
  String get shutdownGlasses;

  /// No description provided for @setupIdle.
  ///
  /// In en, this message translates to:
  /// **'Connect BLE to set up, or enter the IP of configured glasses.'**
  String get setupIdle;

  /// No description provided for @setupPairing.
  ///
  /// In en, this message translates to:
  /// **'Verifying the glasses setup code…'**
  String get setupPairing;

  /// No description provided for @setupProvisioning.
  ///
  /// In en, this message translates to:
  /// **'Waiting for saved-profile confirmation and device identity…'**
  String get setupProvisioning;

  /// No description provided for @setupRebooting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for reboot confirmation and BLE disconnection…'**
  String get setupRebooting;

  /// No description provided for @setupAwaitingIp.
  ///
  /// In en, this message translates to:
  /// **'Profile saved. Connect your phone to the same WiFi, then enter the glasses IP.'**
  String get setupAwaitingIp;

  /// No description provided for @setupWaitingFrame.
  ///
  /// In en, this message translates to:
  /// **'Waiting for a complete, readable image from the glasses…'**
  String get setupWaitingFrame;

  /// No description provided for @setupFailed.
  ///
  /// In en, this message translates to:
  /// **'Setup could not be confirmed. See the message below.'**
  String get setupFailed;

  /// No description provided for @setupManualIpHint.
  ///
  /// In en, this message translates to:
  /// **'Find the IP in your router\'s connected-device list using the saved MAC. This firmware has no automatic discovery and no BLE status after reboot.'**
  String get setupManualIpHint;

  /// No description provided for @setupRecoveryHint.
  ///
  /// In en, this message translates to:
  /// **'The profile may already be saved. Do not resend it automatically. Check the router or the device\'s serial output before retrying; reconfiguration after reboot needs an explicit setup reset.'**
  String get setupRecoveryHint;

  /// No description provided for @setupCredentialsHint.
  ///
  /// In en, this message translates to:
  /// **'SSID: 1–32 UTF-8 bytes. Password: empty, 8–63 bytes, or 64 hexadecimal characters. Use a trusted local network; setup and UDP control are not encrypted.'**
  String get setupCredentialsHint;

  /// No description provided for @setupIdentity.
  ///
  /// In en, this message translates to:
  /// **'Device: {hostname} · MAC: {mac}'**
  String setupIdentity(String hostname, String mac);

  /// No description provided for @setupNetwork.
  ///
  /// In en, this message translates to:
  /// **'Network: {ssid}'**
  String setupNetwork(String ssid);

  /// No description provided for @setupEndpoint.
  ///
  /// In en, this message translates to:
  /// **'IPv4 address: {ip}'**
  String setupEndpoint(String ip);

  /// No description provided for @setupRetryReboot.
  ///
  /// In en, this message translates to:
  /// **'Retry reboot only'**
  String get setupRetryReboot;

  /// No description provided for @wifiOnlyControlsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Restart, standby and status queries are unavailable in WiFi-only mode. Use the physical reset button to restart the glasses.'**
  String get wifiOnlyControlsUnavailable;

  /// No description provided for @pauseVideo.
  ///
  /// In en, this message translates to:
  /// **'Pause video'**
  String get pauseVideo;

  /// No description provided for @resumeVideo.
  ///
  /// In en, this message translates to:
  /// **'Resume video'**
  String get resumeVideo;

  /// No description provided for @requestOneFrame.
  ///
  /// In en, this message translates to:
  /// **'Request one image'**
  String get requestOneFrame;

  /// No description provided for @videoPaused.
  ///
  /// In en, this message translates to:
  /// **'Video paused; the WiFi listener remains open.'**
  String get videoPaused;

  /// No description provided for @setupErrorBleUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Could not connect to setup BLE. Check Bluetooth and permissions. Configured glasses use WiFi only.'**
  String get setupErrorBleUnavailable;

  /// No description provided for @setupErrorBleWrite.
  ///
  /// In en, this message translates to:
  /// **'The glasses did not accept the command. Check the BLE connection before trying again.'**
  String get setupErrorBleWrite;

  /// No description provided for @setupErrorAckTimeout.
  ///
  /// In en, this message translates to:
  /// **'No matching confirmation arrived from the glasses. The command may have reached the device; do not repeat profile saving automatically.'**
  String get setupErrorAckTimeout;

  /// No description provided for @setupErrorCredentials.
  ///
  /// In en, this message translates to:
  /// **'Check the network name and password lengths. Neither field may contain a NUL character.'**
  String get setupErrorCredentials;

  /// No description provided for @setupErrorIdentity.
  ///
  /// In en, this message translates to:
  /// **'The returned device MAC or hostname was invalid. Setup has not been confirmed.'**
  String get setupErrorIdentity;

  /// No description provided for @setupErrorPairing.
  ///
  /// In en, this message translates to:
  /// **'Pairing was not confirmed for this BLE connection. Reconnect and verify setup first.'**
  String get setupErrorPairing;

  /// No description provided for @setupErrorBusy.
  ///
  /// In en, this message translates to:
  /// **'Another glasses operation is still running. Wait for it to finish.'**
  String get setupErrorBusy;

  /// No description provided for @setupErrorConnectionLost.
  ///
  /// In en, this message translates to:
  /// **'BLE disconnected before confirmation. Check the device before repeating setup.'**
  String get setupErrorConnectionLost;

  /// No description provided for @setupErrorReboot.
  ///
  /// In en, this message translates to:
  /// **'The reboot command was confirmed, but BLE did not disconnect in time. Check the glasses before retrying.'**
  String get setupErrorReboot;

  /// No description provided for @setupErrorIp.
  ///
  /// In en, this message translates to:
  /// **'Enter the glasses\' valid IPv4 address from your router, not a hostname or broadcast address.'**
  String get setupErrorIp;

  /// No description provided for @setupErrorUdp.
  ///
  /// In en, this message translates to:
  /// **'Could not open or send on the WiFi video connection. Check your phone\'s network and try again.'**
  String get setupErrorUdp;

  /// No description provided for @setupErrorUdpTimeout.
  ///
  /// In en, this message translates to:
  /// **'No readable image arrived. Check the IP, the glasses\' power, and that both devices use the same WiFi without client isolation.'**
  String get setupErrorUdpTimeout;

  /// No description provided for @setupErrorUdpStalled.
  ///
  /// In en, this message translates to:
  /// **'Glasses video stopped arriving. The connection is no longer ready; check WiFi and reconnect.'**
  String get setupErrorUdpStalled;

  /// No description provided for @setupErrorUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This control is not supported over WiFi. It needs an active setup BLE connection.'**
  String get setupErrorUnsupported;

  /// No description provided for @tbDocumentTitle.
  ///
  /// In en, this message translates to:
  /// **'Firmware testbench | SpectruLenPor'**
  String get tbDocumentTitle;

  /// No description provided for @tbSkipToWorkspace.
  ///
  /// In en, this message translates to:
  /// **'Skip to instrument controls'**
  String get tbSkipToWorkspace;

  /// No description provided for @tbInstrumentSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Firmware verification instrument'**
  String get tbInstrumentSubtitle;

  /// No description provided for @tbLanguage.
  ///
  /// In en, this message translates to:
  /// **'Interface language'**
  String get tbLanguage;

  /// No description provided for @tbLanguageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get tbLanguageEnglish;

  /// No description provided for @tbLanguageArabic.
  ///
  /// In en, this message translates to:
  /// **'Arabic'**
  String get tbLanguageArabic;

  /// No description provided for @tbLocalWorkbench.
  ///
  /// In en, this message translates to:
  /// **'Local workbench / hardware verification'**
  String get tbLocalWorkbench;

  /// No description provided for @tbDashboardTitle.
  ///
  /// In en, this message translates to:
  /// **'Firmware testbench'**
  String get tbDashboardTitle;

  /// No description provided for @tbOperationInProgress.
  ///
  /// In en, this message translates to:
  /// **'Operation in progress'**
  String get tbOperationInProgress;

  /// No description provided for @tbBackendConnected.
  ///
  /// In en, this message translates to:
  /// **'Local controller online'**
  String get tbBackendConnected;

  /// No description provided for @tbBackendUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Local controller unavailable'**
  String get tbBackendUnavailable;

  /// No description provided for @tbBackendUnavailableHint.
  ///
  /// In en, this message translates to:
  /// **'Check that the testbench server is running. The dashboard will reconnect automatically; hardware commands will not be retried.'**
  String get tbBackendUnavailableHint;

  /// No description provided for @tbDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss message'**
  String get tbDismiss;

  /// No description provided for @tbGuidedWorkflow.
  ///
  /// In en, this message translates to:
  /// **'Commissioning sequence'**
  String get tbGuidedWorkflow;

  /// No description provided for @tbStepConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get tbStepConnect;

  /// No description provided for @tbStepConnectHint.
  ///
  /// In en, this message translates to:
  /// **'Discover and authorize the BLE fixture.'**
  String get tbStepConnectHint;

  /// No description provided for @tbStepProvision.
  ///
  /// In en, this message translates to:
  /// **'Provision'**
  String get tbStepProvision;

  /// No description provided for @tbStepProvisionHint.
  ///
  /// In en, this message translates to:
  /// **'Save the WiFi configuration once.'**
  String get tbStepProvisionHint;

  /// No description provided for @tbStepReboot.
  ///
  /// In en, this message translates to:
  /// **'Reboot'**
  String get tbStepReboot;

  /// No description provided for @tbStepRebootHint.
  ///
  /// In en, this message translates to:
  /// **'Wait for a fresh WiFi-only boot.'**
  String get tbStepRebootHint;

  /// No description provided for @tbStepAttach.
  ///
  /// In en, this message translates to:
  /// **'Attach'**
  String get tbStepAttach;

  /// No description provided for @tbStepAttachHint.
  ///
  /// In en, this message translates to:
  /// **'Enter the device IP for the UDP session.'**
  String get tbStepAttachHint;

  /// No description provided for @tbStepVerify.
  ///
  /// In en, this message translates to:
  /// **'Verify'**
  String get tbStepVerify;

  /// No description provided for @tbStepVerifyHint.
  ///
  /// In en, this message translates to:
  /// **'Inspect frames and record test evidence.'**
  String get tbStepVerifyHint;

  /// No description provided for @tbLocalOnly.
  ///
  /// In en, this message translates to:
  /// **'Local by design'**
  String get tbLocalOnly;

  /// No description provided for @tbLocalOnlyHint.
  ///
  /// In en, this message translates to:
  /// **'Frames and control requests stay on this machine and your local network. No cloud services or telemetry.'**
  String get tbLocalOnlyHint;

  /// No description provided for @tbCameraChannel.
  ///
  /// In en, this message translates to:
  /// **'01 / camera channel'**
  String get tbCameraChannel;

  /// No description provided for @tbPreviewTitle.
  ///
  /// In en, this message translates to:
  /// **'Frame monitor'**
  String get tbPreviewTitle;

  /// No description provided for @tbFrameAlt.
  ///
  /// In en, this message translates to:
  /// **'Latest camera frame received from the firmware fixture'**
  String get tbFrameAlt;

  /// No description provided for @tbWaitingForFrame.
  ///
  /// In en, this message translates to:
  /// **'Awaiting camera signal'**
  String get tbWaitingForFrame;

  /// No description provided for @tbWaitingForFrameHint.
  ///
  /// In en, this message translates to:
  /// **'Connect or attach the fixture, then start streaming or request a single frame.'**
  String get tbWaitingForFrameHint;

  /// No description provided for @tbFrameSequence.
  ///
  /// In en, this message translates to:
  /// **'Frame'**
  String get tbFrameSequence;

  /// No description provided for @tbTransport.
  ///
  /// In en, this message translates to:
  /// **'Transport'**
  String get tbTransport;

  /// No description provided for @tbSingleFrame.
  ///
  /// In en, this message translates to:
  /// **'Single frame'**
  String get tbSingleFrame;

  /// No description provided for @tbStartStream.
  ///
  /// In en, this message translates to:
  /// **'Start stream'**
  String get tbStartStream;

  /// No description provided for @tbPauseStream.
  ///
  /// In en, this message translates to:
  /// **'Pause stream'**
  String get tbPauseStream;

  /// No description provided for @tbEnableFlash.
  ///
  /// In en, this message translates to:
  /// **'Light on'**
  String get tbEnableFlash;

  /// No description provided for @tbDisableFlash.
  ///
  /// In en, this message translates to:
  /// **'Light off'**
  String get tbDisableFlash;

  /// No description provided for @tbFlashCommandHint.
  ///
  /// In en, this message translates to:
  /// **'This control reflects the last requested light setting, not measured hardware feedback.'**
  String get tbFlashCommandHint;

  /// No description provided for @tbReceivedFps.
  ///
  /// In en, this message translates to:
  /// **'Received rate'**
  String get tbReceivedFps;

  /// No description provided for @tbFpsUnit.
  ///
  /// In en, this message translates to:
  /// **'frames/s'**
  String get tbFpsUnit;

  /// No description provided for @tbFramesReceived.
  ///
  /// In en, this message translates to:
  /// **'Frames received'**
  String get tbFramesReceived;

  /// No description provided for @tbIncompleteFrames.
  ///
  /// In en, this message translates to:
  /// **'Incomplete frames'**
  String get tbIncompleteFrames;

  /// No description provided for @tbDatagrams.
  ///
  /// In en, this message translates to:
  /// **'Datagrams'**
  String get tbDatagrams;

  /// No description provided for @tbFrameAge.
  ///
  /// In en, this message translates to:
  /// **'Frame age'**
  String get tbFrameAge;

  /// No description provided for @tbSecondsUnit.
  ///
  /// In en, this message translates to:
  /// **'s'**
  String get tbSecondsUnit;

  /// No description provided for @tbFrameBytes.
  ///
  /// In en, this message translates to:
  /// **'Payload'**
  String get tbFrameBytes;

  /// No description provided for @tbBytesUnit.
  ///
  /// In en, this message translates to:
  /// **'bytes'**
  String get tbBytesUnit;

  /// No description provided for @tbFixtureControls.
  ///
  /// In en, this message translates to:
  /// **'Fixture / controls'**
  String get tbFixtureControls;

  /// No description provided for @tbConnectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection desk'**
  String get tbConnectionTitle;

  /// No description provided for @tbBleLink.
  ///
  /// In en, this message translates to:
  /// **'BLE authorization'**
  String get tbBleLink;

  /// No description provided for @tbAdapterLabel.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth adapter'**
  String get tbAdapterLabel;

  /// No description provided for @tbAdapterHint.
  ///
  /// In en, this message translates to:
  /// **'Uses the server adapter when left blank. Change it before connecting.'**
  String get tbAdapterHint;

  /// No description provided for @tbConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect over BLE'**
  String get tbConnect;

  /// No description provided for @tbDeviceMac.
  ///
  /// In en, this message translates to:
  /// **'Device MAC'**
  String get tbDeviceMac;

  /// No description provided for @tbDeviceHostname.
  ///
  /// In en, this message translates to:
  /// **'Device hostname'**
  String get tbDeviceHostname;

  /// No description provided for @tbWifiProvisioning.
  ///
  /// In en, this message translates to:
  /// **'WiFi provisioning'**
  String get tbWifiProvisioning;

  /// No description provided for @tbUseNetworkManager.
  ///
  /// In en, this message translates to:
  /// **'Use the active NetworkManager connection'**
  String get tbUseNetworkManager;

  /// No description provided for @tbNetworkManagerHint.
  ///
  /// In en, this message translates to:
  /// **'The local controller reads the active network credentials. No password is displayed or stored by this dashboard.'**
  String get tbNetworkManagerHint;

  /// No description provided for @tbSsidLabel.
  ///
  /// In en, this message translates to:
  /// **'Network name (SSID)'**
  String get tbSsidLabel;

  /// No description provided for @tbPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'WiFi password'**
  String get tbPasswordLabel;

  /// No description provided for @tbPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'Masked, held in memory only and cleared on submit. Leave blank only for an open network.'**
  String get tbPasswordHint;

  /// No description provided for @tbSaveAndReboot.
  ///
  /// In en, this message translates to:
  /// **'Save WiFi and reboot'**
  String get tbSaveAndReboot;

  /// No description provided for @tbSetupHint.
  ///
  /// In en, this message translates to:
  /// **'Save once, await the exact acknowledgment, then reboot. A failed setup is never retried automatically.'**
  String get tbSetupHint;

  /// No description provided for @tbRebootOnly.
  ///
  /// In en, this message translates to:
  /// **'Reboot only'**
  String get tbRebootOnly;

  /// No description provided for @tbRebootHint.
  ///
  /// In en, this message translates to:
  /// **'Separate BLE reboot command. It does not save or erase WiFi credentials.'**
  String get tbRebootHint;

  /// No description provided for @tbUdpAttach.
  ///
  /// In en, this message translates to:
  /// **'UDP session'**
  String get tbUdpAttach;

  /// No description provided for @tbIpLabel.
  ///
  /// In en, this message translates to:
  /// **'Device IPv4 address'**
  String get tbIpLabel;

  /// No description provided for @tbIpHint.
  ///
  /// In en, this message translates to:
  /// **'Enter the IP from your router or fresh UART output. Firmware does not provide mDNS discovery.'**
  String get tbIpHint;

  /// No description provided for @tbAttach.
  ///
  /// In en, this message translates to:
  /// **'Attach to device IP'**
  String get tbAttach;

  /// No description provided for @tbActiveIp.
  ///
  /// In en, this message translates to:
  /// **'Attached IP'**
  String get tbActiveIp;

  /// No description provided for @tbLocalListener.
  ///
  /// In en, this message translates to:
  /// **'Local listener'**
  String get tbLocalListener;

  /// No description provided for @tbUartLabel.
  ///
  /// In en, this message translates to:
  /// **'Diagnostic UART (server configuration)'**
  String get tbUartLabel;

  /// No description provided for @tbUartHint.
  ///
  /// In en, this message translates to:
  /// **'Read-only startup setting. UART output can provide the device IP; it is diagnostic evidence, not network discovery.'**
  String get tbUartHint;

  /// No description provided for @tbUartAvailable.
  ///
  /// In en, this message translates to:
  /// **'UART diagnostics available'**
  String get tbUartAvailable;

  /// No description provided for @tbUartUnavailable.
  ///
  /// In en, this message translates to:
  /// **'UART diagnostics unavailable'**
  String get tbUartUnavailable;

  /// No description provided for @tbDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect fixture'**
  String get tbDisconnect;

  /// No description provided for @tbDisconnectHint.
  ///
  /// In en, this message translates to:
  /// **'Stops the session without clearing saved network settings.'**
  String get tbDisconnectHint;

  /// No description provided for @tbVerificationChannel.
  ///
  /// In en, this message translates to:
  /// **'02 / verification channel'**
  String get tbVerificationChannel;

  /// No description provided for @tbTestTitle.
  ///
  /// In en, this message translates to:
  /// **'Test runner'**
  String get tbTestTitle;

  /// No description provided for @tbProfileLabel.
  ///
  /// In en, this message translates to:
  /// **'Test profile'**
  String get tbProfileLabel;

  /// No description provided for @tbProfileSmoke.
  ///
  /// In en, this message translates to:
  /// **'Smoke / quick verification'**
  String get tbProfileSmoke;

  /// No description provided for @tbProfileFull.
  ///
  /// In en, this message translates to:
  /// **'Full / configuration-changing suite'**
  String get tbProfileFull;

  /// No description provided for @tbProfileMobileFlow.
  ///
  /// In en, this message translates to:
  /// **'Mobile flow / commissioning'**
  String get tbProfileMobileFlow;

  /// No description provided for @tbProfileMissingAp.
  ///
  /// In en, this message translates to:
  /// **'Missing AP / recovery boundary'**
  String get tbProfileMissingAp;

  /// No description provided for @tbProfileSoak.
  ///
  /// In en, this message translates to:
  /// **'Soak / sustained streaming'**
  String get tbProfileSoak;

  /// No description provided for @tbProfileUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown profile'**
  String get tbProfileUnknown;

  /// No description provided for @tbProfileSmokeHint.
  ///
  /// In en, this message translates to:
  /// **'Quick fixture checks. Review each recorded result; an unavailable check is not a pass.'**
  String get tbProfileSmokeHint;

  /// No description provided for @tbProfileFullHint.
  ///
  /// In en, this message translates to:
  /// **'Exercises configuration boundaries before final commissioning. Requires a fresh BLE setup fixture and explicit configuration authorization.'**
  String get tbProfileFullHint;

  /// No description provided for @tbProfileMobileFlowHint.
  ///
  /// In en, this message translates to:
  /// **'Verifies the app-style commissioning sequence: BLE setup, WiFi-only reboot, IP attachment and decoded UDP frames.'**
  String get tbProfileMobileFlowHint;

  /// No description provided for @tbProfileMissingApHint.
  ///
  /// In en, this message translates to:
  /// **'Tests boot with an unreachable access point. Saved network settings change and explicit recovery may be required afterward.'**
  String get tbProfileMissingApHint;

  /// No description provided for @tbProfileSoakHint.
  ///
  /// In en, this message translates to:
  /// **'Monitors sustained frame delivery for the selected duration. Missing frames and incomplete datagrams remain visible in the evidence.'**
  String get tbProfileSoakHint;

  /// No description provided for @tbDurationLabel.
  ///
  /// In en, this message translates to:
  /// **'Duration (seconds)'**
  String get tbDurationLabel;

  /// No description provided for @tbRunTests.
  ///
  /// In en, this message translates to:
  /// **'Run tests'**
  String get tbRunTests;

  /// No description provided for @tbCancelRun.
  ///
  /// In en, this message translates to:
  /// **'Cancel operation'**
  String get tbCancelRun;

  /// No description provided for @tbDestructiveProfileWarning.
  ///
  /// In en, this message translates to:
  /// **'Changes saved WiFi configuration. Requires a fresh setup fixture and explicit confirmation; no automatic erase or recovery.'**
  String get tbDestructiveProfileWarning;

  /// No description provided for @tbChecksRecorded.
  ///
  /// In en, this message translates to:
  /// **'checks recorded'**
  String get tbChecksRecorded;

  /// No description provided for @tbRunProgress.
  ///
  /// In en, this message translates to:
  /// **'Test run progress'**
  String get tbRunProgress;

  /// No description provided for @tbJobId.
  ///
  /// In en, this message translates to:
  /// **'Job ID'**
  String get tbJobId;

  /// No description provided for @tbNoTestResults.
  ///
  /// In en, this message translates to:
  /// **'No checks recorded yet'**
  String get tbNoTestResults;

  /// No description provided for @tbNoTestResultsHint.
  ///
  /// In en, this message translates to:
  /// **'Choose a profile to produce a local evidence report.'**
  String get tbNoTestResultsHint;

  /// No description provided for @tbTestResults.
  ///
  /// In en, this message translates to:
  /// **'Recorded firmware test results'**
  String get tbTestResults;

  /// No description provided for @tbCheckName.
  ///
  /// In en, this message translates to:
  /// **'Check'**
  String get tbCheckName;

  /// No description provided for @tbOutcome.
  ///
  /// In en, this message translates to:
  /// **'Outcome'**
  String get tbOutcome;

  /// No description provided for @tbDuration.
  ///
  /// In en, this message translates to:
  /// **'Duration'**
  String get tbDuration;

  /// No description provided for @tbDetails.
  ///
  /// In en, this message translates to:
  /// **'Details / code'**
  String get tbDetails;

  /// No description provided for @tbEvidenceChannel.
  ///
  /// In en, this message translates to:
  /// **'03 / evidence channel'**
  String get tbEvidenceChannel;

  /// No description provided for @tbReportTitle.
  ///
  /// In en, this message translates to:
  /// **'Session evidence'**
  String get tbReportTitle;

  /// No description provided for @tbDownloadReport.
  ///
  /// In en, this message translates to:
  /// **'Download report'**
  String get tbDownloadReport;

  /// No description provided for @tbReportHint.
  ///
  /// In en, this message translates to:
  /// **'Current server report, including recorded checks and diagnostic evidence.'**
  String get tbReportHint;

  /// No description provided for @tbViewReport.
  ///
  /// In en, this message translates to:
  /// **'Inspect report'**
  String get tbViewReport;

  /// No description provided for @tbCloseReport.
  ///
  /// In en, this message translates to:
  /// **'Close report viewer'**
  String get tbCloseReport;

  /// No description provided for @tbCurrentReport.
  ///
  /// In en, this message translates to:
  /// **'Current JSON report'**
  String get tbCurrentReport;

  /// No description provided for @tbEventLog.
  ///
  /// In en, this message translates to:
  /// **'Controller event log'**
  String get tbEventLog;

  /// No description provided for @tbEvents.
  ///
  /// In en, this message translates to:
  /// **'events'**
  String get tbEvents;

  /// No description provided for @tbNoEvents.
  ///
  /// In en, this message translates to:
  /// **'No controller events recorded.'**
  String get tbNoEvents;

  /// No description provided for @tbFooterLocal.
  ///
  /// In en, this message translates to:
  /// **'Local control. No automatic provisioning retries.'**
  String get tbFooterLocal;

  /// No description provided for @tbFooterEvidence.
  ///
  /// In en, this message translates to:
  /// **'Observed evidence only. Unverified is not passed.'**
  String get tbFooterEvidence;

  /// No description provided for @tbCloseConfirmation.
  ///
  /// In en, this message translates to:
  /// **'Close configuration confirmation'**
  String get tbCloseConfirmation;

  /// No description provided for @tbConfigurationChange.
  ///
  /// In en, this message translates to:
  /// **'Configuration change / confirmation required'**
  String get tbConfigurationChange;

  /// No description provided for @tbConfirmTestTitle.
  ///
  /// In en, this message translates to:
  /// **'Authorize this test run'**
  String get tbConfirmTestTitle;

  /// No description provided for @tbConfirmTestDescription.
  ///
  /// In en, this message translates to:
  /// **'This profile can change saved WiFi settings and leave the fixture in WiFi-only boot. Confirm the fixture is ready and that you can restore its configuration yourself.'**
  String get tbConfirmTestDescription;

  /// No description provided for @tbConfirmFreshSetup.
  ///
  /// In en, this message translates to:
  /// **'The fixture is in fresh BLE setup mode with no saved WiFi credentials.'**
  String get tbConfirmFreshSetup;

  /// No description provided for @tbConfirmConfiguration.
  ///
  /// In en, this message translates to:
  /// **'I authorize this test to replace or clear saved WiFi configuration.'**
  String get tbConfirmConfiguration;

  /// No description provided for @tbNoAutomaticErase.
  ///
  /// In en, this message translates to:
  /// **'The dashboard never erases configuration or retries provisioning to recover from a failure. Recovery requires a separate, explicit action.'**
  String get tbNoAutomaticErase;

  /// No description provided for @tbGoBack.
  ///
  /// In en, this message translates to:
  /// **'Go back'**
  String get tbGoBack;

  /// No description provided for @tbConfirmAndRun.
  ///
  /// In en, this message translates to:
  /// **'Authorize and run'**
  String get tbConfirmAndRun;

  /// No description provided for @tbJavaScriptRequired.
  ///
  /// In en, this message translates to:
  /// **'Enable JavaScript to use the local testbench controls.'**
  String get tbJavaScriptRequired;

  /// No description provided for @tbPhaseDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get tbPhaseDisconnected;

  /// No description provided for @tbPhaseBleSetup.
  ///
  /// In en, this message translates to:
  /// **'BLE setup'**
  String get tbPhaseBleSetup;

  /// No description provided for @tbPhasePaired.
  ///
  /// In en, this message translates to:
  /// **'BLE authorized'**
  String get tbPhasePaired;

  /// No description provided for @tbPhaseProvisioned.
  ///
  /// In en, this message translates to:
  /// **'WiFi saved'**
  String get tbPhaseProvisioned;

  /// No description provided for @tbPhaseRebooting.
  ///
  /// In en, this message translates to:
  /// **'Rebooting'**
  String get tbPhaseRebooting;

  /// No description provided for @tbPhaseWifiReady.
  ///
  /// In en, this message translates to:
  /// **'WiFi ready'**
  String get tbPhaseWifiReady;

  /// No description provided for @tbPhaseStreaming.
  ///
  /// In en, this message translates to:
  /// **'Streaming'**
  String get tbPhaseStreaming;

  /// No description provided for @tbPhasePaused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get tbPhasePaused;

  /// No description provided for @tbPhaseError.
  ///
  /// In en, this message translates to:
  /// **'Controller error'**
  String get tbPhaseError;

  /// No description provided for @tbPhaseUnknown.
  ///
  /// In en, this message translates to:
  /// **'Awaiting state'**
  String get tbPhaseUnknown;

  /// No description provided for @tbGuideDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Connect a fresh BLE fixture, or attach a device already running in WiFi mode using its IP.'**
  String get tbGuideDisconnected;

  /// No description provided for @tbGuideBleSetup.
  ///
  /// In en, this message translates to:
  /// **'Select the network, then save and reboot. Setup authorizes the BLE link before sending credentials.'**
  String get tbGuideBleSetup;

  /// No description provided for @tbGuidePaired.
  ///
  /// In en, this message translates to:
  /// **'Select the active local network or enter its credentials, then save and reboot once.'**
  String get tbGuidePaired;

  /// No description provided for @tbGuideProvisioned.
  ///
  /// In en, this message translates to:
  /// **'Credentials were saved. Await the setup reboot, or use the separate reboot control if required.'**
  String get tbGuideProvisioned;

  /// No description provided for @tbGuideRebooting.
  ///
  /// In en, this message translates to:
  /// **'Wait for fresh boot evidence. Do not resend credentials while the device restarts.'**
  String get tbGuideRebooting;

  /// No description provided for @tbGuideWifiReady.
  ///
  /// In en, this message translates to:
  /// **'Enter the device IP from your router or UART, then attach the UDP session if not already attached.'**
  String get tbGuideWifiReady;

  /// No description provided for @tbGuideStreaming.
  ///
  /// In en, this message translates to:
  /// **'Inspect the live frames and run the appropriate verification profile.'**
  String get tbGuideStreaming;

  /// No description provided for @tbGuidePaused.
  ///
  /// In en, this message translates to:
  /// **'The session is paused. Resume streaming or request a single frame.'**
  String get tbGuidePaused;

  /// No description provided for @tbGuideError.
  ///
  /// In en, this message translates to:
  /// **'Review the controller error and evidence before taking a separate recovery action.'**
  String get tbGuideError;

  /// No description provided for @tbGuideUnknown.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the local controller to report the fixture state.'**
  String get tbGuideUnknown;

  /// No description provided for @tbPreviewEmpty.
  ///
  /// In en, this message translates to:
  /// **'No signal'**
  String get tbPreviewEmpty;

  /// No description provided for @tbPreviewLive.
  ///
  /// In en, this message translates to:
  /// **'Live'**
  String get tbPreviewLive;

  /// No description provided for @tbPreviewStale.
  ///
  /// In en, this message translates to:
  /// **'Stale frame'**
  String get tbPreviewStale;

  /// No description provided for @tbPreviewPaused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get tbPreviewPaused;

  /// No description provided for @tbPreviewReady.
  ///
  /// In en, this message translates to:
  /// **'Last frame'**
  String get tbPreviewReady;

  /// No description provided for @tbFrameStaleHint.
  ///
  /// In en, this message translates to:
  /// **'This is an older frame, not proof of a live stream.'**
  String get tbFrameStaleHint;

  /// No description provided for @tbFramePausedHint.
  ///
  /// In en, this message translates to:
  /// **'Streaming is paused. The last received frame is retained.'**
  String get tbFramePausedHint;

  /// No description provided for @tbNoTransport.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get tbNoTransport;

  /// No description provided for @tbUnknownValue.
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get tbUnknownValue;

  /// No description provided for @tbStatusIdle.
  ///
  /// In en, this message translates to:
  /// **'Idle'**
  String get tbStatusIdle;

  /// No description provided for @tbStatusQueued.
  ///
  /// In en, this message translates to:
  /// **'Queued'**
  String get tbStatusQueued;

  /// No description provided for @tbStatusRunning.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get tbStatusRunning;

  /// No description provided for @tbStatusStarted.
  ///
  /// In en, this message translates to:
  /// **'Started'**
  String get tbStatusStarted;

  /// No description provided for @tbStatusPassed.
  ///
  /// In en, this message translates to:
  /// **'Passed'**
  String get tbStatusPassed;

  /// No description provided for @tbStatusSuccess.
  ///
  /// In en, this message translates to:
  /// **'Succeeded'**
  String get tbStatusSuccess;

  /// No description provided for @tbStatusCompleted.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get tbStatusCompleted;

  /// No description provided for @tbStatusFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get tbStatusFailed;

  /// No description provided for @tbStatusRejected.
  ///
  /// In en, this message translates to:
  /// **'Rejected'**
  String get tbStatusRejected;

  /// No description provided for @tbStatusCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get tbStatusCancelled;

  /// No description provided for @tbStatusCancelling.
  ///
  /// In en, this message translates to:
  /// **'Cancelling'**
  String get tbStatusCancelling;

  /// No description provided for @tbStatusSkipped.
  ///
  /// In en, this message translates to:
  /// **'Skipped'**
  String get tbStatusSkipped;

  /// No description provided for @tbStatusUnverified.
  ///
  /// In en, this message translates to:
  /// **'Unverified'**
  String get tbStatusUnverified;

  /// No description provided for @tbStatusWarning.
  ///
  /// In en, this message translates to:
  /// **'Warning'**
  String get tbStatusWarning;

  /// No description provided for @tbStatusReady.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get tbStatusReady;

  /// No description provided for @tbStatusUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown status'**
  String get tbStatusUnknown;

  /// No description provided for @tbStreamOperation.
  ///
  /// In en, this message translates to:
  /// **'Stream control'**
  String get tbStreamOperation;

  /// No description provided for @tbFlashOperation.
  ///
  /// In en, this message translates to:
  /// **'Light control'**
  String get tbFlashOperation;

  /// No description provided for @tbActionQueued.
  ///
  /// In en, this message translates to:
  /// **'Command accepted by the local controller. Await its recorded outcome.'**
  String get tbActionQueued;

  /// No description provided for @tbCancellationRequested.
  ///
  /// In en, this message translates to:
  /// **'Cancellation requested. Wait for the controller to finish cleanup.'**
  String get tbCancellationRequested;

  /// No description provided for @tbActionRejected.
  ///
  /// In en, this message translates to:
  /// **'The controller rejected this operation. Review the error code.'**
  String get tbActionRejected;

  /// No description provided for @tbRequestFailed.
  ///
  /// In en, this message translates to:
  /// **'The local request failed. Review the error code before trying again.'**
  String get tbRequestFailed;

  /// No description provided for @tbInvalidResponse.
  ///
  /// In en, this message translates to:
  /// **'The controller returned an invalid response.'**
  String get tbInvalidResponse;

  /// No description provided for @tbConfigurationUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Controller configuration is unavailable. Commands are disabled until it can be loaded.'**
  String get tbConfigurationUnavailable;

  /// No description provided for @tbLocalizationUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Could not load the selected language from the local controller.'**
  String get tbLocalizationUnavailable;

  /// No description provided for @tbNoProfiles.
  ///
  /// In en, this message translates to:
  /// **'No supported test profiles are available from this controller.'**
  String get tbNoProfiles;

  /// No description provided for @tbInvalidIp.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid device IPv4 address, with four numbers from 0 to 255.'**
  String get tbInvalidIp;

  /// No description provided for @tbInvalidSsid.
  ///
  /// In en, this message translates to:
  /// **'Enter a network name between 1 and 32 UTF-8 bytes.'**
  String get tbInvalidSsid;

  /// No description provided for @tbInvalidDuration.
  ///
  /// In en, this message translates to:
  /// **'Enter a positive whole number of seconds.'**
  String get tbInvalidDuration;

  /// No description provided for @tbTestFailed.
  ///
  /// In en, this message translates to:
  /// **'The test run failed. Review its recorded checks and error code.'**
  String get tbTestFailed;

  /// No description provided for @tbReportUnavailable.
  ///
  /// In en, this message translates to:
  /// **'No report is available from the local controller.'**
  String get tbReportUnavailable;

  /// No description provided for @tbReportLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading report'**
  String get tbReportLoading;

  /// No description provided for @tbRedacted.
  ///
  /// In en, this message translates to:
  /// **'[redacted]'**
  String get tbRedacted;

  /// No description provided for @tbErrorBusy.
  ///
  /// In en, this message translates to:
  /// **'The fixture is busy. Wait for the current operation or request cancellation.'**
  String get tbErrorBusy;

  /// No description provided for @tbErrorCancelled.
  ///
  /// In en, this message translates to:
  /// **'The operation was cancelled. Review the evidence before starting again.'**
  String get tbErrorCancelled;

  /// No description provided for @tbErrorInvalidRequest.
  ///
  /// In en, this message translates to:
  /// **'The request is not valid for this controller. Review the error code.'**
  String get tbErrorInvalidRequest;

  /// No description provided for @tbErrorInvalidWifi.
  ///
  /// In en, this message translates to:
  /// **'The WiFi credentials are invalid or unavailable. Check the network settings and submit explicitly.'**
  String get tbErrorInvalidWifi;

  /// No description provided for @tbErrorSecurity.
  ///
  /// In en, this message translates to:
  /// **'The controller rejected the request security check. Reload the dashboard before trying again.'**
  String get tbErrorSecurity;

  /// No description provided for @tbErrorNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Connect the fixture or attach its IP before sending this command.'**
  String get tbErrorNotConnected;

  /// No description provided for @tbErrorSetupRequired.
  ///
  /// In en, this message translates to:
  /// **'The fixture is not in the required setup phase. Follow the commissioning sequence.'**
  String get tbErrorSetupRequired;

  /// No description provided for @tbErrorConfirmationRequired.
  ///
  /// In en, this message translates to:
  /// **'This test requires explicit authorization to change the saved configuration.'**
  String get tbErrorConfirmationRequired;

  /// No description provided for @tbErrorRecoveryRequired.
  ///
  /// In en, this message translates to:
  /// **'Configuration recovery is required. Review the evidence and restore the fixture explicitly; no automatic erase or resend.'**
  String get tbErrorRecoveryRequired;

  /// No description provided for @tbErrorUartRequired.
  ///
  /// In en, this message translates to:
  /// **'This check requires diagnostic UART. Configure it when starting the local controller.'**
  String get tbErrorUartRequired;

  /// No description provided for @tbErrorDependency.
  ///
  /// In en, this message translates to:
  /// **'A required local component is unavailable. Review the controller setup and error code.'**
  String get tbErrorDependency;

  /// No description provided for @tbErrorPlatform.
  ///
  /// In en, this message translates to:
  /// **'This operation is not supported on the current platform.'**
  String get tbErrorPlatform;

  /// No description provided for @tbErrorHardwareLocked.
  ///
  /// In en, this message translates to:
  /// **'Another process owns the fixture. Stop that session before connecting here.'**
  String get tbErrorHardwareLocked;

  /// No description provided for @tbErrorFrameTimeout.
  ///
  /// In en, this message translates to:
  /// **'No complete camera frame arrived before the timeout. Review the connection and evidence.'**
  String get tbErrorFrameTimeout;

  /// No description provided for @tbErrorHardware.
  ///
  /// In en, this message translates to:
  /// **'A hardware operation failed. Review the recorded evidence and error code.'**
  String get tbErrorHardware;

  /// No description provided for @tbErrorInternal.
  ///
  /// In en, this message translates to:
  /// **'The local controller could not finish this operation. Review the error code.'**
  String get tbErrorInternal;

  /// No description provided for @aboutBody.
  ///
  /// In en, this message translates to:
  /// **'SpectruLenPor v5.5 — Local YOLO26-Nano ONNX object detection (bundled + auto-download) + Cloud-only policy toggle (keeping YOLO local) + Moondream3 Cloud VLM + OpenRouter gemma→inkling→nemotron reasoning chain + streamed fish-audio/s2.1-pro-free:free TTS + 3-mode scientific RAG (Strict / Detailed / Semantic across 119 Periodic Table elements, 110 chemical compounds/materials, GHS lab safety, PubChem, Wikipedia & Web Search) + Google-Search-style inline [n] citations + claim fact-checking + auto-updating structured ConversationContext + 9-table SQLite WAL Internal Database (saved chats, TTL response cache, logs, hangs/crashes, traces & telemetry).\n\nPipeline: phone camera / ESP32-CAM → local YOLO26-Nano interactive boxes → tap box to lock target marker → press Capture & Analyze for dual JPEG capture (clean + marked) → Moondream3 analyzeSelected → grounded LLM context + fact-checking → persistent chat session with auto-updating context.\n\nMalak Adel Sayed Hassan (student) · Abdoul-Rahman Ayman Mohamed (developer) · Grade 1 secondary, Class 3/1 · Ashmounin Secondary School · Budget: 2,500–6,000 EGP.'**
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
