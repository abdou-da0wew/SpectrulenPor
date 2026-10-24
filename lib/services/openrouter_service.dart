import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:http/http.dart' as http;

/// Streams the AI analysis from OpenRouter.
///
/// Pipeline philosophy (per project design):
///   * The **specialized local model** (ONNX Runtime Mobile) does the actual
///     analysis — classification, confidences, sensor interpretation hints.
///   * The **LLM only presents** that analysis in clear spoken language.
///     => short prompts, low max_tokens, streaming — first sentence arrives
///     in ~1s and is spoken immediately while the rest streams.
///
/// Endpoint: POST https://openrouter.ai/api/v1/chat/completions (SSE stream).
class OpenRouterService {
  // Mutable so Settings can hot-swap the key without restart.
  String apiKey;
  static const String _endpoint =
      'https://openrouter.ai/api/v1/chat/completions';

  OpenRouterService({required this.apiKey});

  bool get isConfigured => apiKey.isNotEmpty;

  /// Stream markdown tokens as they arrive.
  ///
  /// [predictions]   — top-k output of the specialized ONNX model (may be null
  ///                   when ML Kit produced the label instead).
  /// [labelSentence] — ready-to-speak sentence from the local vision stage.
  /// [telemetry]     — UV/IR sensor line (optional).
  /// [lang]          — 'en' or 'ar'.
  Stream<String> streamAnalysis({
    required String model,
    required String labelSentence,
    List<(String, double)>? predictions,
    String? telemetry,
    String lang = 'en',
  }) async* {
    if (!isConfigured) {
      yield lang.startsWith('ar')
          ? '*لم يتم ضبط مفتاح OpenRouter. افتح الإعدادات ← المفاتيح.*'
          : '*OpenRouter API key not set. Open Settings → API keys.*';
      return;
    }

    final request = http.Request('POST', Uri.parse(_endpoint))
      ..headers.addAll({
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
        'HTTP-Referer': 'https://github.com/abdou-da0wew/SpectrulenPor',
        'X-Title': 'SpectruLenPor',
      })
      ..body = jsonEncode({
        'model': model,
        'stream': true,
        'temperature': 0.3, // presentation task — stay factual, low creativity
        'max_tokens': 380, // presenter role → short; cuts tail latency
        'messages': [
          {'role': 'system', 'content': _systemPrompt(lang)},
          {'role': 'user', 'content': _userPrompt(
            labelSentence: labelSentence,
            predictions: predictions,
            telemetry: telemetry,
            lang: lang,
          )},
        ],
      });

    final client = http.Client();
    try {
      final streamed = await client.send(request);
      if (streamed.statusCode != 200) {
        final body = await streamed.stream.bytesToString();
        yield '*${streamed.statusCode}: ${body.substring(0, body.length > 220 ? 220 : body.length)}*';
        return;
      }

      final lineStream = streamed.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lineStream) {
        if (!line.startsWith('data: ')) continue;
        final payload = line.substring(6).trim();
        if (payload == '[DONE]') break;
        try {
          final json = jsonDecode(payload) as Map<String, dynamic>;
          final delta = json['choices']?[0]?['delta']?['content'] as String?;
          if (delta != null && delta.isNotEmpty) yield delta;
        } catch (e) {
          log('SSE parse: $e');
        }
      }
    } finally {
      client.close();
    }
  }

  String _systemPrompt(String lang) {
    if (lang.startsWith('ar')) {
      return 'أنت مساعد صوتي لنظارة "سبكترو لِن بور" لتحليل الطيف واكتشاف '
          'العناصر والمركبات الكيميائية. نموذج محلي متخصص قد حصل على نتائج '
          'التحليل، ومهمتك فقط: صياغة النتائج في لغة عربية واضحة وقابلة '
          'للنطق الصوتي، بجُمل قصيرة، بدون رموز أو تنسيق معقد. اذكر حالة '
          'المادة (صلب/سائل/غاز) والتقديرات المئوية إن وُجدت، وحدد بوضوح في '
          'سطر مستقل يبدأ بـ "تحذير:" إذا كانت المادة خطرة (سامة، حارقة، '
          'كاوية، قابلة للانفجار). لا تخترع بيانات غير موجودة.';
    }
    return 'You are the voice assistant of "SpectruLenPor" smart glasses for '
        'spectrum analysis and detection of chemical elements and compounds. '
        'A specialized on-device model has ALREADY produced the analysis; '
        'your only job is to present it: clear, spoken-friendly language, '
        'short sentences, no heavy markdown. State the state of matter '
        '(solid/liquid/gas) and percentage estimates when available. If the '
        'material is hazardous (toxic, flammable, corrosive, explosive), add '
        'one standalone line starting with "Warning:" and say what to do. '
        'Never invent data that is not in the input.';
  }

  String _userPrompt({
    required String labelSentence,
    List<(String, double)>? predictions,
    String? telemetry,
    required String lang,
  }) {
    final buf = StringBuffer();
    if (lang.startsWith('ar')) {
      buf.writeln('نتيجة النموذج المتخصص: $labelSentence');
      if (predictions != null && predictions.isNotEmpty) {
        buf.writeln('أعلى الاحتمالات: ${predictions.map((p) => "${p.$1} ${(p.$2 * 100).toStringAsFixed(0)}%").join('، ')}');
      }
      if (telemetry != null) buf.writeln(telemetry);
      buf.writeln();
      buf.writeln('اكتب فقرة قصيرة (٣-٥ جمل) تشرح ما المادة، حالتها، واستخدامها أو خطرها.');
    } else {
      buf.writeln('Specialized model result: $labelSentence');
      if (predictions != null && predictions.isNotEmpty) {
        buf.writeln('Top predictions: ${predictions.map((p) => "${p.$1} ${(p.$2 * 100).toStringAsFixed(0)}%").join(', ')}');
      }
      if (telemetry != null) buf.writeln(telemetry);
      buf.writeln();
      buf.writeln('Write a short paragraph (3-5 sentences): what the substance/'
          'object is, its state of matter, one practical note or use, and the '
          'hazard line if applicable. Then a "## Explore" section with 3 '
          'related terms.');
    }
    return buf.toString();
  }
}
