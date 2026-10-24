import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_glass_app/l10n/app_localizations.dart';
import 'package:smart_glass_app/l10n/app_localizations_ar.dart';
import 'package:smart_glass_app/l10n/app_localizations_en.dart';

AppLocalizations get _en => AppLocalizationsEn();
AppLocalizations get _ar => AppLocalizationsAr();

void main() {
  test('EN and AR both resolve', () {
    expect(_en.appName, 'SpectruLenPor');
    expect(_ar.appName, 'سبكترو لِن بور');
  });

  test('every key is non-empty in BOTH locales', () async {
    final en = _en;
    final ar = _ar;

    final getters = <String, String Function(AppLocalizations)>{
      'appTagline': (l) => l.appTagline,
      'glassesNotConnected': (l) => l.glassesNotConnected,
      'scanning': (l) => l.scanning,
      'connecting': (l) => l.connecting,
      'connected': (l) => l.connected,
      'btError': (l) => l.btError,
      'connectGlasses': (l) => l.connectGlasses,
      'disconnect': (l) => l.disconnect,
      'waitingFrame': (l) => l.waitingFrame,
      'phoneCamera': (l) => l.phoneCamera,
      'glassesCam': (l) => l.glassesCam,
      'localVision': (l) => l.localVision,
      'idleLabel': (l) => l.idleLabel,
      'deepReasoning': (l) => l.deepReasoning,
      'deepHint': (l) => l.deepHint,
      'describeNow': (l) => l.describeNow,
      'analyzing': (l) => l.analyzing,
      'soundOn': (l) => l.soundOn,
      'muted': (l) => l.muted,
      'settings': (l) => l.settings,
      'spectrum': (l) => l.spectrum,
      'uvChannel': (l) => l.uvChannel,
      'irChannel': (l) => l.irChannel,
      'noSensorData': (l) => l.noSensorData,
      'stateMatter': (l) => l.stateMatter,
      'stateUnknown': (l) => l.stateUnknown,
      'stateSolid': (l) => l.stateSolid,
      'stateLiquid': (l) => l.stateLiquid,
      'stateGas': (l) => l.stateGas,
      'hazardClear': (l) => l.hazardClear,
      'hazardDetected': (l) => l.hazardDetected,
      'hazardSpeech': (l) => l.hazardSpeech,
      'flashlight': (l) => l.flashlight,
      'waitingSensors': (l) => l.waitingSensors,
      'credits': (l) => l.credits,
      'visionSourceMoondream': (l) => l.visionSourceMoondream,
      'visionSourceLocalMoondream': (l) => l.visionSourceLocalMoondream,
      'visionSourceOnnx': (l) => l.visionSourceOnnx,
      'visionSourceMlkit': (l) => l.visionSourceMlkit,
      'visionSourceIdle': (l) => l.visionSourceIdle,
      'visionSourceError': (l) => l.visionSourceError,
      'moondreamApiKeyLabel': (l) => l.moondreamApiKeyLabel,
      'moondreamApiKeyHint': (l) => l.moondreamApiKeyHint,
      'moondreamCloudEnabled': (l) => l.moondreamCloudEnabled,
      'moondreamCloudDisabled': (l) => l.moondreamCloudDisabled,
      'openRouterLlmKeyLabel': (l) => l.openRouterLlmKeyLabel,
      'openRouterLlmKeyHint': (l) => l.openRouterLlmKeyHint,
      'openRouterTtsKeyLabel': (l) => l.openRouterTtsKeyLabel,
      'openRouterTtsKeyHint': (l) => l.openRouterTtsKeyHint,
      'diagnosticsHeader': (l) => l.diagnosticsHeader,
      'diagnosticsCloud': (l) => l.diagnosticsCloud,
      'diagnosticsLastModel': (l) => l.diagnosticsLastModel,
      'diagnosticsReasoningTokens': (l) => l.diagnosticsReasoningTokens,
      'diagnosticsTts': (l) => l.diagnosticsTts,
      'fishAudioTts': (l) => l.fishAudioTts,
      'fishAudioTtsSubtitle': (l) => l.fishAudioTtsSubtitle,
      'ttsNative': (l) => l.ttsNative,
      'ttsNativeSubtitle': (l) => l.ttsNativeSubtitle,
      'testVoice': (l) => l.testVoice,
      'visionPriorityHeader': (l) => l.visionPriorityHeader,
      'upstreamFallbackHeader': (l) => l.upstreamFallbackHeader,
      'modelGemma26': (l) => l.modelGemma26,
      'modelInkling': (l) => l.modelInkling,
      'modelNemotron': (l) => l.modelNemotron,
      'reasoningTokensLabel': (l) => l.reasoningTokensLabel,
      'reasoningTokensHint': (l) => l.reasoningTokensHint,
      'aboutBody': (l) => l.aboutBody,
    };

    for (final entry in getters.entries) {
      final enValue = entry.value(en);
      final arValue = entry.value(ar);
      expect(enValue.trim(), isNotEmpty, reason: 'en.${entry.key} is empty');
      expect(arValue.trim(), isNotEmpty, reason: 'ar.${entry.key} is empty');
    }
  });

  test('Arabic translations actually differ from English', () async {
    final en = _en;
    final ar = _ar;
    expect(ar.settings, isNot(en.settings));
    expect(ar.deepReasoning, isNot(en.deepReasoning));
    expect(ar.hazardSpeech, contains('تحذير'));
  });

  test('parameterized latencyFirstToken formats the ms value', () async {
    final en = _en;
    final ar = _ar;
    expect(en.latencyFirstToken(1234), contains('1234'));
    expect(ar.latencyFirstToken(1234), contains('1234'));
  });

  test('delegate + supported locales wired', () async {
    expect(AppLocalizations.supportedLocales.map((l) => l.languageCode),
        containsAll(['en', 'ar']));
    expect(AppLocalizations.localizationsDelegates, isNotEmpty);
    expect(AppLocalizations.delegate.isSupported(const Locale('ar')), isTrue);
    expect(AppLocalizations.delegate.isSupported(const Locale('de')), isFalse);
  });
}
