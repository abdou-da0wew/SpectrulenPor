import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:http/http' as http;

/// Streams a deep-reasoning markdown reply from an OpenRouter text model.
///
/// We intentionally only send the *textual* local description upstream
/// (e.g. "In front of you is a glass beaker. Visible text: 'NaCl 0.9%'.")
/// rather than the raw image. This keeps the request body tiny over mobile
/// data, lets us use the free-tier text-only models, and keeps latency low.
///
/// Endpoint: POST https://openrouter.ai/api/v1/chat/completions
/// Body: standard OpenAI-style chat completion with stream=true.
class OpenRouterService {
  // Mutable so the settings screen can hot-swap the key without restarting.
  String apiKey;
  static const String _endpoint =
      'https://openrouter.ai/api/v1/chat/completions';

  OpenRouterService({required this.apiKey});

  bool get isConfigured => apiKey.isNotEmpty;

  /// Stream markdown tokens as they arrive.
  Stream<String> streamDeepReasoning({
    required String model,
    required String localDescription,
    String? extraContext,
  }) async* {
    if (!isConfigured) {
      yield '*OpenRouter API key not set. Open Settings → API keys.*';
      return;
    }

    final prompt = _buildPrompt(localDescription, extraContext);

    final request = http.Request('POST', Uri.parse(_endpoint))
      ..headers.addAll({
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
        'HTTP-Referer': 'https://github.com/spectraglass/mobile',
        'X-Title': 'SpectraGlass',
      })
      ..body = jsonEncode({
        'model': model,
        'stream': true,
        'temperature': 0.4,
        'max_tokens': 900,
        'messages': [
          {
            'role': 'system',
            'content':
                'You are an expert knowledge assistant for a visually impaired '
                'wearer of smart scientific glasses. The local on-device vision '
                'system has identified the object in front of the wearer and '
                'sent you a short text description. Your job is to enrich that '
                'description with helpful, accurate, immediately useful '
                'information. Always answer in clear, plain language suitable '
                'for spoken text-to-speech output. Use markdown headers '
                '(## Title) and short bullet points. Avoid long sentences.',
          },
          {'role': 'user', 'content': prompt},
        ],
      });

    final client = http.Client();
    final response = client.send(request);

    try {
      final streamed = await response;
      if (streamed.statusCode != 200) {
        final body = await streamed.stream.bytesToString();
        yield '*Upstream error ${streamed.statusCode}: ${body.substring(0, body.length > 300 ? 300 : body.length)}*';
        return;
      }

      // Parse Server-Sent Events (SSE) stream.
      final lineStream = streamed.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lineStream) {
        if (!line.startsWith('data: ')) continue;
        final payload = line.substring(6).trim();
        if (payload == '[DONE]') break;

        try {
          final json = jsonDecode(payload) as Map<String, dynamic>;
          final delta =
              json['choices']?[0]?['delta']?['content'] as String?;
          if (delta != null && delta.isNotEmpty) yield delta;
        } catch (e) {
          log('SSE parse error: $e');
        }
      }
    } finally {
      client.close();
    }
  }

  /// Build the user prompt that wraps the local description.
  /// Designed to produce a clean spoken-style narration with structured info.
  String _buildPrompt(String localDescription, String? extraContext) {
    final buf = StringBuffer();
    buf.writeln('The local vision system on the glasses identified:');
    buf.writeln('"""');
    buf.writeln(localDescription);
    buf.writeln('"""');
    if (extraContext != null && extraContext.isNotEmpty) {
      buf.writeln();
      buf.writeln('Additional context from sensors: $extraContext');
    }
    buf.writeln();
    buf.writeln('Please give me:');
    buf.writeln('## What it is');
    buf.writeln('A one-sentence identification, restated more precisely.');
    buf.writeln();
    buf.writeln('## Why it matters');
    buf.writeln('Two or three short bullets with practical or historical context.');
    buf.writeln();
    buf.writeln('## Practical tips');
    buf.writeln('Three bullets: how to use it, common mistakes, or safety notes.');
    buf.writeln();
    buf.writeln('## Explore');
    buf.writeln('Three related concepts or search queries the wearer might want to dig into.');
    return buf.toString();
  }
}
