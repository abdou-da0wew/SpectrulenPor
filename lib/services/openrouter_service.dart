import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:http/http.dart' as http;
import '../models/chat_message.dart';
import '../models/citation.dart';
import '../models/conversation_context.dart';
import 'docs_search_service.dart';
import 'wikipedia_service.dart';
import 'fact_checker_service.dart';
import 'chat_session.dart';

/// Streams the AI presentation pass from OpenRouter.
///
/// Pipeline philosophy (per project design):
///   * **Moondream3 cloud** (or the local fallbacks) is the ANALYST — it
///     produces the factual analysis of the frame.
///   * **This LLM only PRESENTS** that analysis in clear spoken language.
///     => short prompts, low max_tokens, streaming — first sentence arrives
///     in ~1s and is spoken immediately while the rest streams.
///
/// Text+reasoning model chain (user-specified, first that works wins):
///   1. google/gemma-4-26b-a4b-it:free ............ primary
///   2. thinkingmachines/inkling-small:free ....... fallback 1
///   3. nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free ... fallback 2
///
/// Streaming captures reasoning tokens from the final usage chunk:
///   chunk.usage.completionTokensDetails.reasoningTokens
///
/// Endpoint: POST https://openrouter.ai/api/v1/chat/completions (SSE).
class OpenRouterService {
  OpenRouterService({String? apiKey, http.Client Function()? clientFactory})
      : apiKey = apiKey ?? defaultApiKey,
        clientFactory = clientFactory;

  /// Key resolution: Settings (SharedPreferences) →
  /// `assets/config/secrets.json` → `--dart-define` → ''. Empty in source so
  /// pushes pass GitHub push protection.
  static const String defaultApiKey =
      String.fromEnvironment('OPENROUTER_LLM_KEY');

  /// Mutable so Settings can hot-swap the key without restart.
  String apiKey;

  /// Injectable http.Client factory (unit tests swap in a MockClient).
  @visibleForTesting
  http.Client Function()? clientFactory;

  /// Real host on mobile/desktop; relative CORS-proxy path in web preview.
  static String get endpoint => kIsWeb
      ? '/openrouter/v1/chat/completions'
      : 'https://openrouter.ai/api/v1/chat/completions';

  /// The full fallback chain in priority order.
  static const List<String> modelChain = [
    'google/gemma-4-26b-a4b-it:free',
    'thinkingmachines/inkling-small:free',
    'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free',
  ];

  /// Which chain entry answered last (0 = primary, 1/2 = fallback).
  int lastChainIndex = 0;
  String get lastModelUsed =>
      lastChainIndex < modelChain.length ? modelChain[lastChainIndex] : '?';

  /// Reasoning tokens reported by the final usage chunk (when the upstream
  /// model is a reasoning model and OpenRouter returns usage).
  int? lastReasoningTokens;

  bool get isConfigured => apiKey.isNotEmpty;

