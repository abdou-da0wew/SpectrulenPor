// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Arabic (`ar`).
class AppLocalizationsAr extends AppLocalizations {
  AppLocalizationsAr([String locale = 'ar']) : super(locale);

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
      'وجّه الكاميرا نحو المادة ثم اضغط \"حلّل الآن\" للحصول على تحليل كامل قائم على الطيف.';

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
      'سبكترو لِن بور · ملك عادل سيد حسن · الصف الأول الثانوي ٣/١ · مدرسة الأشمونين الثانوية';

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
  String get openRouterLlmKeyLabel => 'مفتاح OpenRouter للنص';

  @override
  String get openRouterLlmKeyHint => 'يشغّل سلسلة gemma ثم inkling ثم nemotron';

  @override
  String get openRouterTtsKeyLabel => 'مفتاح OpenRouter للصوت';

  @override
  String get openRouterTtsKeyHint => 'يشغّل التعليق الصوتي المتدفق fish-audio';

  @override
  String get diagnosticsHeader => 'التشخيص';

  @override
  String get diagnosticsCloud => 'سحابة موندريم';

  @override
  String get diagnosticsLastModel => 'آخر نموذج';

  @override
  String get diagnosticsReasoningTokens => 'رموز التفكير';

  @override
  String get diagnosticsTts => 'محرّك الصوت';

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
  String latencyFirstToken(int ms) {
    return '⏱ أول رمز صوتي: $ms مللي ثانية';
  }

  @override
  String get aboutBody =>
      'سبكترو لِن بور v3.0 — رؤية موندريم ٣ السحابية + بديل موندريم محلي + سلسلة OpenRouter gemma←inkling←nemotron الاستدلالية + بث صوت fish-audio.\n\nالخط: المستشعرات + الكاميرا ← ESP32-CAM ← بلوتوث ← الهاتف ← تحليل موندريم ٣ السحابي ← عرض OpenRouter ← سرد صوتي ثنائي اللغة.\n\nملك عادل سيد حسن · الصف الأول الثانوي ٣/١ · مدرسة الأشمونين الثانوية · الميزانية: ٢٬٥٠٠–٦٬٠٠٠ جنيه.';
}
