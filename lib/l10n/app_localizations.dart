// This file is a hand-written bootstrap of what `flutter gen-l10n` produces
// from lib/l10n/app_*.arb. When `flutter pub get` runs (with `generate: true`
// in pubspec.yaml), the generator will overwrite this file with an equivalent
// generated implementation. Both produce the same public API:
//
//   final l = AppLocalizations.of(context);
//   print(l.appName);
//   final lAr = await AppLocalizations.load(const Locale('ar'));
//   print(lAr.hazardSpeech);
//
// We ship it manually so the project compiles before the first `flutter pub get`.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// AppLocalizations — bilingual (en / ar) string table for SpectruLenPor.
abstract class AppLocalizations {
  AppLocalizations(String locale) : _localeName = locale;

  final String _localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];

  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ar'),
  ];

  /// Load resources for the given locale asynchronously (for non-context use).
  static Future<AppLocalizations> load(Locale locale) {
    final AppLocalizations l =
        locale.languageCode == 'ar' ? AppLocalizationsAr() : AppLocalizationsEn();
    return SynchronousFuture<AppLocalizations>(l);
  }

  // ----------------------------- keys -----------------------------
  String get appName;
  String get appTagline;
  String get glassesNotConnected;
  String get scanning;
  String get connecting;
  String get connected;
  String get btError;
  String get connectGlasses;
  String get disconnect;
  String get waitingFrame;
  String get phoneCamera;
  String get glassesCam;
  String get localVision;
  String get idleLabel;
  String get deepReasoning;
  String get deepHint;
  String get describeNow;
  String get analyzing;
  String get soundOn;
  String get muted;
  String get settings;
  String get spectrum;
  String get uvChannel;
  String get irChannel;
  String get noSensorData;
  String get stateMatter;
  String get stateUnknown;
  String get stateSolid;
  String get stateLiquid;
  String get stateGas;
  String get hazardClear;
  String get hazardDetected;
  String get hazardSpeech;
  String get flashlight;
  String get waitingSensors;
  String get credits;
  String get visionSourceMoondream;
  String get visionSourceLocalMoondream;
  String get visionSourceOnnx;
  String get visionSourceMlkit;
  String get visionSourceIdle;
  String get visionSourceError;
  String get moondreamApiKeyLabel;
  String get moondreamApiKeyHint;
  String get moondreamCloudEnabled;
  String get moondreamCloudDisabled;
  String get openRouterApiKeyLabel;
  String get openRouterApiKeyHint;
  String get fishAudioTts;
  String get fishAudioTtsSubtitle;
  String get ttsNative;
  String get ttsNativeSubtitle;
  String get testVoice;
  String get visionPriorityHeader;
  String get upstreamFallbackHeader;
  String get modelGemma26;
  String get modelInkling;
  String get modelNemotron;
  String get reasoningTokensLabel;
  String get reasoningTokensHint;
  String latencyFirstToken(int ms);
  String get aboutBody;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) => AppLocalizations.load(locale);

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ar'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn() : super('en');

  @override
  String get appName => 'SpectruLenPor';

  @override
  String get appTagline =>
      'Smart glasses for spectrum analysis and detection of chemical '
      'elements and compounds';

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
      'Point at a substance, then tap "Analyze now" for full spectrum-based '
      'analysis.';
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
      'No sensor telemetry yet — UV/IR readings appear when the glasses '
      'stream them.';
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
      'SpectruLenPor · Malak Adel Sayed Hassan · Grade 1 secondary, Class '
      '3/1 · Ashmounin Secondary School';
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
  String latencyFirstToken(int ms) => '⏱ first audio token: $ms ms';
  @override
  String get aboutBody =>
      'SpectruLenPor v3.0 — Moondream3 cloud vision + local Moondream fallback '
      '+ OpenRouter gemma→inkling→nemotron reasoning chain + streamed '
      'fish-audio TTS.\n\n'
      'Pipeline: sensors + camera → ESP32-CAM → Bluetooth → phone → '
      'Moondream3 cloud analysis → OpenRouter presentation → bilingual voice '
      'narration.\n\n'
      'Malak Adel Sayed Hassan · Grade 1 secondary, Class 3/1 · Ashmounin '
      'Secondary School · Budget: 2,500–6,000 EGP.';
}

class AppLocalizationsAr extends AppLocalizations {
  AppLocalizationsAr() : super('ar');

  @override
  String get appName => 'سبكترو لِن بور';

  @override
  String get appTagline =>
      'النظارة الذكية لتحليل الطيف واكتشاف العناصر والمركبات الكيميائية';

