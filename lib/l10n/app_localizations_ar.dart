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
  String get factCheckHeader => 'تطابقات المصادر المحتملة';

  @override
  String get factCheckMethodHint =>
      'تداخل الكلمات يشير فقط إلى مصدر قد يكون ذا صلة؛ ولا يثبت صحة الادعاء أو صحته العلمية.';

  @override
  String factCheckSourceMatchSummary(int matched, int unmatched) {
    return '$matched تطابقات مصدر محتملة · $unmatched ادعاءات بلا تطابق';
  }

  @override
  String get modelGemma26 =>
      'google/gemma-4-26b-a4b-it:free — Gemma 4 26B A4B (بديل ١)';

  @override
  String get modelInkling =>
      'thinkingmachines/inkling-2-small:free — Inkling 2 Small (بديل ٢)';

  @override
  String get modelNemotron =>
      'nvidia/nemotron-3.5-super-vl:free — Nemotron 3.5 Super VL (رئيسي)';

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
  String get wifiConfigTitle => 'إعداد واي فاي النظارة';

  @override
  String get wifiSsidLabel => 'اسم شبكة واي فاي (SSID)';

  @override
  String get wifiPasswordLabel => 'كلمة المرور (اتركها فارغة للشبكة المفتوحة)';

  @override
  String get wifiSaveConnect => 'حفظ الشبكة وإعادة تشغيل النظارة';

  @override
  String get wifiConfigured => 'تم حفظ إعدادات الشبكة على النظارة';

  @override
  String get wifiConnected => 'تم التحقق من فيديو النظارة عبر واي فاي';

  @override
  String get wifiDisconnected => 'فيديو واي فاي غير متصل';

  @override
  String get glassesIpLabel => 'عنوان IPv4 للنظارة';

  @override
  String get startUdpVideo => 'توصيل فيديو واي فاي';

  @override
  String get stopVideo => 'قطع اتصال الفيديو';

  @override
  String get refreshStatus => 'قراءة حالة البلوتوث';

  @override
  String get restartEsp => 'إعادة تشغيل النظارة';

  @override
  String get alreadyConnected => 'الفيديو متصل';

  @override
  String get shutdownGlasses => 'وضع الاستعداد';

  @override
  String get setupIdle =>
      'وصّل البلوتوث للإعداد، أو أدخل عنوان IP لنظارة سبق إعدادها.';

  @override
  String get setupPairing => 'جارٍ التحقق من رمز إعداد النظارة…';

  @override
  String get setupProvisioning => 'بانتظار تأكيد حفظ الشبكة وهوية الجهاز…';

  @override
  String get setupRebooting => 'بانتظار تأكيد إعادة التشغيل وانقطاع البلوتوث…';

  @override
  String get setupAwaitingIp =>
      'تم حفظ الشبكة. وصّل الهاتف بنفس شبكة واي فاي ثم أدخل عنوان IP للنظارة.';

  @override
  String get setupWaitingFrame =>
      'بانتظار صورة كاملة قابلة للقراءة من النظارة…';

  @override
  String get setupFailed => 'لم نتمكن من تأكيد الإعداد. راجع الرسالة بالأسفل.';

  @override
  String get setupManualIpHint =>
      'أدخل عنوان IP الخاص بـ ESP32، أو اترك الحقل فارغًا لاكتشاف الكاميرا تلقائيًا على شبكة Wi-Fi نفسها.';

  @override
  String get setupRecoveryHint =>
      'قد تكون الشبكة حُفظت بالفعل. لا ترسلها مجدداً تلقائياً. افحص الراوتر أو سجل الجهاز عبر المنفذ التسلسلي قبل المحاولة؛ تغيير الشبكة بعد إعادة التشغيل يحتاج إلى إعادة ضبط وضع الإعداد بشكل صريح.';

  @override
  String get setupCredentialsHint =>
      'اسم الشبكة: من ١ إلى ٣٢ بايت بترميز UTF-8. كلمة المرور: فارغة، أو من ٨ إلى ٦٣ بايت، أو ٦٤ خانة بالنظام الست عشري. استخدم شبكة محلية موثوقة؛ الإعداد والتحكم عبر UDP غير مشفّرين.';

  @override
  String setupIdentity(String hostname, String mac) {
    return 'الجهاز: $hostname · عنوان MAC: $mac';
  }

  @override
  String setupNetwork(String ssid) {
    return 'الشبكة: $ssid';
  }

  @override
  String setupEndpoint(String ip) {
    return 'عنوان IPv4: $ip';
  }

  @override
  String get setupRetryReboot => 'إعادة محاولة التشغيل فقط';

  @override
  String get wifiOnlyControlsUnavailable =>
      'إعادة التشغيل والاستعداد وقراءة الحالة غير متاحة في وضع واي فاي فقط. استخدم زر إعادة الضبط الفعلي لإعادة تشغيل النظارة.';

  @override
  String get pauseVideo => 'إيقاف الفيديو مؤقتاً';

  @override
  String get resumeVideo => 'استئناف الفيديو';

  @override
  String get requestOneFrame => 'طلب صورة واحدة';

  @override
  String get videoPaused => 'الفيديو متوقف مؤقتاً؛ يظل استقبال واي فاي متاحاً.';

  @override
  String get setupErrorBleUnavailable =>
      'تعذّر الاتصال ببلوتوث الإعداد. تحقق من تشغيل البلوتوث والأذونات. النظارة التي سبق إعدادها تعمل بواي فاي فقط.';

  @override
  String get setupErrorBleWrite =>
      'لم تقبل النظارة الأمر. تحقق من اتصال البلوتوث قبل المحاولة مجدداً.';

  @override
  String get setupErrorAckTimeout =>
      'لم يصل تأكيد مطابق من النظارة. قد يكون الأمر وصل إلى الجهاز؛ لا تُكرر حفظ الشبكة تلقائياً.';

  @override
  String get setupErrorCredentials =>
      'راجع طول اسم الشبكة وكلمة المرور. لا يجوز أن يحتوي أي منهما على محرف NUL.';

  @override
  String get setupErrorIdentity =>
      'عنوان MAC أو اسم الجهاز المُرسل غير صالح. لم يتم تأكيد الإعداد.';

  @override
  String get setupErrorPairing =>
      'لم يتم تأكيد الاقتران لاتصال البلوتوث الحالي. أعد الاتصال وتحقق من الإعداد أولاً.';

  @override
  String get setupErrorBusy =>
      'هناك عملية أخرى للنظارة قيد التنفيذ. انتظر حتى تنتهي.';

  @override
  String get setupErrorConnectionLost =>
      'انقطع البلوتوث قبل وصول التأكيد. افحص الجهاز قبل تكرار الإعداد.';

  @override
  String get setupErrorReboot =>
      'تم تأكيد أمر إعادة التشغيل، لكن البلوتوث لم ينقطع في الوقت المحدد. افحص النظارة قبل المحاولة مجدداً.';

  @override
  String get setupErrorIp =>
      'أدخل عنوان IPv4 الصحيح للنظارة من الراوتر، وليس اسم جهاز أو عنوان بث عام.';

  @override
  String get setupErrorUdp =>
      'تعذّر فتح اتصال فيديو واي فاي أو إرسال الأمر. تحقق من شبكة الهاتف ثم حاول مجدداً.';

  @override
  String get setupErrorUdpTimeout =>
      'لم تصل صورة قابلة للقراءة. تحقق من العنوان وتشغيل النظارة واتصال الجهازين بنفس شبكة واي فاي دون عزل الأجهزة.';

  @override
  String get setupErrorUdpStalled =>
      'توقفت صور النظارة عن الوصول. الاتصال لم يعد جاهزاً؛ تحقق من واي فاي ثم أعد الاتصال.';

  @override
  String get setupErrorUnsupported =>
      'هذا التحكم غير مدعوم عبر واي فاي. يحتاج إلى اتصال بلوتوث نشط في وضع الإعداد.';

  @override
  String get tbDocumentTitle => 'منصة اختبار البرنامج الثابت | SpectruLenPor';

  @override
  String get tbSkipToWorkspace => 'انتقل إلى أدوات التحكم';

  @override
  String get tbInstrumentSubtitle => 'أداة التحقق من البرنامج الثابت';

  @override
  String get tbLanguage => 'لغة الواجهة';

  @override
  String get tbLanguageEnglish => 'الإنجليزية';

  @override
  String get tbLanguageArabic => 'العربية';

  @override
  String get tbLocalWorkbench => 'منصة محلية / التحقق من العتاد';

  @override
  String get tbDashboardTitle => 'منصة اختبار البرنامج الثابت';

  @override
  String get tbOperationInProgress => 'عملية قيد التنفيذ';

  @override
  String get tbBackendConnected => 'وحدة التحكم المحلية متصلة';

  @override
  String get tbBackendUnavailable => 'وحدة التحكم المحلية غير متاحة';

  @override
  String get tbBackendUnavailableHint =>
      'تأكد من تشغيل خادم الاختبار. ستعاود اللوحة الاتصال تلقائيًا، لكنها لن تعيد إرسال أوامر العتاد.';

  @override
  String get tbDismiss => 'أغلق الرسالة';

  @override
  String get tbGuidedWorkflow => 'مراحل تجهيز الجهاز';

  @override
  String get tbStepConnect => 'الاتصال';

  @override
  String get tbStepConnectHint => 'اكتشف جهاز الاختبار وصرّح له عبر BLE.';

  @override
  String get tbStepProvision => 'حفظ الشبكة';

  @override
  String get tbStepProvisionHint => 'احفظ إعدادات WiFi مرة واحدة.';

  @override
  String get tbStepReboot => 'إعادة التشغيل';

  @override
  String get tbStepRebootHint => 'انتظر إقلاعًا جديدًا في وضع WiFi فقط.';

  @override
  String get tbStepAttach => 'ربط الجلسة';

  @override
  String get tbStepAttachHint => 'أدخل عنوان الجهاز لربط جلسة UDP.';

  @override
  String get tbStepVerify => 'التحقق';

  @override
  String get tbStepVerifyHint => 'افحص الصور وسجّل أدلة الاختبار.';

  @override
  String get tbLocalOnly => 'محلية بالكامل';

  @override
  String get tbLocalOnlyHint =>
      'تبقى الصور وأوامر التحكم على هذا الحاسوب وشبكتك المحلية. لا خدمات سحابية ولا بيانات تتبع.';

  @override
  String get tbCameraChannel => '٠١ / قناة الكاميرا';

  @override
  String get tbPreviewTitle => 'مراقبة الصور';

  @override
  String get tbFrameAlt => 'آخر صورة استُقبلت من كاميرا جهاز الاختبار';

  @override
  String get tbWaitingForFrame => 'في انتظار إشارة الكاميرا';

  @override
  String get tbWaitingForFrameHint =>
      'اتصل بالجهاز أو اربط جلسته، ثم ابدأ البث أو اطلب صورة واحدة.';

  @override
  String get tbFrameSequence => 'الصورة';

  @override
  String get tbTransport => 'وسيلة النقل';

  @override
  String get tbSingleFrame => 'صورة واحدة';

  @override
  String get tbStartStream => 'ابدأ البث';

  @override
  String get tbPauseStream => 'أوقف البث مؤقتًا';

  @override
  String get tbEnableFlash => 'شغّل الإضاءة';

  @override
  String get tbDisableFlash => 'أطفئ الإضاءة';

  @override
  String get tbFlashCommandHint =>
      'تعكس هذه الأداة آخر إعداد إضاءة طُلب، وليس قياسًا لحالة العتاد.';

  @override
  String get tbReceivedFps => 'معدل الاستقبال';

  @override
  String get tbFpsUnit => 'صورة/ث';

  @override
  String get tbFramesReceived => 'الصور المستقبلة';

  @override
  String get tbIncompleteFrames => 'الصور غير المكتملة';

  @override
  String get tbDatagrams => 'حزم البيانات';

  @override
  String get tbFrameAge => 'عمر الصورة';

  @override
  String get tbSecondsUnit => 'ث';

  @override
  String get tbFrameBytes => 'حجم الصورة';

  @override
  String get tbBytesUnit => 'بايت';

  @override
  String get tbFixtureControls => 'الجهاز / التحكم';

  @override
  String get tbConnectionTitle => 'لوحة الاتصال';

  @override
  String get tbBleLink => 'التصريح عبر BLE';

  @override
  String get tbAdapterLabel => 'محوّل Bluetooth';

  @override
  String get tbAdapterHint =>
      'يُستخدم محوّل الخادم إذا تركت الحقل فارغًا. غيّره قبل الاتصال.';

  @override
  String get tbConnect => 'اتصل عبر BLE';

  @override
  String get tbDeviceMac => 'عنوان MAC للجهاز';

  @override
  String get tbDeviceHostname => 'اسم الجهاز';

  @override
  String get tbWifiProvisioning => 'إعداد شبكة WiFi';

  @override
  String get tbUseNetworkManager => 'استخدم اتصال NetworkManager النشط';

  @override
  String get tbNetworkManagerHint =>
      'تقرأ وحدة التحكم المحلية بيانات الشبكة النشطة. لا تعرض اللوحة كلمة المرور ولا تحفظها.';

  @override
  String get tbSsidLabel => 'اسم الشبكة (SSID)';

  @override
  String get tbPasswordLabel => 'كلمة مرور WiFi';

  @override
  String get tbPasswordHint =>
      'مخفية ومحفوظة في الذاكرة فقط، وتُمسح عند الإرسال. اتركها فارغة للشبكات المفتوحة فقط.';

  @override
  String get tbSaveAndReboot => 'احفظ WiFi وأعد التشغيل';

  @override
  String get tbSetupHint =>
      'تُحفظ البيانات مرة واحدة، ثم يُنتظر التأكيد المطابق قبل إعادة التشغيل. لا تُعاد محاولة الإعداد تلقائيًا عند الفشل.';

  @override
  String get tbRebootOnly => 'إعادة التشغيل فقط';

  @override
  String get tbRebootHint =>
      'أمر مستقل عبر BLE، لا يحفظ بيانات WiFi ولا يمسحها.';

  @override
  String get tbUdpAttach => 'جلسة UDP';

  @override
  String get tbIpLabel => 'عنوان IPv4 للجهاز';

  @override
  String get tbIpHint =>
      'أدخل العنوان من الراوتر أو من خرج UART بعد الإقلاع الجديد. لا يدعم البرنامج الثابت الاكتشاف عبر mDNS.';

  @override
  String get tbAttach => 'اربط جلسة بعنوان الجهاز';

  @override
  String get tbActiveIp => 'العنوان المرتبط';

  @override
  String get tbLocalListener => 'الاستقبال المحلي';

  @override
  String get tbUartLabel => 'UART للتشخيص (إعداد الخادم)';

  @override
  String get tbUartHint =>
      'إعداد يُحدد عند بدء الخادم ولا يُعدل هنا. قد يعرض UART عنوان الجهاز، وهو دليل تشخيصي وليس اكتشافًا للشبكة.';

  @override
  String get tbUartAvailable => 'تشخيص UART متاح';

  @override
  String get tbUartUnavailable => 'تشخيص UART غير متاح';

  @override
  String get tbDisconnect => 'افصل جهاز الاختبار';

  @override
  String get tbDisconnectHint => 'يوقف الجلسة دون مسح إعدادات الشبكة المحفوظة.';

  @override
  String get tbVerificationChannel => '٠٢ / قناة التحقق';

  @override
  String get tbTestTitle => 'تشغيل الاختبارات';

  @override
  String get tbProfileLabel => 'نمط الاختبار';

  @override
  String get tbProfileSmoke => 'سريع / تحقق أولي';

  @override
  String get tbProfileFull => 'كامل / يغيّر إعدادات الجهاز';

  @override
  String get tbProfileMobileFlow => 'مسار الهاتف / تجهيز الجهاز';

  @override
  String get tbProfileMissingAp => 'شبكة غائبة / حدود الاستعادة';

  @override
  String get tbProfileSoak => 'تحمّل / بث مستمر';

  @override
  String get tbProfileUnknown => 'نمط غير معروف';

  @override
  String get tbProfileSmokeHint =>
      'فحوص سريعة للجهاز. راجع كل نتيجة مسجلة، فالفحص غير المتاح لا يُعد ناجحًا.';

  @override
  String get tbProfileFullHint =>
      'يفحص حدود الإعداد قبل التجهيز النهائي. يتطلب جهازًا في وضع إعداد BLE جديدًا وتصريحًا صريحًا بتغيير الإعدادات.';

  @override
  String get tbProfileMobileFlowHint =>
      'يتحقق من مسار التجهيز كما في التطبيق: إعداد BLE، ثم إقلاع WiFi فقط، وربط العنوان، وفك صور UDP.';

  @override
  String get tbProfileMissingApHint =>
      'يختبر الإقلاع مع شبكة غير متاحة. يغيّر بيانات الشبكة المحفوظة وقد يتطلب استعادة صريحة للإعدادات بعد انتهائه.';

  @override
  String get tbProfileSoakHint =>
      'يراقب وصول الصور طوال المدة المحددة. تبقى الصور المفقودة والحزم غير المكتملة ظاهرة في الأدلة.';

  @override
  String get tbDurationLabel => 'المدة بالثواني';

  @override
  String get tbRunTests => 'ابدأ الاختبارات';

  @override
  String get tbCancelRun => 'ألغِ العملية';

  @override
  String get tbDestructiveProfileWarning =>
      'يغيّر إعدادات WiFi المحفوظة. يتطلب جهازًا في وضع إعداد جديدًا وتأكيدًا صريحًا، دون مسح أو استعادة تلقائية.';

  @override
  String get tbChecksRecorded => 'فحوص مسجلة';

  @override
  String get tbRunProgress => 'تقدم الاختبار';

  @override
  String get tbJobId => 'معرّف المهمة';

  @override
  String get tbNoTestResults => 'لم تُسجل فحوص بعد';

  @override
  String get tbNoTestResultsHint => 'اختر نمطًا لإنشاء تقرير أدلة محلي.';

  @override
  String get tbTestResults => 'نتائج اختبار البرنامج الثابت المسجلة';

  @override
  String get tbCheckName => 'الفحص';

  @override
  String get tbOutcome => 'النتيجة';

  @override
  String get tbDuration => 'المدة';

  @override
  String get tbDetails => 'التفاصيل / الرمز';

  @override
  String get tbEvidenceChannel => '٠٣ / قناة الأدلة';

  @override
  String get tbReportTitle => 'أدلة الجلسة';

  @override
  String get tbDownloadReport => 'نزّل التقرير';

  @override
  String get tbReportHint =>
      'تقرير الخادم الحالي، بما فيه الفحوص المسجلة والأدلة التشخيصية.';

  @override
  String get tbViewReport => 'اعرض التقرير';

  @override
  String get tbCloseReport => 'أغلق عرض التقرير';

  @override
  String get tbCurrentReport => 'تقرير JSON الحالي';

  @override
  String get tbEventLog => 'سجل أحداث وحدة التحكم';

  @override
  String get tbEvents => 'أحداث';

  @override
  String get tbNoEvents => 'لم تُسجل أحداث لوحدة التحكم.';

  @override
  String get tbFooterLocal =>
      'تحكم محلي. لا إعادة تلقائية لإرسال إعدادات الشبكة.';

  @override
  String get tbFooterEvidence =>
      'أدلة مرصودة فقط. غير المتحقق منه لا يُعد ناجحًا.';

  @override
  String get tbCloseConfirmation => 'أغلق تأكيد تغيير الإعدادات';

  @override
  String get tbConfigurationChange => 'تغيير الإعدادات / يلزم التأكيد';

  @override
  String get tbConfirmTestTitle => 'صرّح بتشغيل هذا الاختبار';

  @override
  String get tbConfirmTestDescription =>
      'قد يغيّر هذا النمط بيانات WiFi المحفوظة ويترك الجهاز في وضع إقلاع WiFi فقط. أكد جاهزية الجهاز وقدرتك على استعادة إعداداته بنفسك.';

  @override
  String get tbConfirmFreshSetup =>
      'الجهاز في وضع إعداد BLE جديد، ولا توجد بيانات WiFi محفوظة.';

  @override
  String get tbConfirmConfiguration =>
      'أسمح لهذا الاختبار باستبدال إعدادات WiFi المحفوظة أو مسحها.';

  @override
  String get tbNoAutomaticErase =>
      'لا تمسح اللوحة الإعدادات ولا تعيد إرسالها للاستعادة بعد الفشل. تتطلب الاستعادة إجراءً منفصلًا وصريحًا.';

  @override
  String get tbGoBack => 'ارجع';

  @override
  String get tbConfirmAndRun => 'صرّح وابدأ';

  @override
  String get tbJavaScriptRequired =>
      'فعّل JavaScript لاستخدام أدوات الاختبار المحلية.';

  @override
  String get tbPhaseDisconnected => 'غير متصل';

  @override
  String get tbPhaseBleSetup => 'إعداد BLE';

  @override
  String get tbPhasePaired => 'تم التصريح عبر BLE';

  @override
  String get tbPhaseProvisioned => 'حُفظت بيانات WiFi';

  @override
  String get tbPhaseRebooting => 'جارٍ إعادة التشغيل';

  @override
  String get tbPhaseWifiReady => 'WiFi جاهزة';

  @override
  String get tbPhaseStreaming => 'البث جارٍ';

  @override
  String get tbPhasePaused => 'متوقف مؤقتًا';

  @override
  String get tbPhaseError => 'خطأ في وحدة التحكم';

  @override
  String get tbPhaseUnknown => 'في انتظار الحالة';

  @override
  String get tbGuideDisconnected =>
      'اتصل بجهاز في وضع إعداد BLE جديد، أو اربط جلسة جهاز يعمل بالفعل عبر WiFi باستخدام عنوانه.';

  @override
  String get tbGuideBleSetup =>
      'اختر الشبكة ثم احفظها وأعد التشغيل. يصرّح إجراء الإعداد لاتصال BLE قبل إرسال بيانات الشبكة.';

  @override
  String get tbGuidePaired =>
      'اختر الشبكة المحلية النشطة أو أدخل بياناتها، ثم احفظها وأعد التشغيل مرة واحدة.';

  @override
  String get tbGuideProvisioned =>
      'حُفظت بيانات الشبكة. انتظر إعادة التشغيل ضمن الإعداد، أو استخدم أمر إعادة التشغيل المستقل عند الحاجة.';

  @override
  String get tbGuideRebooting =>
      'انتظر دليلًا على إقلاع جديد. لا تُعد إرسال بيانات الشبكة أثناء إعادة التشغيل.';

  @override
  String get tbGuideWifiReady =>
      'أدخل عنوان الجهاز من الراوتر أو UART، ثم اربط جلسة UDP إن لم تكن مرتبطة بالفعل.';

  @override
  String get tbGuideStreaming =>
      'افحص الصور المباشرة وشغّل نمط التحقق المناسب.';

  @override
  String get tbGuidePaused =>
      'الجلسة متوقفة مؤقتًا. استأنف البث أو اطلب صورة واحدة.';

  @override
  String get tbGuideError =>
      'راجع خطأ وحدة التحكم والأدلة قبل اتخاذ إجراء منفصل لاستعادة الجهاز.';

  @override
  String get tbGuideUnknown =>
      'في انتظار وحدة التحكم المحلية للإبلاغ عن حالة الجهاز.';

  @override
  String get tbPreviewEmpty => 'لا توجد إشارة';

  @override
  String get tbPreviewLive => 'مباشر';

  @override
  String get tbPreviewStale => 'صورة قديمة';

  @override
  String get tbPreviewPaused => 'متوقف مؤقتًا';

  @override
  String get tbPreviewReady => 'آخر صورة';

  @override
  String get tbFrameStaleHint =>
      'هذه صورة قديمة، وليست دليلًا على استمرار البث.';

  @override
  String get tbFramePausedHint => 'البث متوقف مؤقتًا. تُعرض آخر صورة مستقبلة.';

  @override
  String get tbNoTransport => 'لا توجد';

  @override
  String get tbUnknownValue => 'غير متاح';

  @override
  String get tbStatusIdle => 'خامل';

  @override
  String get tbStatusQueued => 'في الانتظار';

  @override
  String get tbStatusRunning => 'قيد التشغيل';

  @override
  String get tbStatusStarted => 'بدأ';

  @override
  String get tbStatusPassed => 'ناجح';

  @override
  String get tbStatusSuccess => 'تم بنجاح';

  @override
  String get tbStatusCompleted => 'مكتمل';

  @override
  String get tbStatusFailed => 'فشل';

  @override
  String get tbStatusRejected => 'مرفوض';

  @override
  String get tbStatusCancelled => 'ملغى';

  @override
  String get tbStatusCancelling => 'جارٍ الإلغاء';

  @override
  String get tbStatusSkipped => 'لم يُنفذ';

  @override
  String get tbStatusUnverified => 'غير متحقق منه';

  @override
  String get tbStatusWarning => 'تحذير';

  @override
  String get tbStatusReady => 'جاهز';

  @override
  String get tbStatusUnknown => 'حالة غير معروفة';

  @override
  String get tbStreamOperation => 'التحكم في البث';

  @override
  String get tbFlashOperation => 'التحكم في الإضاءة';

  @override
  String get tbActionQueued =>
      'قبلت وحدة التحكم المحلية الأمر. انتظر النتيجة المسجلة.';

  @override
  String get tbCancellationRequested =>
      'أُرسل طلب الإلغاء. انتظر حتى تنتهي وحدة التحكم من إنهاء الجلسة.';

  @override
  String get tbActionRejected =>
      'رفضت وحدة التحكم هذه العملية. راجع رمز الخطأ.';

  @override
  String get tbRequestFailed =>
      'فشل الطلب المحلي. راجع رمز الخطأ قبل المحاولة مجددًا.';

  @override
  String get tbInvalidResponse => 'أعادت وحدة التحكم استجابة غير صالحة.';

  @override
  String get tbConfigurationUnavailable =>
      'إعدادات وحدة التحكم غير متاحة. تبقى الأوامر معطلة حتى تُحمّل الإعدادات.';

  @override
  String get tbLocalizationUnavailable =>
      'تعذر تحميل اللغة المختارة من وحدة التحكم المحلية.';

  @override
  String get tbNoProfiles => 'لا توفر وحدة التحكم أنماط اختبار مدعومة.';

  @override
  String get tbInvalidIp =>
      'أدخل عنوان IPv4 صالحًا للجهاز، يتكون من أربعة أعداد بين 0 و255.';

  @override
  String get tbInvalidSsid =>
      'أدخل اسم شبكة يتراوح حجمه بين 1 و32 بايت بترميز UTF-8.';

  @override
  String get tbInvalidDuration => 'أدخل عددًا صحيحًا موجبًا للمدة بالثواني.';

  @override
  String get tbTestFailed => 'فشل الاختبار. راجع الفحوص المسجلة ورمز الخطأ.';

  @override
  String get tbReportUnavailable =>
      'لا يوجد تقرير متاح من وحدة التحكم المحلية.';

  @override
  String get tbReportLoading => 'جارٍ تحميل التقرير';

  @override
  String get tbRedacted => '[محجوب]';

  @override
  String get tbErrorBusy =>
      'الجهاز مشغول. انتظر العملية الحالية أو اطلب إلغاءها.';

  @override
  String get tbErrorCancelled =>
      'أُلغيت العملية. راجع الأدلة قبل البدء من جديد.';

  @override
  String get tbErrorInvalidRequest =>
      'الطلب غير صالح لوحدة التحكم هذه. راجع رمز الخطأ.';

  @override
  String get tbErrorInvalidWifi =>
      'بيانات WiFi غير صالحة أو غير متاحة. راجع إعدادات الشبكة وأرسلها بإجراء صريح.';

  @override
  String get tbErrorSecurity =>
      'رفضت وحدة التحكم فحص أمان الطلب. أعد تحميل اللوحة قبل المحاولة مجددًا.';

  @override
  String get tbErrorNotConnected =>
      'اتصل بالجهاز أو اربط عنوانه قبل إرسال هذا الأمر.';

  @override
  String get tbErrorSetupRequired =>
      'الجهاز ليس في مرحلة الإعداد المطلوبة. اتبع مراحل تجهيز الجهاز.';

  @override
  String get tbErrorConfirmationRequired =>
      'يتطلب هذا الاختبار تصريحًا صريحًا بتغيير الإعدادات المحفوظة.';

  @override
  String get tbErrorRecoveryRequired =>
      'تحتاج الإعدادات إلى استعادة. راجع الأدلة واستعد الجهاز بإجراء صريح، دون مسح أو إعادة إرسال تلقائية.';

  @override
  String get tbErrorUartRequired =>
      'يتطلب هذا الفحص UART للتشخيص. اضبطه عند بدء وحدة التحكم المحلية.';

  @override
  String get tbErrorDependency =>
      'أحد المكونات المحلية المطلوبة غير متاح. راجع إعداد وحدة التحكم ورمز الخطأ.';

  @override
  String get tbErrorPlatform => 'هذه العملية غير مدعومة على المنصة الحالية.';

  @override
  String get tbErrorHardwareLocked =>
      'تستخدم عملية أخرى جهاز الاختبار. أنهِ تلك الجلسة قبل الاتصال هنا.';

  @override
  String get tbErrorFrameTimeout =>
      'لم تصل صورة كاملة من الكاميرا قبل انتهاء المهلة. راجع الاتصال والأدلة.';

  @override
  String get tbErrorHardware =>
      'فشلت عملية على العتاد. راجع الأدلة المسجلة ورمز الخطأ.';

  @override
  String get tbErrorInternal =>
      'تعذر على وحدة التحكم المحلية إكمال هذه العملية. راجع رمز الخطأ.';

  @override
  String get aboutBody =>
      'سبكترو لِن بور v5.5 — رصد الكائنات المحلي عبر YOLO26-Nano ONNX (مرفق بالتطبيق مع تنزيل/تحقق تلقائي) + خيار النماذج السحابية فقط (مع بقاء YOLO محلياً) + رؤية موندريم ٣ السحابية + سلسلة OpenRouter الاستدلالية (nemotron←gemma←inkling) + بث صوت fish-audio/s2.1-pro-free:free + بحث علمي بثلاثة أوضاع (صارم / مفصل / دلالي عبر 119 عنصراً كيميائياً و110 مركبات ومعايير السلامة GHS وPubChem وويكيبيديا والويب) + استشهادات مرقمة [n] ومؤشرات تطابق مصادر محتملة (تشابه لفظي فقط، وليست إثباتًا لصحة الادعاء) + سياق علمي مهيكل ذاتي التحديث + قاعدة بيانات داخلية SQLite WAL من 9 جداول لحفظ المحادثات والكاش والسجلات والأعطال والقياسات.\n\nالخط التشغيلي: كاميرا الهاتف أو نظارة ESP32-CAM ← صناديق YOLO26-Nano التفاعلية ← لمس الصندوق لوضع علامة الهدف ← الضغط على التقاط وتحليل لأخذ صورتين (نظيفة + معلمة) ← تحليل موندريم ٣ ← سياق علمي موثق ومؤشرات تطابق المصادر ← محادثة مستمرة محفوظة تلقائياً.\n\nملك عادل سيد حسن (طالبة) · عبد الرحمن أيمن محمد (مطور) · الصف الأول الثانوي ٣/١ · مدرسة الأشمونين الثانوية · الميزانية: ٢٬٥٠٠–٦٬٠٠٠ جنيه.';
}