  /// Stream markdown tokens as they arrive, walking the fallback chain
  /// until one model streams successfully.
  ///
  /// [moondreamAnalysis] — factual analysis from Moondream3 cloud (or the
  ///   local fallback). The presenter treats this as ground truth.
  /// [labelSentence]     — ready-to-speak sentence from the vision cascade.
  /// [predictions]       — top-k output when the ONNX engine produced it.
  /// [telemetry]         — UV/IR sensor line (optional).
  /// [lang]              — 'en' or 'ar'.
  /// [startModel]        — preferred chain entry (default 0 = gemma).
  Stream<String> streamAnalysis({
    required String labelSentence,
    String? moondreamAnalysis,
    List<(String, double)>? predictions,
    String? telemetry,
    String lang = 'en',
    int startModel = 0,
  }) async* {
    if (!isConfigured) {
      yield lang.startsWith('ar')
          ? '*لم يتم ضبط مفتاح OpenRouter. افتح الإعدادات ← المفاتيح.*'
          : '*OpenRouter API key not set. Open Settings → API keys.*';
      return;
    }

    final order = <String>[
      if (startModel >= 0 && startModel < modelChain.length)
        modelChain[startModel],
      ...modelChain.where((m) => m != modelChain[startModel]),
    ];

    Object? lastError;
    for (var i = 0; i < order.length; i++) {
      final model = order[i];
      var emitted = false;
      try {
        await for (final chunk in _streamOne(model, labelSentence,
            moondreamAnalysis: moondreamAnalysis,
            predictions: predictions,
            telemetry: telemetry,
            lang: lang)) {
          emitted = true;
          lastChainIndex = modelChain.indexOf(model);
          yield chunk;
        }
        if (emitted) return; // this model delivered — done
        lastError = 'empty stream from $model';
      } catch (e) {
        lastError = e;
        log('[OpenRouter] $model failed: $e — trying next fallback…');
      }
      if (!emitted) {
        log('[OpenRouter] falling back ($i failed): $lastError');
      }
    }
    // Whole chain failed.
    yield lang.startsWith('ar')
        ? '*تعذّر الوصول إلى نموذج العرض. تحقق من الاتصال بالمحاولة مجددًا.*'
        : '*Could not reach any presentation model. Check connectivity and '
            'retry.*';
  }

  /// Single-model SSE stream. Throws on HTTP errors so the chain can
  /// fall through to the next model.
  Stream<String> _streamOne(
    String model,
    String labelSentence, {
    String? moondreamAnalysis,
    List<(String, double)>? predictions,
    String? telemetry,
    required String lang,
  }) async* {
    final request = http.Request('POST', Uri.parse(endpoint))
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
            moondreamAnalysis: moondreamAnalysis,
            predictions: predictions,
            telemetry: telemetry,
            lang: lang,
          )},
        ],
      });

    final client = clientFactory?.call() ?? http.Client();
    try {
      final streamed = await client.send(request).timeout(
            const Duration(seconds: 20),
            onTimeout: () => throw TimeoutException(
                'OpenRouter connect: $model', const Duration(seconds: 20)),
          );
      if (streamed.statusCode != 200) {
        final body = await streamed.stream.bytesToString();
        throw HttpExceptionWithBody(streamed.statusCode, body);
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
          // Null-safe: usage-only tail chunks carry an EMPTY choices list.
          final choices = json['choices'] as List?;
          final delta = (choices != null && choices.isNotEmpty)
              ? (choices[0]?['delta']?['content']) as String?
              : null;
          if (delta != null && delta.isNotEmpty) yield delta;

          // Final chunk carries usage incl. reasoning token count. Both
          // key casings seen in the wild are accepted:
          //   OpenRouter camelCase: usage.completionTokensDetails.reasoningTokens
          //   OpenAI snake_case:    usage.completion_tokens_details.reasoning_tokens
          final usage = json['usage'];
          if (usage is Map<String, dynamic>) {
            final details = (usage['completionTokensDetails'] ??
                    usage['completion_tokens_details'])
                as Map<String, dynamic>?;
            final rt = (details?['reasoningTokens'] ??
                    details?['reasoning_tokens']) as num?;
            if (rt != null && rt > 0) lastReasoningTokens = rt.toInt();
          }
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
          'العناصر والمركبات الكيميائية. نموذج الرؤية موندريم ٣ قد حصل على '
          'نتائج التحليل، ومهمتك فقط: صياغة النتائج في لغة عربية واضحة '
          'وقابلة للنطق الصوتي، بجُمل قصيرة، بدون رموز أو تنسيق معقد. اذكر '
          'حالة المادة (صلب/سائل/غاز) والتقديرات المئوية إن وُجدت، وحدد '
          'بوضوح في سطر مستقل يبدأ بـ "تحذير:" إذا كانت المادة خطرة (سامة، '
          'حارقة، كاوية، قابلة للانفجار). لا تخترع بيانات غير موجودة.';
    }
    return 'You are the voice assistant of "SpectruLenPor" smart glasses for '
        'spectrum analysis and detection of chemical elements and compounds. '
        'The Moondream3 vision model has ALREADY produced the analysis; your '
        'only job is to present it: clear, spoken-friendly language, short '
        'sentences, no heavy markdown. State the state of matter '
        '(solid/liquid/gas) and percentage estimates when available. If the '
        'material is hazardous (toxic, flammable, corrosive, explosive), add '
        'one standalone line starting with "Warning:" and say what to do. '
        'Never invent data that is not in the input.';
  }

  String _userPrompt({
    required String labelSentence,
    String? moondreamAnalysis,
    List<(String, double)>? predictions,
    String? telemetry,
    required String lang,
  }) {
    final buf = StringBuffer();
    if (lang.startsWith('ar')) {
      buf.writeln('نتيجة النموذج المتخصص: $labelSentence');
      if (moondreamAnalysis != null && moondreamAnalysis.isNotEmpty) {
        buf.writeln('تحليل موندريم ٣: $moondreamAnalysis');
      }
      if (predictions != null && predictions.isNotEmpty) {
        buf.writeln('أعلى الاحتمالات: ${predictions.map((p) => "${p.$1} ${(p.$2 * 100).toStringAsFixed(0)}%").join('، ')}');
      }
      if (telemetry != null) buf.writeln(telemetry);
      buf.writeln();
      buf.writeln('اكتب فقرة قصيرة (٣-٥ جمل) تشرح ما المادة، حالتها، '
          'واستخدامها أو خطرها.');
    } else {
      buf.writeln('Specialized model result: $labelSentence');
      if (moondreamAnalysis != null && moondreamAnalysis.isNotEmpty) {
        buf.writeln('Moondream3 analysis: $moondreamAnalysis');
      }
      if (predictions != null && predictions.isNotEmpty) {
        buf.writeln('Top predictions: ${predictions.map((p) => "${p.$1} ${(p.$2 * 100).toStringAsFixed(0)}%").join(', ')}');
      }
      if (telemetry != null) buf.writeln(telemetry);
      buf.writeln();
      buf.writeln('Write a short paragraph (3-5 sentences): what the '
          'substance/object is, its state of matter, one practical note or '
          'use, and the hazard line if applicable. Then a "## Explore" '
          'section with 3 related terms.');
    }
    return buf.toString();
  }
