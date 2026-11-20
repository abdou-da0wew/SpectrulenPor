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
      'SpectruLenPor · Project author: Malak Adel Sayed Hassan · Grade 1 secondary, Class 3/1 · Ashmounin Secondary School';

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
  String get factCheckHeader => 'Candidate source matches';

  @override
  String get factCheckMethodHint =>
      'Text overlap only suggests a possibly relevant source. It does not verify the claim or its scientific correctness.';

  @override
  String factCheckSourceMatchSummary(int matched, int unmatched) {
    return '$matched possible source matches · $unmatched claims without a match';
  }

  @override
  String get modelGemma26 =>
      'google/gemma-4-26b-a4b-it:free — Gemma 4 26B A4B (fallback 1)';

  @override
  String get modelInkling =>
      'thinkingmachines/inkling-2-small:free — Inkling 2 Small (fallback 2)';

  @override
  String get modelNemotron =>
      'nvidia/nemotron-3.5-super-vl:free — Nemotron 3.5 Super VL (primary)';

  @override
  String get reasoningTokensLabel => 'Capture reasoning tokens';

  @override
  String get reasoningTokensHint =>
      'Reports reasoning tokens via chunk.usage.completionTokensDetails.reasoningTokens';

  @override
  String latencyFirstToken(int ms) {
    return 'first audio token: $ms ms';
  }

  @override
  String get live => 'Live';

  @override
  String get scanningGlasses => 'Scanning glasses…';

  @override
  String get negotiatingStream => 'Negotiating stream…';

  @override
  String get waitingFirstFrame => 'Waiting for first frame…';

  @override
  String get btPermissionsRequired => 'Bluetooth permissions required';

  @override
  String get turnOnBluetooth => 'Turn on Bluetooth';

  @override
  String get btConnectionError => 'Bluetooth connection error';

  @override
  String get wifiConfigTitle => 'Set up glasses WiFi';

  @override
  String get wifiSsidLabel => 'WiFi network name (SSID)';

  @override
  String get wifiPasswordLabel => 'Password (leave empty for an open network)';

  @override
  String get wifiSaveConnect => 'Save and reboot glasses';

  @override
  String get wifiConfigured => 'WiFi profile saved on the glasses';

  @override
  String get wifiConnected => 'Glasses video verified over WiFi';

  @override
  String get wifiDisconnected => 'WiFi video disconnected';

  @override
  String get glassesIpLabel => 'Glasses IPv4 address';

  @override
  String get startUdpVideo => 'Connect WiFi video';

  @override
  String get stopVideo => 'Disconnect video';

  @override
  String get refreshStatus => 'Read BLE status';

  @override
  String get restartEsp => 'Restart glasses';

  @override
  String get alreadyConnected => 'Video connected';

  @override
  String get shutdownGlasses => 'Standby';

  @override
  String get setupIdle =>
      'Connect BLE to set up, or enter the IP of configured glasses.';

  @override
  String get setupPairing => 'Verifying the glasses setup code…';

  @override
  String get setupProvisioning =>
      'Waiting for saved-profile confirmation and device identity…';

  @override
  String get setupRebooting =>
      'Waiting for reboot confirmation and BLE disconnection…';

  @override
  String get setupAwaitingIp =>
      'Profile saved. Connect your phone to the same WiFi, then enter the glasses IP.';

  @override
  String get setupWaitingFrame =>
      'Waiting for a complete, readable image from the glasses…';

  @override
  String get setupFailed =>
      'Setup could not be confirmed. See the message below.';

  @override
  String get setupManualIpHint =>
      'Enter the ESP32 IP, or leave this field empty to discover the camera automatically on the same Wi-Fi network.';

  @override
  String get setupRecoveryHint =>
      'The profile may already be saved. Do not resend it automatically. Check the router or the device\'s serial output before retrying; reconfiguration after reboot needs an explicit setup reset.';

  @override
  String get setupCredentialsHint =>
      'SSID: 1–32 UTF-8 bytes. Password: empty, 8–63 bytes, or 64 hexadecimal characters. Use a trusted local network; setup and UDP control are not encrypted.';

  @override
  String setupIdentity(String hostname, String mac) {
    return 'Device: $hostname · MAC: $mac';
  }

  @override
  String setupNetwork(String ssid) {
    return 'Network: $ssid';
  }

  @override
  String setupEndpoint(String ip) {
    return 'IPv4 address: $ip';
  }

  @override
  String get setupRetryReboot => 'Retry reboot only';

  @override
  String get wifiOnlyControlsUnavailable =>
      'Restart, standby and status queries are unavailable in WiFi-only mode. Use the physical reset button to restart the glasses.';

  @override
  String get pauseVideo => 'Pause video';

  @override
  String get resumeVideo => 'Resume video';

  @override
  String get requestOneFrame => 'Request one image';

  @override
  String get videoPaused => 'Video paused; the WiFi listener remains open.';

  @override
  String get setupErrorBleUnavailable =>
      'Could not connect to setup BLE. Check Bluetooth and permissions. Configured glasses use WiFi only.';

  @override
  String get setupErrorBleWrite =>
      'The glasses did not accept the command. Check the BLE connection before trying again.';

  @override
  String get setupErrorAckTimeout =>
      'No matching confirmation arrived from the glasses. The command may have reached the device; do not repeat profile saving automatically.';

  @override
  String get setupErrorCredentials =>
      'Check the network name and password lengths. Neither field may contain a NUL character.';

  @override
  String get setupErrorIdentity =>
      'The returned device MAC or hostname was invalid. Setup has not been confirmed.';

  @override
  String get setupErrorPairing =>
      'Pairing was not confirmed for this BLE connection. Reconnect and verify setup first.';

  @override
  String get setupErrorBusy =>
      'Another glasses operation is still running. Wait for it to finish.';

  @override
  String get setupErrorConnectionLost =>
      'BLE disconnected before confirmation. Check the device before repeating setup.';

  @override
  String get setupErrorReboot =>
      'The reboot command was confirmed, but BLE did not disconnect in time. Check the glasses before retrying.';

  @override
  String get setupErrorIp =>
      'Enter the glasses\' valid IPv4 address from your router, not a hostname or broadcast address.';

  @override
  String get setupErrorUdp =>
      'Could not open or send on the WiFi video connection. Check your phone\'s network and try again.';

  @override
  String get setupErrorUdpTimeout =>
      'No readable image arrived. Check the IP, the glasses\' power, and that both devices use the same WiFi without client isolation.';

  @override
  String get setupErrorUdpStalled =>
      'Glasses video stopped arriving. The connection is no longer ready; check WiFi and reconnect.';

  @override
  String get setupErrorUnsupported =>
      'This control is not supported over WiFi. It needs an active setup BLE connection.';

  @override
  String get tbDocumentTitle => 'Firmware testbench | SpectruLenPor';

  @override
  String get tbSkipToWorkspace => 'Skip to instrument controls';

  @override
  String get tbInstrumentSubtitle => 'Firmware verification instrument';

  @override
  String get tbLanguage => 'Interface language';

  @override
  String get tbLanguageEnglish => 'English';

  @override
  String get tbLanguageArabic => 'Arabic';

  @override
  String get tbLocalWorkbench => 'Local workbench / hardware verification';

  @override
  String get tbDashboardTitle => 'Firmware testbench';

  @override
  String get tbOperationInProgress => 'Operation in progress';

  @override
  String get tbBackendConnected => 'Local controller online';

  @override
  String get tbBackendUnavailable => 'Local controller unavailable';

  @override
  String get tbBackendUnavailableHint =>
      'Check that the testbench server is running. The dashboard will reconnect automatically; hardware commands will not be retried.';

  @override
  String get tbDismiss => 'Dismiss message';

  @override
  String get tbGuidedWorkflow => 'Commissioning sequence';

  @override
  String get tbStepConnect => 'Connect';

  @override
  String get tbStepConnectHint => 'Discover and authorize the BLE fixture.';

  @override
  String get tbStepProvision => 'Provision';

  @override
  String get tbStepProvisionHint => 'Save the WiFi configuration once.';

  @override
  String get tbStepReboot => 'Reboot';

  @override
  String get tbStepRebootHint => 'Wait for a fresh WiFi-only boot.';

  @override
  String get tbStepAttach => 'Attach';

  @override
  String get tbStepAttachHint => 'Enter the device IP for the UDP session.';

  @override
  String get tbStepVerify => 'Verify';

  @override
  String get tbStepVerifyHint => 'Inspect frames and record test evidence.';

  @override
  String get tbLocalOnly => 'Local by design';

  @override
  String get tbLocalOnlyHint =>
      'Frames and control requests stay on this machine and your local network. No cloud services or telemetry.';

  @override
  String get tbCameraChannel => '01 / camera channel';

  @override
  String get tbPreviewTitle => 'Frame monitor';

  @override
  String get tbFrameAlt =>
      'Latest camera frame received from the firmware fixture';

  @override
  String get tbWaitingForFrame => 'Awaiting camera signal';

  @override
  String get tbWaitingForFrameHint =>
      'Connect or attach the fixture, then start streaming or request a single frame.';

  @override
  String get tbFrameSequence => 'Frame';

  @override
  String get tbTransport => 'Transport';

  @override
  String get tbSingleFrame => 'Single frame';

  @override
  String get tbStartStream => 'Start stream';

  @override
  String get tbPauseStream => 'Pause stream';

  @override
  String get tbEnableFlash => 'Light on';

  @override
  String get tbDisableFlash => 'Light off';

  @override
  String get tbFlashCommandHint =>
      'This control reflects the last requested light setting, not measured hardware feedback.';

  @override
  String get tbReceivedFps => 'Received rate';

  @override
  String get tbFpsUnit => 'frames/s';

  @override
  String get tbFramesReceived => 'Frames received';

  @override
  String get tbIncompleteFrames => 'Incomplete frames';

  @override
  String get tbDatagrams => 'Datagrams';

  @override
  String get tbFrameAge => 'Frame age';

  @override
  String get tbSecondsUnit => 's';

  @override
  String get tbFrameBytes => 'Payload';

  @override
  String get tbBytesUnit => 'bytes';

  @override
  String get tbFixtureControls => 'Fixture / controls';

  @override
  String get tbConnectionTitle => 'Connection desk';

  @override
  String get tbBleLink => 'BLE authorization';

  @override
  String get tbAdapterLabel => 'Bluetooth adapter';

  @override
  String get tbAdapterHint =>
      'Uses the server adapter when left blank. Change it before connecting.';

  @override
  String get tbConnect => 'Connect over BLE';

  @override
  String get tbDeviceMac => 'Device MAC';

  @override
  String get tbDeviceHostname => 'Device hostname';

  @override
  String get tbWifiProvisioning => 'WiFi provisioning';

  @override
  String get tbUseNetworkManager => 'Use the active NetworkManager connection';

  @override
  String get tbNetworkManagerHint =>
      'The local controller reads the active network credentials. No password is displayed or stored by this dashboard.';

  @override
  String get tbSsidLabel => 'Network name (SSID)';

  @override
  String get tbPasswordLabel => 'WiFi password';

  @override
  String get tbPasswordHint =>
      'Masked, held in memory only and cleared on submit. Leave blank only for an open network.';

  @override
  String get tbSaveAndReboot => 'Save WiFi and reboot';

  @override
  String get tbSetupHint =>
      'Save once, await the exact acknowledgment, then reboot. A failed setup is never retried automatically.';

  @override
  String get tbRebootOnly => 'Reboot only';

  @override
  String get tbRebootHint =>
      'Separate BLE reboot command. It does not save or erase WiFi credentials.';

  @override
  String get tbUdpAttach => 'UDP session';

  @override
  String get tbIpLabel => 'Device IPv4 address';

  @override
  String get tbIpHint =>
      'Enter the IP from your router or fresh UART output. Firmware does not provide mDNS discovery.';

  @override
  String get tbAttach => 'Attach to device IP';

  @override
  String get tbActiveIp => 'Attached IP';

  @override
  String get tbLocalListener => 'Local listener';

  @override
  String get tbUartLabel => 'Diagnostic UART (server configuration)';

  @override
  String get tbUartHint =>
      'Read-only startup setting. UART output can provide the device IP; it is diagnostic evidence, not network discovery.';

  @override
  String get tbUartAvailable => 'UART diagnostics available';

  @override
  String get tbUartUnavailable => 'UART diagnostics unavailable';

  @override
  String get tbDisconnect => 'Disconnect fixture';

  @override
  String get tbDisconnectHint =>
      'Stops the session without clearing saved network settings.';

  @override
  String get tbVerificationChannel => '02 / verification channel';

  @override
  String get tbTestTitle => 'Test runner';

  @override
  String get tbProfileLabel => 'Test profile';

  @override
  String get tbProfileSmoke => 'Smoke / quick verification';

  @override
  String get tbProfileFull => 'Full / configuration-changing suite';

  @override
  String get tbProfileMobileFlow => 'Mobile flow / commissioning';

  @override
  String get tbProfileMissingAp => 'Missing AP / recovery boundary';

  @override
  String get tbProfileSoak => 'Soak / sustained streaming';

  @override
  String get tbProfileUnknown => 'Unknown profile';

  @override
  String get tbProfileSmokeHint =>
      'Quick fixture checks. Review each recorded result; an unavailable check is not a pass.';

  @override
  String get tbProfileFullHint =>
      'Exercises configuration boundaries before final commissioning. Requires a fresh BLE setup fixture and explicit configuration authorization.';

  @override
  String get tbProfileMobileFlowHint =>
      'Verifies the app-style commissioning sequence: BLE setup, WiFi-only reboot, IP attachment and decoded UDP frames.';

  @override
  String get tbProfileMissingApHint =>
      'Tests boot with an unreachable access point. Saved network settings change and explicit recovery may be required afterward.';

  @override
  String get tbProfileSoakHint =>
      'Monitors sustained frame delivery for the selected duration. Missing frames and incomplete datagrams remain visible in the evidence.';

  @override
  String get tbDurationLabel => 'Duration (seconds)';

  @override
  String get tbRunTests => 'Run tests';

  @override
  String get tbCancelRun => 'Cancel operation';

  @override
  String get tbDestructiveProfileWarning =>
      'Changes saved WiFi configuration. Requires a fresh setup fixture and explicit confirmation; no automatic erase or recovery.';

  @override
  String get tbChecksRecorded => 'checks recorded';

  @override
  String get tbRunProgress => 'Test run progress';

  @override
  String get tbJobId => 'Job ID';

  @override
  String get tbNoTestResults => 'No checks recorded yet';

  @override
  String get tbNoTestResultsHint =>
      'Choose a profile to produce a local evidence report.';

  @override
  String get tbTestResults => 'Recorded firmware test results';

  @override
  String get tbCheckName => 'Check';

  @override
  String get tbOutcome => 'Outcome';

  @override
  String get tbDuration => 'Duration';

  @override
  String get tbDetails => 'Details / code';

  @override
  String get tbEvidenceChannel => '03 / evidence channel';

  @override
  String get tbReportTitle => 'Session evidence';

  @override
  String get tbDownloadReport => 'Download report';

  @override
  String get tbReportHint =>
      'Current server report, including recorded checks and diagnostic evidence.';

  @override
  String get tbViewReport => 'Inspect report';

  @override
  String get tbCloseReport => 'Close report viewer';

  @override
  String get tbCurrentReport => 'Current JSON report';

  @override
  String get tbEventLog => 'Controller event log';

  @override
  String get tbEvents => 'events';

  @override
  String get tbNoEvents => 'No controller events recorded.';

  @override
  String get tbFooterLocal =>
      'Local control. No automatic provisioning retries.';

  @override
  String get tbFooterEvidence =>
      'Observed evidence only. Unverified is not passed.';

  @override
  String get tbCloseConfirmation => 'Close configuration confirmation';

  @override
  String get tbConfigurationChange =>
      'Configuration change / confirmation required';

  @override
  String get tbConfirmTestTitle => 'Authorize this test run';

  @override
  String get tbConfirmTestDescription =>
      'This profile can change saved WiFi settings and leave the fixture in WiFi-only boot. Confirm the fixture is ready and that you can restore its configuration yourself.';

  @override
  String get tbConfirmFreshSetup =>
      'The fixture is in fresh BLE setup mode with no saved WiFi credentials.';

  @override
  String get tbConfirmConfiguration =>
      'I authorize this test to replace or clear saved WiFi configuration.';

  @override
  String get tbNoAutomaticErase =>
      'The dashboard never erases configuration or retries provisioning to recover from a failure. Recovery requires a separate, explicit action.';

  @override
  String get tbGoBack => 'Go back';

  @override
  String get tbConfirmAndRun => 'Authorize and run';

  @override
  String get tbJavaScriptRequired =>
      'Enable JavaScript to use the local testbench controls.';

  @override
  String get tbPhaseDisconnected => 'Disconnected';

  @override
  String get tbPhaseBleSetup => 'BLE setup';

  @override
  String get tbPhasePaired => 'BLE authorized';

  @override
  String get tbPhaseProvisioned => 'WiFi saved';

  @override
  String get tbPhaseRebooting => 'Rebooting';

  @override
  String get tbPhaseWifiReady => 'WiFi ready';

  @override
  String get tbPhaseStreaming => 'Streaming';

  @override
  String get tbPhasePaused => 'Paused';

  @override
  String get tbPhaseError => 'Controller error';

  @override
  String get tbPhaseUnknown => 'Awaiting state';

  @override
  String get tbGuideDisconnected =>
      'Connect a fresh BLE fixture, or attach a device already running in WiFi mode using its IP.';

  @override
  String get tbGuideBleSetup =>
      'Select the network, then save and reboot. Setup authorizes the BLE link before sending credentials.';

  @override
  String get tbGuidePaired =>
      'Select the active local network or enter its credentials, then save and reboot once.';

  @override
  String get tbGuideProvisioned =>
      'Credentials were saved. Await the setup reboot, or use the separate reboot control if required.';

  @override
  String get tbGuideRebooting =>
      'Wait for fresh boot evidence. Do not resend credentials while the device restarts.';

  @override
  String get tbGuideWifiReady =>
      'Enter the device IP from your router or UART, then attach the UDP session if not already attached.';

  @override
  String get tbGuideStreaming =>
      'Inspect the live frames and run the appropriate verification profile.';

  @override
  String get tbGuidePaused =>
      'The session is paused. Resume streaming or request a single frame.';

  @override
  String get tbGuideError =>
      'Review the controller error and evidence before taking a separate recovery action.';

  @override
  String get tbGuideUnknown =>
      'Waiting for the local controller to report the fixture state.';

  @override
  String get tbPreviewEmpty => 'No signal';

  @override
  String get tbPreviewLive => 'Live';

  @override
  String get tbPreviewStale => 'Stale frame';

  @override
  String get tbPreviewPaused => 'Paused';

  @override
  String get tbPreviewReady => 'Last frame';

  @override
  String get tbFrameStaleHint =>
      'This is an older frame, not proof of a live stream.';

  @override
  String get tbFramePausedHint =>
      'Streaming is paused. The last received frame is retained.';

  @override
  String get tbNoTransport => 'None';

  @override
  String get tbUnknownValue => 'Unavailable';

  @override
  String get tbStatusIdle => 'Idle';

  @override
  String get tbStatusQueued => 'Queued';

  @override
  String get tbStatusRunning => 'Running';

  @override
  String get tbStatusStarted => 'Started';

  @override
  String get tbStatusPassed => 'Passed';

  @override
  String get tbStatusSuccess => 'Succeeded';

  @override
  String get tbStatusCompleted => 'Completed';

  @override
  String get tbStatusFailed => 'Failed';

  @override
  String get tbStatusRejected => 'Rejected';

  @override
  String get tbStatusCancelled => 'Cancelled';

  @override
  String get tbStatusCancelling => 'Cancelling';

  @override
  String get tbStatusSkipped => 'Skipped';

  @override
  String get tbStatusUnverified => 'Unverified';

  @override
  String get tbStatusWarning => 'Warning';

  @override
  String get tbStatusReady => 'Ready';

  @override
  String get tbStatusUnknown => 'Unknown status';

  @override
  String get tbStreamOperation => 'Stream control';

  @override
  String get tbFlashOperation => 'Light control';

  @override
  String get tbActionQueued =>
      'Command accepted by the local controller. Await its recorded outcome.';

  @override
  String get tbCancellationRequested =>
      'Cancellation requested. Wait for the controller to finish cleanup.';

  @override
  String get tbActionRejected =>
      'The controller rejected this operation. Review the error code.';

  @override
  String get tbRequestFailed =>
      'The local request failed. Review the error code before trying again.';

  @override
  String get tbInvalidResponse =>
      'The controller returned an invalid response.';

  @override
  String get tbConfigurationUnavailable =>
      'Controller configuration is unavailable. Commands are disabled until it can be loaded.';

  @override
  String get tbLocalizationUnavailable =>
      'Could not load the selected language from the local controller.';

  @override
  String get tbNoProfiles =>
      'No supported test profiles are available from this controller.';

  @override
  String get tbInvalidIp =>
      'Enter a valid device IPv4 address, with four numbers from 0 to 255.';

  @override
  String get tbInvalidSsid =>
      'Enter a network name between 1 and 32 UTF-8 bytes.';

  @override
  String get tbInvalidDuration => 'Enter a positive whole number of seconds.';

  @override
  String get tbTestFailed =>
      'The test run failed. Review its recorded checks and error code.';

  @override
  String get tbReportUnavailable =>
      'No report is available from the local controller.';

  @override
  String get tbReportLoading => 'Loading report';

  @override
  String get tbRedacted => '[redacted]';

  @override
  String get tbErrorBusy =>
      'The fixture is busy. Wait for the current operation or request cancellation.';

  @override
  String get tbErrorCancelled =>
      'The operation was cancelled. Review the evidence before starting again.';

  @override
  String get tbErrorInvalidRequest =>
      'The request is not valid for this controller. Review the error code.';

  @override
  String get tbErrorInvalidWifi =>
      'The WiFi credentials are invalid or unavailable. Check the network settings and submit explicitly.';

  @override
  String get tbErrorSecurity =>
      'The controller rejected the request security check. Reload the dashboard before trying again.';

  @override
  String get tbErrorNotConnected =>
      'Connect the fixture or attach its IP before sending this command.';

  @override
  String get tbErrorSetupRequired =>
      'The fixture is not in the required setup phase. Follow the commissioning sequence.';

  @override
  String get tbErrorConfirmationRequired =>
      'This test requires explicit authorization to change the saved configuration.';

  @override
  String get tbErrorRecoveryRequired =>
      'Configuration recovery is required. Review the evidence and restore the fixture explicitly; no automatic erase or resend.';

  @override
  String get tbErrorUartRequired =>
      'This check requires diagnostic UART. Configure it when starting the local controller.';

  @override
  String get tbErrorDependency =>
      'A required local component is unavailable. Review the controller setup and error code.';

  @override
  String get tbErrorPlatform =>
      'This operation is not supported on the current platform.';

  @override
  String get tbErrorHardwareLocked =>
      'Another process owns the fixture. Stop that session before connecting here.';

  @override
  String get tbErrorFrameTimeout =>
      'No complete camera frame arrived before the timeout. Review the connection and evidence.';

  @override
  String get tbErrorHardware =>
      'A hardware operation failed. Review the recorded evidence and error code.';

  @override
  String get tbErrorInternal =>
      'The local controller could not finish this operation. Review the error code.';

  @override
  String get aboutBody =>
      'SpectruLenPor v5.5 — Local YOLO26-Nano ONNX object detection (bundled + auto-download) + Cloud-only policy toggle (keeping YOLO local) + Moondream3 Cloud VLM + OpenRouter nemotron→gemma→inkling reasoning chain + streamed fish-audio/s2.1-pro-free:free TTS + 3-mode scientific RAG (Strict / Detailed / Semantic across 119 Periodic Table elements, 110 chemical compounds/materials, GHS lab safety, PubChem, Wikipedia & Web Search) + Google-Search-style inline [n] citations + candidate lexical source-match hints (not proof of correctness) + auto-updating structured ConversationContext + 9-table SQLite WAL Internal Database (saved chats, TTL response cache, logs, hangs/crashes, traces & telemetry).\n\nPipeline: phone camera / ESP32-CAM → local YOLO26-Nano interactive boxes → tap box to lock target marker → press Capture & Analyze for dual JPEG capture (clean + marked) → Moondream3 analyzeSelected → grounded LLM context + candidate source matching → persistent chat session with auto-updating context.\n\nMalak Adel Sayed Hassan (project author) · Abdou (عبد الرحمن أيمن محمد) (software developer and original code author) · Grade 1 secondary, Class 3/1 · Ashmounin Secondary School · Budget: 2,500–6,000 EGP.';
}