  @override
  String get glassesNotConnected => 'النظارة غير متصلة';
  @override
  String get scanning => 'جارٍ البحث عن النظارة…';
  @override
  String get connecting => 'جارٍ الاتصال…';
  @override
  String get connected => 'متصل';
  @override
  String get btError => 'خطأ في البلوتوث';
  @override
  String get connectGlasses => 'توصيل النظارة';
  @override
  String get disconnect => 'قطع الاتصال';
  @override
  String get waitingFrame =>
      'بانتظار إطار صورة… (استخدم كاميرا الهاتف للتجربة بدون النظارة)';
  @override
  String get phoneCamera => 'كاميرا الهاتف';
  @override
  String get glassesCam => 'النظارة';
  @override
  String get localVision => 'الرؤية المحلية — فورية';
  @override
  String get idleLabel => 'خامل — بانتظار الإطار التالي.';
  @override
  String get deepReasoning => 'تحليل الذكاء الاصطناعي';
  @override
  String get deepHint =>
      'وجّه الكاميرا نحو المادة ثم اضغط "حلّل الآن" للحصول على تحليل كامل '
      'قائم على الطيف.';
  @override
  String get describeNow => 'حلّل الآن';
  @override
  String get analyzing => 'جارٍ التحليل…';
  @override
  String get soundOn => 'الصوت مفتوح';
  @override
  String get muted => 'صامت';
  @override
  String get settings => 'الإعدادات';
  @override
  String get spectrum => 'قنوات الطيف';
  @override
  String get uvChannel => 'فوق بنفسجي';
  @override
  String get irChannel => 'تحت أحمر';
  @override
  String get noSensorData =>
      'لا توجد بيانات مستشعرات بعد — تظهر قراءات UV/IR عند إرسالها من النظارة.';
  @override
  String get stateMatter => 'حالة المادة';
  @override
  String get stateUnknown => 'غير معروفة';
  @override
  String get stateSolid => 'صلب';
  @override
  String get stateLiquid => 'سائل';
  @override
  String get stateGas => 'غاز';
  @override
  String get hazardClear => 'لا توجد مخاطر';
  @override
  String get hazardDetected => 'تم اكتشاف خطر!';
  @override
  String get hazardSpeech => 'تحذير! تم اكتشاف مادة خطرة. تراجع بحذر.';
  @override
  String get flashlight => 'مصباح النظارة';
  @override
  String get waitingSensors => 'بانتظار بيانات المستشعرات…';
  @override
  String get credits =>
      'سبكترو لِن بور · ملك عادل سيد حسن · الصف الأول الثانوي ٣/١ · '
      'مدرسة الأشمونين الثانوية';
  @override
  String get visionSourceMoondream => 'موندريم ٣ سحابي';
  @override
  String get visionSourceLocalMoondream => 'موندريم محلي';
  @override
  String get visionSourceOnnx => 'نموذج ONNX';
  @override
  String get visionSourceMlkit => 'إم إل كِت';
  @override
  String get visionSourceIdle => 'خامل';
  @override
  String get visionSourceError => 'خطأ في الرؤية';
  @override
  String get moondreamApiKeyLabel => 'مفتاح Mondream API';
  @override
  String get moondreamApiKeyHint => 'احصل عليه من docs.moondream.ai → السحابة';
  @override
  String get moondreamCloudEnabled =>
      'الرؤية السحابية مُفعّلة (moondream3.1-9B-A2B)';
  @override
  String get moondreamCloudDisabled =>
      'لا يوجد مفتاح Mondream — استخدام البديل المحلي أو ML Kit';
  @override
  String get openRouterApiKeyLabel => 'مفتاح OpenRouter API';
  @override
  String get openRouterApiKeyHint => 'مفتاح مجاني: openrouter.ai/keys';
  @override
  String get fishAudioTts => 'بث صوت fish-audio';
  @override
  String get fishAudioTtsSubtitle =>
      'سرد عالي الجودة بث مباشر (OpenRouter /audio/speech)';
  @override
  String get ttsNative => 'نطق أندرويد الأصلي (دون اتصال)';
  @override
  String get ttsNativeSubtitle => 'أقل زمن وصول، دون شبكة';
  @override
  String get testVoice => 'اختبر الصوت';
  @override
  String get visionPriorityHeader => 'أولوية مصدر الرؤية';
  @override
  String get upstreamFallbackHeader =>
      'سلسلة OpenRouter النصية + الاستدلال البديلة';
  @override
  String get modelGemma26 => 'google/gemma-4-26b-a4b-it:free — رئيسي';
  @override
  String get modelInkling => 'thinkingmachines/inkling-small:free — بديل ١';
  @override
  String get modelNemotron =>
      'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free — بديل ٢';
  @override
  String get reasoningTokensLabel => 'التقاط رموز الاستدلال';
  @override
  String get reasoningTokensHint =>
      'تُعِد رموز الاستدلال عبر chunk.usage.completionTokensDetails.reasoningTokens';
  @override
  String latencyFirstToken(int ms) => '⏱ أول رمز صوتي: $ms مللي ثانية';
  @override
  String get aboutBody =>
      'سبكترو لِن بور v3.0 — رؤية موندريم ٣ السحابية + بديل موندريم محلي + '
      'سلسلة OpenRouter gemma←inkling←nemotron الاستدلالية + بث صوت fish-audio.\n\n'
      'الخط: المستشعرات + الكاميرا ← ESP32-CAM ← بلوتوث ← الهاتف ← تحليل '
      'موندريم ٣ السحابي ← عرض OpenRouter ← سرد صوتي ثنائي اللغة.\n\n'
      'ملك عادل سيد حسن · الصف الأول الثانوي ٣/١ · مدرسة الأشمونين الثانوية · '
      'الميزانية: ٢٬٥٠٠–٦٬٠٠٠ جنيه.';
}
