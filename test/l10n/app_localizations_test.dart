import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_glass_app/l10n/app_localizations.dart';
import 'package:smart_glass_app/l10n/app_localizations_ar.dart';
import 'package:smart_glass_app/l10n/app_localizations_en.dart';
import 'package:smart_glass_app/l10n/glasses_messages.dart';
import 'package:smart_glass_app/models/glasses_setup.dart';
import 'package:smart_glass_app/services/openrouter_service.dart';

AppLocalizations get _en => AppLocalizationsEn();
AppLocalizations get _ar => AppLocalizationsAr();

void main() {
  test('EN and AR both resolve', () {
    expect(_en.appName, 'SpectruLenPor');
    expect(_ar.appName, 'سبكترو لِن بور');
  });

  test('localized model labels follow the configured OpenRouter chain', () {
    expect(_en.modelNemotron, startsWith(OpenRouterService.modelChain[0]));
    expect(_en.modelGemma26, startsWith(OpenRouterService.modelChain[1]));
    expect(_en.modelInkling, startsWith(OpenRouterService.modelChain[2]));
    expect(_ar.modelNemotron, startsWith(OpenRouterService.modelChain[0]));
    expect(_ar.modelGemma26, startsWith(OpenRouterService.modelChain[1]));
    expect(_ar.modelInkling, startsWith(OpenRouterService.modelChain[2]));
    expect(_en.modelNemotron, contains('Nemotron 3.5 Super VL'));
    expect(_ar.modelNemotron, contains('Nemotron 3.5 Super VL'));
    expect(_en.modelGemma26, contains('Gemma 4 26B A4B'));
    expect(_ar.modelGemma26, contains('Gemma 4 26B A4B'));
    expect(_en.modelInkling, contains('Inkling 2 Small'));
    expect(_ar.modelInkling, contains('Inkling 2 Small'));
    expect(_en.factCheckSourceMatchSummary(2, 1), contains('2'));
    expect(_ar.factCheckSourceMatchSummary(2, 1), contains('1'));
    expect(_ar.factCheckMethodHint, isNot(_en.factCheckMethodHint));
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
      'factCheckHeader': (l) => l.factCheckHeader,
      'factCheckMethodHint': (l) => l.factCheckMethodHint,
      'factCheckSourceMatchSummary': (l) => l.factCheckSourceMatchSummary(2, 1),
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

  test('ARB keys have bilingual parity and every setup translation is real',
      () {
    final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
        as Map<String, dynamic>;
    final ar = jsonDecode(File('lib/l10n/app_ar.arb').readAsStringSync())
        as Map<String, dynamic>;
    final enKeys = en.keys.where((key) => !key.startsWith('@')).toSet();
    final arKeys = ar.keys.where((key) => !key.startsWith('@')).toSet();
    expect(arKeys, enKeys);
    for (final key in enKeys) {
      expect(en[key], isA<String>());
      expect(ar[key], isA<String>());
      expect((en[key] as String).trim(), isNotEmpty, reason: 'en.$key');
      expect((ar[key] as String).trim(), isNotEmpty, reason: 'ar.$key');
      if (key.startsWith('setup') ||
          key.startsWith('wifi') ||
          key.startsWith('tb') ||
          const {
            'glassesIpLabel',
            'startUdpVideo',
            'stopVideo',
            'refreshStatus',
            'restartEsp',
            'alreadyConnected',
            'shutdownGlasses',
            'pauseVideo',
            'resumeVideo',
            'requestOneFrame',
            'videoPaused',
          }.contains(key)) {
        expect(ar[key], isNot(en[key]), reason: 'untranslated $key');
      }
    }
  });

  test('all setup stages and failures resolve to localized safe messages', () {
    for (final stage in GlassesSetupStage.values) {
      expect(_en.setupProgress(stage).trim(), isNotEmpty);
      expect(_ar.setupProgress(stage).trim(), isNotEmpty);
      expect(_ar.setupProgress(stage), isNot(_en.setupProgress(stage)));
    }
    for (final failure in GlassesFailure.values) {
      expect(_en.setupFailure(failure).trim(), isNotEmpty);
      expect(_ar.setupFailure(failure).trim(), isNotEmpty);
      expect(_ar.setupFailure(failure), isNot(_en.setupFailure(failure)));
      expect(_en.setupFailure(failure), isNot(contains('GlassesException')));
    }
    expect(
        _en.setupProgress(GlassesSetupStage.awaitingIp), _en.setupAwaitingIp);
    expect(_ar.setupProgress(GlassesSetupStage.waitingForFrame),
        _ar.setupWaitingFrame);
    expect(
        _en.setupFailure(GlassesFailure.udpStalled), _en.setupErrorUdpStalled);
    expect(_ar.setupFailure(GlassesFailure.unsupportedControl),
        _ar.setupErrorUnsupported);
  });

  test('identity, network and endpoint interpolation preserve exact values',
      () {
    const hostname = 'spectrulenpor-esp32';
    const mac = '02:12:34:56:78:90';
    const ip = '192.0.2.10';
    for (final l in [_en, _ar]) {
      expect(l.setupIdentity(hostname, mac),
          allOf(contains(hostname), contains(mac)));
      expect(l.setupNetwork('Lab'), contains('Lab'));
      expect(l.setupEndpoint(ip), contains(ip));
    }
  });
}
