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
  String get modelInkling => 'liquid/inkling-small:free — بديل ١';

  @override
  String get modelNemotron => 'nvidia/nemotron-3-nano-30b-a3b:free — بديل ٢';

  @override
  String get reasoningTokensLabel => 'التقاط رموز الاستدلال';

  @override
  String get reasoningTokensHint =>
      'تُعِد رموز الاستدلال عبر chunk.usage.completionTokensDetails.reasoningTokens';

  @override
  String latencyFirstToken(int ms) {
    return 'أول رمز صوتي: $ms مللي ثانية';
  }

  @override
  String get live => 'مباشر';

  @override
  String get scanningGlasses => 'جارٍ مسح النظارة…';

  @override
  String get negotiatingStream => 'جارٍ التفاوض على البث…';

  @override
  String get waitingFirstFrame => 'بانتظار الإطار الأول…';

  @override
  String get btPermissionsRequired => 'أذونات البلوتوث مطلوبة';

  @override
  String get turnOnBluetooth => 'شغل البلوتوث';

  @override
  String get btConnectionError => 'خطأ في اتصال البلوتوث';

  @override
  String get aboutBody =>
      'سبكترو لِن بور v5.5 — رصد الكائنات المحلي عبر YOLO26-Nano ONNX (مرفق بالتطبيق مع تنزيل/تحقق تلقائي) + خيار النماذج السحابية فقط (مع بقاء YOLO محلياً) + رؤية موندريم ٣ السحابية + سلسلة OpenRouter الاستدلالية (gemma←inkling←nemotron) + بث صوت fish-audio/s2.1-pro-free:free + بحث علمي بثلاثة أوضاع (صارم / مفصل / دلالي عبر 119 عنصراً كيميائياً و110 مركبات ومعايير السلامة GHS وPubChem وويكيبيديا والويب) + استشهادات مرقمة [n] وتدقيق الحقائق + سياق علمي مهيكل ذاتي التحديث + قاعدة بيانات داخلية SQLite WAL من 9 جداول لحفظ المحادثات والكاش والسجلات والأعطال والقياسات.\n\nالخط التشغيلي: كاميرا الهاتف أو نظارة ESP32-CAM ← صناديق YOLO26-Nano التفاعلية ← لمس الصندوق لوضع علامة الهدف ← الضغط على التقاط وتحليل لأخذ صورتين (نظيفة + معلمة) ← تحليل موندريم ٣ ← سياق علمي موثق وتدقيق الحقائق ← محادثة مستمرة محفوظة تلقائياً.\n\nملك عادل سيد حسن (طالبة) · عبد الرحمن أيمن محمد (مطور) · الصف الأول الثانوي ٣/١ · مدرسة الأشمونين الثانوية · الميزانية: ٢٬٥٠٠–٦٬٠٠٠ جنيه.';
}
