import 'package:flutter/material.dart';

/// Lightweight bilingual (English / Arabic) string table for SpectruLenPor.
///
/// Usage: `S.t(context, S.connectGlasses)` resolves the string for the
/// current MaterialApp locale. Arabic uses the official project terminology:
///   النظارة الذكية لتحليل الطيف واكتشاف العناصر والمركبات الكيميائية
class S {
  S._();

  static const Locale en = Locale('en');
  static const Locale ar = Locale('ar');

  // ---- keys ----
  static const appName = 'appName';
  static const appTagline = 'appTagline';
  static const glassesNotConnected = 'glassesNotConnected';
  static const scanning = 'scanning';
  static const connecting = 'connecting';
  static const connected = 'connected';
  static const btError = 'btError';
  static const connectGlasses = 'connectGlasses';
  static const disconnect = 'disconnect';
  static const waitingFrame = 'waitingFrame';
  static const phoneCamera = 'phoneCamera';
  static const glassesCam = 'glassesCam';
  static const localVision = 'localVision';
  static const idleLabel = 'idleLabel';
  static const deepReasoning = 'deepReasoning';
  static const deepHint = 'deepHint';
  static const describeNow = 'describeNow';
  static const analyzing = 'analyzing';
  static const soundOn = 'soundOn';
  static const muted = 'muted';
  static const settings = 'settings';
  static const spectrum = 'spectrum';
  static const uvChannel = 'uvChannel';
  static const irChannel = 'irChannel';
  static const noSensorData = 'noSensorData';
  static const stateMatter = 'stateMatter';
  static const stateUnknown = 'stateUnknown';
  static const stateSolid = 'stateSolid';
  static const stateLiquid = 'stateLiquid';
  static const stateGas = 'stateGas';
  static const hazardClear = 'hazardClear';
  static const hazardDetected = 'hazardDetected';
  static const hazardSpeech = 'hazardSpeech';
  static const flashlight = 'flashlight';
  static const waitingSensors = 'waitingSensors';
  static const credits = 'credits';

  static const Map<String, Map<String, String>> _table = {
    appName: {
      'en': 'SpectruLenPor',
      'ar': 'سبكترو لِن بور',
    },
    appTagline: {
      'en': 'Smart glasses for spectrum analysis and detection of chemical '
          'elements and compounds',
      'ar': 'النظارة الذكية لتحليل الطيف واكتشاف العناصر والمركبات الكيميائية',
    },
    glassesNotConnected: {
      'en': 'Glasses not connected',
      'ar': 'النظارة غير متصلة',
    },
    scanning: {'en': 'Scanning for glasses…', 'ar': 'جارٍ البحث عن النظارة…'},
    connecting: {'en': 'Connecting…', 'ar': 'جارٍ الاتصال…'},
    connected: {'en': 'Connected', 'ar': 'متصل'},
    btError: {'en': 'Bluetooth error', 'ar': 'خطأ في البلوتوث'},
    connectGlasses: {'en': 'Connect glasses', 'ar': 'توصيل النظارة'},
    disconnect: {'en': 'Disconnect', 'ar': 'قطع الاتصال'},
    waitingFrame: {
      'en': 'Waiting for a frame… (use phone camera to test without glasses)',
      'ar': 'بانتظار إطار صورة… (استخدم كاميرا الهاتف للتجربة بدون النظارة)',
    },
    phoneCamera: {'en': 'Phone camera', 'ar': 'كاميرا الهاتف'},
    glassesCam: {'en': 'Glasses', 'ar': 'النظارة'},
    localVision: {'en': 'Local vision — instant', 'ar': 'الرؤية المحلية — فورية'},
    idleLabel: {'en': 'Idle — waiting for next frame.', 'ar': 'خامل — بانتظار الإطار التالي.'},
    deepReasoning: {'en': 'AI analysis', 'ar': 'تحليل الذكاء الاصطناعي'},
    deepHint: {
      'en': 'Point at a substance, then tap "Describe now" for full '
          'spectrum-based analysis.',
      'ar': 'وجّه الكاميرا نحو المادة ثم اضغط "حلّل الآن" للحصول على تحليل '
          'كامل قائم على الطيف.',
    },
    describeNow: {'en': 'Analyze now', 'ar': 'حلّل الآن'},
    analyzing: {'en': 'Analyzing…', 'ar': 'جارٍ التحليل…'},
    soundOn: {'en': 'Sound on', 'ar': 'الصوت مفتوح'},
    muted: {'en': 'Muted', 'ar': 'صامت'},
    settings: {'en': 'Settings', 'ar': 'الإعدادات'},
    spectrum: {'en': 'Spectrum channels', 'ar': 'قنوات الطيف'},
    uvChannel: {'en': 'UV', 'ar': 'فوق بنفسجي'},
    irChannel: {'en': 'IR', 'ar': 'تحت أحمر'},
    noSensorData: {
      'en': 'No sensor telemetry yet — UV/IR readings appear when the '
          'glasses stream them.',
      'ar': 'لا توجد بيانات مستشعرات بعد — تظهر قراءات UV/IR عند إرسالها '
          'من النظارة.',
    },
    stateMatter: {'en': 'State of matter', 'ar': 'حالة المادة'},
    stateUnknown: {'en': 'Unknown', 'ar': 'غير معروفة'},
    stateSolid: {'en': 'Solid', 'ar': 'صلب'},
    stateLiquid: {'en': 'Liquid', 'ar': 'سائل'},
    stateGas: {'en': 'Gas', 'ar': 'غاز'},
    hazardClear: {'en': 'No hazard detected', 'ar': 'لا توجد مخاطر'},
    hazardDetected: {'en': 'Hazard detected!', 'ar': 'تم اكتشاف خطر!'},
    hazardSpeech: {
      'en': 'Warning! Hazardous material detected. Step back carefully.',
      'ar': 'تحذير! تم اكتشاف مادة خطرة. تراجع بحذر.',
    },
    flashlight: {'en': 'Glasses flashlight', 'ar': 'مصباح النظارة'},
    waitingSensors: {'en': 'Waiting for sensor data…', 'ar': 'بانتظار بيانات المستشعرات…'},
    credits: {
      'en': 'SpectruLenPor · Malak Adel Sayed Hassan · Grade 1 secondary, '
          'Class 3/1 · Ashmounin Secondary School',
      'ar': 'سبكترو لِن بور · ملك عادل سيد حسن · الصف الأول الثانوي ٣/١ · '
          'مدرسة الأشمونين الثانوية',
    },
  };

  /// Resolve [key] for the current locale.
  static String t(BuildContext context, String key) {
    final code = Localizations.localeOf(context).languageCode;
    final table = _table[key];
    if (table == null) return key;
    return table[code] ?? table['en'] ?? key;
  }

  /// Static resolution without context (for TTS / prompts).
  static String forLang(String key, String languageCode) {
    final table = _table[key];
    if (table == null) return key;
    return table[languageCode] ?? table['en'] ?? key;
  }
}
