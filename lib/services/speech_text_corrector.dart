/// Conservative offline cleanup for speech-recognition output.
///
/// It normalizes punctuation, common Arabic marks and a small, explicit
/// technology glossary. It never guesses a replacement for unknown words.
class SpeechTextCorrector {
  static final Map<RegExp, String> _englishGlossary = {
    RegExp(r'\bspectrulen\s+(?:poor|por)\b', caseSensitive: false):
        'SpectruLenPor',
    RegExp(r'\bspectro\s+len\s+por\b', caseSensitive: false): 'SpectruLenPor',
    RegExp(r'\bopen\s+router\b', caseSensitive: false): 'OpenRouter',
    RegExp(r'\bfish\s+audio\b', caseSensitive: false): 'Fish Audio',
    RegExp(r'\bsuper\s+tonic(?:\s+3)?\b', caseSensitive: false): 'Supertonic-3',
    RegExp(r'\bvos\s*k\b', caseSensitive: false): 'Vosk',
    RegExp(r'\besp\s+32\b', caseSensitive: false): 'ESP32',
    RegExp(r'\bwi[\s-]?fi\b', caseSensitive: false): 'Wi-Fi',
    RegExp(r'\bt\s*t\s*s\b', caseSensitive: false): 'TTS',
    RegExp(r'\bs\s*t\s*t\b', caseSensitive: false): 'STT',
    RegExp(r'\bllm\b', caseSensitive: false): 'LLM',
  };

  static final Map<RegExp, String> _arabicGlossary = {
    RegExp(r'سبكترولين\s*بور'): 'SpectruLenPor',
    RegExp(r'سبكترو\s+لين\s+بور'): 'SpectruLenPor',
  };

  static String correct(
    String input, {
    required String languageCode,
    bool isFinal = false,
  }) {
    var text = input.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return text;

    final isArabic = languageCode.toLowerCase().startsWith('ar') ||
        RegExp(r'[\u0600-\u06FF]').hasMatch(text);

    if (isArabic) {
      text = _normalizeArabic(text);
      _arabicGlossary.forEach((pattern, replacement) {
        text = text.replaceAll(pattern, replacement);
      });
      return _finishSentence(text, isFinal, r'[.!؟。؛،,;:)\]}»]$');
    }

    _englishGlossary.forEach((pattern, replacement) {
      text = text.replaceAll(pattern, replacement);
    });
    text = text
        .replaceAllMapped(
          RegExp(r'\s+([,.!?;:])'),
          (match) => match[1]!,
        )
        .replaceAllMapped(
          RegExp(r'([,.!?;:])(?=\S)'),
          (match) => '${match[1]} ',
        )
        .replaceFirstMapped(
          RegExp(r'^[a-z]'),
          (match) => match[0]!.toUpperCase(),
        )
        .replaceAll(RegExp(r'\bi\b'), 'I')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return _finishSentence(text, isFinal, r'[.!?;:)\]}»]$');
  }

  static String _normalizeArabic(String input) {
    return input
        .replaceAll(RegExp(r'[\u064B-\u065F\u0670\u0640]'), '')
        .replaceAllMapped(
          RegExp(r'\s+([،؛؟.!])'),
          (match) => match[1]!,
        )
        .replaceAllMapped(
          RegExp(r'([،؛؟.!])(?=\S)'),
          (match) => '${match[1]} ',
        )
        .replaceAllMapped(
          RegExp(r'([،؛؟.!])\1+'),
          (match) => match[1]!,
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _finishSentence(
    String text,
    bool isFinal,
    String trailingPunctuation,
  ) {
    if (text.isEmpty ||
        !isFinal ||
        RegExp(trailingPunctuation).hasMatch(text)) {
      return text;
    }
    return '$text.';
  }
}
