/// Telemetry packet from the glasses' UV + IR channels.
///
/// The ESP32-CAM firmware samples:
///   * UV sensor  (e.g. GUVA-S12SD analog) on ADC pin GPIO12
///   * IR sensor  (photodiode/thermopile analog) on ADC pin GPIO13
/// and interleaves a text packet between JPEG frames:
///   `$UV:1234;IR:567\n`   (12-bit ADC raw values, 0..4095)
class SpectrumReading {
  final int uvRaw; // 0..4095
  final int irRaw; // 0..4095
  final DateTime at;

  SpectrumReading({required this.uvRaw, required this.irRaw, required this.at});

  static SpectrumReading? tryParse(String line) {
    // Expected: "$UV:1234;IR:567"
    if (!line.startsWith(r'$')) return null;
    final uvMatch = RegExp(r'UV:(\d+)').firstMatch(line);
    final irMatch = RegExp(r'IR:(\d+)').firstMatch(line);
    if (uvMatch == null || irMatch == null) return null;
    return SpectrumReading(
      uvRaw: int.tryParse(uvMatch.group(1)!) ?? 0,
      irRaw: int.tryParse(irMatch.group(1)!) ?? 0,
      at: DateTime.now(),
    );
  }

  /// Normalized 0..100 % of full scale.
  double get uvPercent => (uvRaw / 4095).clamp(0, 1) * 100;
  double get irPercent => (irRaw / 4095).clamp(0, 1) * 100;

  /// Heuristic thresholds (calibrate against your sensors):
  ///   * UV above 72 % full scale flags strong UV emission/absorption.
  ///   * IR above 80 % full scale flags strong heat / IR signature.
  bool get uvHazard => uvPercent >= 72;
  bool get irHazard => irPercent >= 80;

  bool get anyHazard => uvHazard || irHazard;

  /// One-line spoken summary fed to TTS + the upstream prompt.
  String telemetryLine(String lang) {
    final uv = uvPercent.toStringAsFixed(0);
    final ir = irPercent.toStringAsFixed(0);
    if (lang.startsWith('ar')) {
      return 'قراءة المستشعرات: الأشعة فوق البنفسجية $uv% والأشعة تحت '
          'الحمراء $ir% من المدى الكامل.';
    }
    return 'Sensor telemetry: UV at $uv% and IR at $ir% of full scale.';
  }
}

/// State of matter parsed out of the AI analysis (or sensor heuristics).
enum MatterState { unknown, solid, liquid, gas }

MatterState matterStateFromText(String text) {
  final t = text.toLowerCase();
  if (t.contains('liquid') || text.contains('سائل')) return MatterState.liquid;
  if (t.contains('gas') || text.contains('غاز') || text.contains('گاز')) {
    return MatterState.gas;
  }
  if (t.contains('solid') || text.contains('صلب')) return MatterState.solid;
  return MatterState.unknown;
}

/// Hazard keyword detector — bilingual. Triggers the red banner + warning TTS.
bool textSignalsHazard(String text) {
  const en = [
    'hazard', 'dangerous', 'toxic', 'poison', 'corrosive', 'flammable',
    'explosive', 'caustic', 'volatile', 'radioactive', 'warn',
  ];
  const arWords = [
    'خطير', 'سام', 'سامة', 'سموم', 'حارق', 'اشتعال', 'انفجار',
    'كاوية', 'كاوٍ', 'إشعاع', 'اشعاع', 'تحذير', 'خطر',
  ];
  final lower = text.toLowerCase();
  for (final w in en) {
    if (lower.contains(w)) return true;
  }
  for (final w in arWords) {
    if (text.contains(w)) return true;
  }
  return false;
}