// CORRECTED OpenRouter additions — replace the broken additions block.
// This block goes INSIDE the OpenRouterService class, before its final '}'.

  // ---------------------------------------------------------------------------
  // v4.0 — SCIENTIFIC CONTEXT WRITER + CHAT MODE
  // ---------------------------------------------------------------------------

  /// Write the first scientific context for the captured image. Auto-narrated
  /// by the caller via fish-audio TTS (cloud) or Android native TTS (fallback).
  Stream<String> writeScientificContext({
    required String moondreamSummary,
    required String selectedLabel,
    String lang = 'en',
  }) async* {
    final isAr = lang.startsWith('ar');
    final prompt = isAr
        ? buildArabicContextPrompt(moondreamSummary, selectedLabel)
        : buildEnglishContextPrompt(moondreamSummary, selectedLabel);

    yield* streamChat(
      history: [
        ChatMessage(role: 'user', content: prompt, at: DateTime.now()),
      ],
      anchor: null,
      lang: lang,
    );
  }

  String buildArabicContextPrompt(String moondreamSummary, String selectedLabel) {
    final parts = <String>[
      'أنت عالم وكاتب علمي. حصلت على تحليل Moondream المهيكل التالي:',
      '',
      moondreamSummary,
      '',
      'المكون المحدد من قبل المستخدم هو: "$selectedLabel".',
      '',
      'اكتب سياقاً علمياً شاملاً عن $selectedLabel. يجب أن يشمل:',
      '1. ما هو $selectedLabel؟ تعريف علمي دقيق.',
      '2. ما المكونات الكيميائية أو الفيزيائية فيه؟ صيغة كيميائية إن وجدت.',
      '3. كيف يتشكل $selectedLabel؟ (طبيعياً، صناعياً، في المعمل؟)',
      '4. ما هي خصائصه (الكثافة، درجة الانصهار، درجة الغليان، اللون، الرائحة؟)',
      '5. ما هي استخداماته الشائعة؟',
      '6. أي مخاطر سلامة يجب أن يعرفها الطالب؟',
      '7. سياق المشهد: ما الأشياء المحيطة بـ$selectedLabel ولماذا قد تكون مهمة؟',
      '',
      'كن علمياً، مفصلاً، ودقيقاً. استخدم تنسيق Markdown. لا تخمن — إذا لم تعرف قل ذلك.',
    ];
    return parts.join('\n');
  }

  String buildEnglishContextPrompt(String moondreamSummary, String selectedLabel) {
    final parts = <String>[
      'You are a scientist and science writer. You received the following Moondream structured analysis:',
      '',
      moondreamSummary,
      '',
      'The user-selected component is: "$selectedLabel".',
      '',
      'Write a comprehensive scientific context about $selectedLabel. It must cover:',
      '1. What is $selectedLabel? Precise scientific definition.',
      '2. What are its chemical or physical components? Chemical formula if applicable.',
      '3. How is $selectedLabel formed? (naturally, industrially, in the lab?)',
      '4. What are its properties (density, melting point, boiling point, color, odor?)',
      '5. What are its common uses?',
      '6. Any safety hazards the student should know about?',
      '7. Scene context: what objects surround $selectedLabel and why might they be relevant?',
      '',
      "Be scientific, detailed, and accurate. Use Markdown formatting. Do not guess - if you don't know, say so.",
    ];
    return parts.join('\n');
  }

  /// Streaming chat mode — walks the gemma → inkling → nemotron chain.
  Stream<String> streamChat({
    required List<ChatMessage> history,
    required AnchorContext? anchor,
    ConversationContext? runningContext,
    String lang = 'en',
  }) async* {
    final messages = <Map<String, String>>[];
    final systemParts = <String>[];
    if (anchor != null) systemParts.add(anchor.toSystemPrompt(lang: lang));
    if (runningContext != null) systemParts.add(runningContext.toSystemPromptBlock(lang: lang));
    if (systemParts.isNotEmpty) {
      messages.add({'role': 'system', 'content': systemParts.join('\n\n---\n\n')});
    }
    for (final m in history) {
      messages.add({'role': m.role, 'content': m.content});
    }
    yield* streamRawMessages(messages, lang: lang);
  }

  /// Low-level stream — accepts raw OpenRouter-format messages and walks the
  /// fallback chain (gemma → inkling → nemotron) until one model streams.
  Stream<String> streamRawMessages(
    List<Map<String, String>> messages, {
    String lang = 'en',
  }) async* {
    if (!isConfigured) {
      yield lang.startsWith('ar')
          ? '*لم يتم ضبط مفتاح OpenRouter. افتح الإعدادات ← المفاتيح.*'
          : '*OpenRouter API key not set. Open Settings → API keys.*';
      return;
    }
    var lastError = '';
    for (var i = 0; i < modelChain.length; i++) {
      final model = modelChain[i];
      try {
        final emitted = <String>[];
        await for (final chunk in _streamRawOne(model, messages)) {
          emitted.add(chunk);
          yield chunk;
        }
        if (emitted.isNotEmpty) {
          lastChainIndex = i;
          return;
        }
        lastError = 'empty stream from $model';
      } catch (e) {
        lastError = '$model: $e';
        log('[OpenRouter chat] $lastError — trying next fallback…');
      }
    }
    yield lang.startsWith('ar')
        ? '*تعذّر الوصول لأي نموذج عرض. تحقق من الاتصال والمفاتيح. ($lastError)*'
        : '*Could not reach any presentation model. Check connectivity and keys. ($lastError)*';
  }

  /// Single-model SSE stream with raw messages payload.
  Stream<String> _streamRawOne(
    String model,
    List<Map<String, String>> messages,
  ) async* {
    final client = clientFactory?.call() ?? http.Client();
    try {
      final request = http.Request('POST', Uri.parse(endpoint));
      request.headers['Authorization'] = 'Bearer $apiKey';
      request.headers['Content-Type'] = 'application/json';
      request.headers['HTTP-Referer'] = 'https://spectraglass.app';
      request.headers['X-Title'] = 'SpectruLenPor';
      request.body = jsonEncode({
        'model': model,
        'messages': messages,
        'stream': true,
        'reasoning': {'exclude': false},
      });
      final streamed = await client.send(request);
      if (streamed.statusCode != 200) {
        throw HttpExceptionWithBody(
            streamed.statusCode, await streamed.stream.bytesToString());
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
          final choices = json['choices'] as List?;
          final delta = (choices != null && choices.isNotEmpty)
              ? (choices[0]?['delta']?['content']) as String?
              : null;
          if (delta != null && delta.isNotEmpty) yield delta;
          // Capture reasoning tokens for diagnostics.
          final usage = json['usage'];
          if (usage is Map<String, dynamic>) {
            final details = (usage['completionTokensDetails'] ??
                    usage['completion_tokens_details'])
                as Map<String, dynamic>?;
            final rt = (details?['reasoningTokens'] ??
                    details?['reasoning_tokens']) as num?;
            if (rt != null && rt > 0) lastReasoningTokens = rt.toInt();
          }
        } catch (e) {
          log('SSE parse (chat): $e');
        }
      }
    } finally {
      client.close();
    }
  }

  // ---------------------------------------------------------------------------
  // v5.1 — SCIENTIFIC CONTEXT WRITER WITH WIKIPEDIA + DOCS CITATIONS
  // ---------------------------------------------------------------------------

  /// v5.1 — Like [writeScientificContext] but pre-fetches sources from
  /// Wikipedia + bundled docs, includes them in the LLM prompt, AND asks
  /// the LLM to use inline [n] citations like Google AI Overviews.
  ///
  /// Returns an [AnnotatedMessage] with the markdown body + the list of
  /// citations (numbered [1], [2], etc.).
  Future<AnnotatedMessage> writeScientificContextWithCitations({
    required String moondreamSummary,
    required String selectedLabel,
    String lang = 'en',
  }) async {
    // 1. Pre-fetch sources — bundled docs first, then Wikipedia fallback.
    final docs = await DocsSearchService.instance.search(selectedLabel, startIndex: 1);
    var nextIdx = docs.isEmpty ? 1 : docs.last.index + 1;
    final wiki = await WikipediaService.instance.searchWithSummaries(selectedLabel, limit: 3);
    final wikiCitations = wiki.map((w) => Citation.fromWiki(nextIdx++, w)).toList();
    final sources = [...docs, ...wikiCitations];

    // 2. Build the system prompt with sources.
    final sourcesBlock = sources.asMap().entries.map((e) {
      final c = e.value;
      return '[${c.index}] ${c.title} — ${c.snippet.isNotEmpty ? c.snippet.substring(0, c.snippet.length.clamp(0, 200)) : ""}';
    }).join('\n');

    // 3. Build the user prompt — ask LLM to use inline [n] citations.
    final isAr = lang.startsWith('ar');
    final userPrompt = isAr
        ? buildArabicContextPromptWithCitations(moondreamSummary, selectedLabel, sourcesBlock)
        : buildEnglishContextPromptWithCitations(moondreamSummary, selectedLabel, sourcesBlock);

    // 4. Stream the LLM response.
    final buffer = StringBuffer();
    await for (final chunk in streamChat(
      history: [ChatMessage(role: 'user', content: userPrompt, at: DateTime.now())],
      anchor: null,
      lang: lang,
    )) {
      buffer.write(chunk);
    }

    // 5. Fact-check the output — flag verified / unverified claims.
    final factResult = await FactCheckerService.instance.check(
      llmMarkdown: buffer.toString(),
      sources: sources,
    );

    return AnnotatedMessage(
      body: factResult.annotatedMarkdown,
      citations: sources,
    );
  }

  String buildArabicContextPromptWithCitations(String moondreamSummary, String selectedLabel, String sourcesBlock) {
    final parts = <String>[
      'أنت عالم وكاتب علمي. حصلت على تحليل Moondream المهيكل التالي:',
      '',
      moondreamSummary,
      '',
      'المكون المحدد من قبل المستخدم هو: "$selectedLabel".',
      '',
      'المصادر المتاحة لك (استخدم الأرقام [n] كمراجع داخلية في إجابتك):',
      sourcesBlock,
      '',
      'اكتب سياقاً علمياً شاملاً عن $selectedLabel. يجب أن يشمل:',
      '1. ما هو $selectedLabel؟ تعريف علمي دقيق. استخدم [n] للمراجع.',
      '2. ما المكونات الكيميائية أو الفيزيائية فيه؟ صيغة كيميائية إن وجدت.',
      '3. كيف يتشكل $selectedLabel؟ (طبيعياً، صناعياً، في المعمل؟)',
      '4. ما هي خصائصه (الكثافة، درجة الانصهار، درجة الغليان، اللون، الرائحة؟)',
      '5. ما هي استخداماته الشائعة؟',
      '6. أي مخاطر سلامة يجب أن يعرفها الطالب؟',
      '7. سياق المشهد: ما الأشياء المحيطة بـ$selectedLabel ولماذا قد تكون مهمة؟',
      '',
      'تنسيق: Markdown. كل ادعاء علمي يجب أن يكون مذكوراً بمرجع [n] في نفس السطر.',
      'إذا لم تجد مرجعاً لادعاء معين، لا تخترع مرجعاً — فقط اتركه بدون [n].',
      'كن علمياً، مفصلاً، ودقيقاً. لا تخمن.',
    ];
    return parts.join('\n');
  }

  String buildEnglishContextPromptWithCitations(String moondreamSummary, String selectedLabel, String sourcesBlock) {
    final parts = <String>[
      'You are a scientist and science writer. You received the following Moondream structured analysis:',
      '',
      moondreamSummary,
      '',
      'The user-selected component is: "$selectedLabel".',
      '',
      'Available sources (use the [n] numbers as inline citations in your answer):',
      sourcesBlock,
      '',
      'Write a comprehensive scientific context about $selectedLabel. It must cover:',
      '1. What is $selectedLabel? Precise scientific definition — cite [n].',
      '2. What are its chemical or physical components? Chemical formula if applicable.',
      '3. How is $selectedLabel formed? (naturally, industrially, in the lab?)',
      '4. What are its properties (density, melting point, boiling point, color, odor?)',
      '5. What are its common uses?',
      '6. Any safety hazards the student should know about?',
      '7. Scene context: what objects surround $selectedLabel and why might they be relevant?',
      '',
      'Formatting: Markdown. Every factual claim MUST be cited with [n] inline at the end of the sentence.',
      'Do not invent citations — if no source covers a claim, leave it without [n].',
      'Be scientific, detailed, and accurate. Do not guess.',
    ];
    return parts.join('\n');
  }

}

class HttpExceptionWithBody implements Exception {
  HttpExceptionWithBody(this.statusCode, this.body);
  final int statusCode;
  final String body;
  @override
  String toString() =>
      'HTTP $statusCode: ${body.length > 140 ? '${body.substring(0, 140)}…' : body}';
}
