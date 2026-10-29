import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import '../models/chat_message.dart';
import '../models/citation.dart';
import '../models/conversation_context.dart';
import 'docs_search_service.dart';
import 'fact_checker_service.dart';
import 'internal_db_service.dart';

/// OpenRouter text + reasoning presentation tier.
///
/// Fallback chain:
///   1. `nvidia/nemotron-3.5-super-vl:free`   (native image / vision / video)
///   2. `google/gemma-4-26b-a4b-it:free`
///   3. `liquid/inkling-small:free`
class OpenRouterService {
  OpenRouterService({
    String? apiKey,
    http.Client Function()? clientFactory,
  })  : apiKey = apiKey ?? defaultApiKey,
        _clientFactory = clientFactory ?? http.Client.new;

  static const String defaultApiKey =
      String.fromEnvironment('OPENROUTER_LLM_KEY');

  static String get endpoint => kIsWeb
      ? '/openrouter/api/v1/chat/completions'
      : 'https://openrouter.ai/api/v1/chat/completions';

  static const List<String> modelChain = <String>[
    'nvidia/nemotron-3.5-super-vl:free',
    'google/gemma-4-26b-a4b-it:free',
    'liquid/inkling-small:free',
  ];

  String apiKey;
  final http.Client Function() _clientFactory;

  int lastChainIndex = 0;
  String get lastModelUsed =>
      modelChain[lastChainIndex.clamp(0, modelChain.length - 1)];

  int? lastReasoningTokens;
  bool get isConfigured => apiKey.trim().isNotEmpty;

  List<String> _orderedChain(int startModel) {
    final safeStart = startModel.clamp(0, modelChain.length - 1);
    return <String>[
      ...modelChain.sublist(safeStart),
      ...modelChain.sublist(0, safeStart),
    ];
  }

  Stream<String> streamAnalysis({
    required String labelSentence,
    String? moondreamAnalysis,
    List<(String, double)>? predictions,
    String? telemetry,
    String lang = 'en',
    int startModel = 0,
  }) async* {
    lastReasoningTokens = null;

    if (!isConfigured) {
      yield lang.startsWith('ar')
          ? '*لم يتم ضبط مفتاح OpenRouter. افتح الإعدادات ← المفاتيح.*'
          : '*OpenRouter API key not set. Open Settings → API keys.*';
      return;
    }

    final systemPrompt = _systemPrompt(lang);
    final userPrompt = _buildUserPrompt(
      labelSentence: labelSentence,
      moondreamAnalysis: moondreamAnalysis,
      predictions: predictions,
      telemetry: telemetry,
      lang: lang,
    );

    final order = _orderedChain(startModel);
    var lastError = '';
    for (var i = 0; i < order.length; i++) {
      final model = order[i];
      try {
        var emitted = false;
        await for (final chunk in _streamOne(
          model: model,
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
        )) {
          emitted = true;
          lastChainIndex = modelChain.indexOf(model);
          yield chunk;
        }
        if (emitted) return;
        lastError = 'empty stream from $model';
      } catch (e) {
        lastError = '$model: $e';
        log('[OpenRouter] $lastError — trying next fallback…');
      }
    }

    yield lang.startsWith('ar')
        ? '*تعذّر الوصول لأي نموذج عرض. تحقق من الاتصال والمفاتيح. ($lastError)*'
        : '*Could not reach any presentation model. Check connectivity and keys. ($lastError)*';
  }

  Stream<String> _streamOne({
    required String model,
    required String systemPrompt,
    required String userPrompt,
  }) async* {
    final request = http.Request('POST', Uri.parse(endpoint))
      ..headers.addAll({
        'Authorization': 'Bearer ${apiKey.trim()}',
        'Content-Type': 'application/json',
        'HTTP-Referer': 'https://github.com/abdou-da0wew/SpectrulenPor',
        'X-Title': 'SpectruLenPor',
      })
      ..body = jsonEncode({
        'model': model,
        'stream': true,
        'temperature': 0.3,
        'max_tokens': 420,
        'reasoning': {'exclude': true},
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userPrompt},
        ],
      });

    yield* _consumeSse(request, model, timeoutSeconds: 18);
  }

  String _systemPrompt(String lang) {
    if (lang.startsWith('ar')) {
      return 'أنت "سبكترو لِن بور"، مساعد نظارات علمية ذكية. نموذج الرؤية '
          'المتخصص (Moondream3) قام بتحليل الصورة بالفعل؛ دورك هو صياغة '
          'التحليل بأسلوب واضح وموجز ومناسب للنطق الصوتي بالعربية الفصحى. '
          'اذكر حالة المادة إن ظهرت، وأضف سطر تحذير يبدأ بـ "تحذير:" فقط عند '
          'وجود خطر حقيقي (مادة سامة، حارقة، قابلة للاشتعال، أشعة قوية). '
          'اختم بقسم "## استكشف" فيه ٣ مصطلحات ذات صلة.';
    }
    return 'You are SpectruLenPor, a smart scientific glasses assistant. '
        'A specialized vision model (Moondream3) has ALREADY analyzed the '
        'frame; your job is to present its findings clearly, concisely and '
        'naturally for spoken audio. State the matter phase if relevant, '
        'include a line starting with "Warning:" ONLY when an actual hazard '
        'is plausible, and finish with a short "## Explore" bullet list of '
        '3 related concepts. Never invent readings that were not provided.';
  }

  String _buildUserPrompt({
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
        buf.writeln(
          'أعلى الاحتمالات: ${predictions.map((p) => "${p.$1} ${(p.$2 * 100).toStringAsFixed(0)}%").join('، ')}',
        );
      }
      if (telemetry != null) buf.writeln(telemetry);
      buf.writeln();
      buf.writeln(
        'اكتب فقرة قصيرة (٣-٥ جمل) تشرح ما المادة، حالتها، واستخدامها أو خطرها.',
      );
    } else {
      buf.writeln('Specialized model result: $labelSentence');
      if (moondreamAnalysis != null && moondreamAnalysis.isNotEmpty) {
        buf.writeln('Moondream3 analysis: $moondreamAnalysis');
      }
      if (predictions != null && predictions.isNotEmpty) {
        buf.writeln(
          'Top predictions: ${predictions.map((p) => "${p.$1} ${(p.$2 * 100).toStringAsFixed(0)}%").join(', ')}',
        );
      }
      if (telemetry != null) buf.writeln(telemetry);
      buf.writeln();
      buf.writeln(
        'Write a short paragraph (3-5 sentences): what the substance/object is, '
        'its state of matter, one practical note or use, and the hazard line if '
        'applicable. Then a "## Explore" section with 3 related terms.',
      );
    }
    return buf.toString();
  }

  // ---------------------------------------------------------------------------
  // SCIENTIFIC CONTEXT WRITER + CHAT MODE + CITATIONS + FACT-CHECKING
  // ---------------------------------------------------------------------------

  Stream<String> writeScientificContext({
    required String moondreamSummary,
    required String selectedLabel,
    String lang = 'en',
    int startModel = 0,
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
      startModel: startModel,
    );
  }

  String buildArabicContextPrompt(
      String moondreamSummary, String selectedLabel) {
    return [
      'أنت عالم وكاتب علمي. حصلت على تحليل Moondream المهيكل التالي:',
      '',
      moondreamSummary,
      '',
      'المكون المحدد من قبل المستخدم هو: "$selectedLabel".',
      '',
      'اكتب سياقاً علمياً شاملاً عن $selectedLabel يشمل التعريف، المكونات الكيميائية/الفيزيائية، '
          'التكوين، الخصائص، الاستخدامات، مخاطر السلامة إن وجدت، وسياق المشهد.',
      'استخدم تنسيق Markdown ولا تخمن.',
    ].join('\n');
  }

  String buildEnglishContextPrompt(
      String moondreamSummary, String selectedLabel) {
    return [
      'You are a scientist and science writer. You received the following Moondream structured analysis:',
      '',
      moondreamSummary,
      '',
      'The user-selected component is: "$selectedLabel".',
      '',
      'Write a comprehensive scientific context about $selectedLabel covering its definition, '
          'chemical/physical composition, formation, properties, uses, safety notes if applicable, '
          'and surrounding scene context. Use Markdown formatting and do not guess.',
    ].join('\n');
  }

  /// Streaming chat mode — embeds BOTH [anchor] AND [runningContext] into EVERY
  /// system prompt, plus optional retrieved [turnCitations] for inline `[n]`
  /// Google-AI-Overviews-style source grounding.
  Stream<String> streamChat({
    required List<ChatMessage> history,
    required AnchorContext? anchor,
    ConversationContext? runningContext,
    List<Citation> turnCitations = const [],
    String lang = 'en',
    int startModel = 0,
  }) async* {
    final messages = <Map<String, String>>[];
    final systemParts = <String>[];
    if (anchor != null) systemParts.add(anchor.toSystemPrompt(lang: lang));
    if (runningContext != null) {
      systemParts.add(runningContext.toSystemPromptBlock(lang: lang));
    }
    if (turnCitations.isNotEmpty) {
      final srcLines = turnCitations
          .map((c) => '[${c.index}] ${c.title}: ${c.snippet}')
          .join('\n');
      systemParts.add(
        lang.startsWith('ar')
            ? '## المصادر المرجعية المتاحة لهذه الرسالة (استشهد بالأرقام [n] لكل معلومة علمية، ولا تخترع مراجع)\n$srcLines'
            : '## Grounded Reference Sources for This Turn (cite [n] inline at the end of factual claims; never invent citations)\n$srcLines',
      );
    }
    if (systemParts.isNotEmpty) {
      messages.add({
        'role': 'system',
        'content': systemParts.join('\n\n---\n\n'),
      });
    }
    for (final m in history) {
      messages.add({'role': m.role, 'content': m.content});
    }
    yield* streamRawMessages(messages, lang: lang, startModel: startModel);
  }

  Stream<String> streamRawMessages(
    List<Map<String, String>> messages, {
    String lang = 'en',
    int startModel = 0,
  }) async* {
    if (!isConfigured) {
      yield lang.startsWith('ar')
          ? '*لم يتم ضبط مفتاح OpenRouter. افتح الإعدادات ← المفاتيح.*'
          : '*OpenRouter API key not set. Open Settings → API keys.*';
      return;
    }

    final order = _orderedChain(startModel);
    var lastError = '';
    for (var i = 0; i < order.length; i++) {
      final model = order[i];
      try {
        var emitted = false;
        await for (final chunk in _streamRawOne(model, messages)) {
          emitted = true;
          lastChainIndex = modelChain.indexOf(model);
          yield chunk;
        }
        if (emitted) return;
        lastError = 'empty stream from $model';
      } catch (e) {
        lastError = '$model: $e';
        log('[OpenRouter chat] $lastError — trying next fallback…');
        unawaited(InternalDatabaseService.instance.logWarn(
          'OpenRouter',
          'Model fallback triggered: $lastError',
        ));
      }
    }
    yield lang.startsWith('ar')
        ? '*تعذّر الوصول لأي نموذج عرض. تحقق من الاتصال والمفاتيح. ($lastError)*'
        : '*Could not reach any presentation model. Check connectivity and keys. ($lastError)*';
  }

  Stream<String> _streamRawOne(
    String model,
    List<Map<String, String>> messages,
  ) async* {
    final request = http.Request('POST', Uri.parse(endpoint))
      ..headers.addAll({
        'Authorization': 'Bearer ${apiKey.trim()}',
        'Content-Type': 'application/json',
        'HTTP-Referer': 'https://github.com/abdou-da0wew/SpectrulenPor',
        'X-Title': 'SpectruLenPor',
      })
      ..body = jsonEncode({
        'model': model,
        'messages': messages,
        'stream': true,
        'reasoning': {'exclude': false},
      });
    yield* _consumeSse(request, model, timeoutSeconds: 25);
  }

  Stream<String> _consumeSse(
    http.Request request,
    String model, {
    required int timeoutSeconds,
  }) async* {
    final client = _clientFactory();
    try {
      final streamed = await client.send(request).timeout(
            Duration(seconds: timeoutSeconds),
            onTimeout: () =>
                throw TimeoutException('OpenRouter connect ($model)'),
          );
      if (streamed.statusCode != 200) {
        final body = await streamed.stream.bytesToString();
        throw HttpExceptionWithBody(streamed.statusCode, body);
      }

      final lines = streamed.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final raw in lines) {
        if (!raw.startsWith('data:')) continue;
        final payload = raw.substring(5).trim();
        if (payload.isEmpty || payload == '[DONE]') {
          if (payload == '[DONE]') break;
          continue;
        }
        Map<String, dynamic> json;
        try {
          json = jsonDecode(payload) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        final usage = json['usage'];
        if (usage is Map<String, dynamic>) {
          final details = usage['completion_tokens_details'];
          if (details is Map<String, dynamic>) {
            final rt = details['reasoning_tokens'];
            if (rt is int) lastReasoningTokens = rt;
          }
        }
        final choices = json['choices'];
        if (choices is List && choices.isNotEmpty) {
          final first = choices.first;
          if (first is Map<String, dynamic>) {
            final delta = first['delta'];
            if (delta is Map<String, dynamic>) {
              final content = delta['content'];
              if (content is String && content.isNotEmpty) {
                yield content;
              }
            }
          }
        }
      }
    } finally {
      client.close();
    }
  }

  /// Writes the initial grounded scientific context with multi-source `[n]`
  /// citations (118+ elements, 110 compounds, GHS safety, PubChem, Wikipedia,
  /// Web Search) AND runs `FactCheckerService.check`.
  Future<AnnotatedMessage> writeScientificContextWithCitations({
    required String moondreamSummary,
    required String selectedLabel,
    String lang = 'en',
    int startModel = 0,
    DocsSearchMode searchMode = DocsSearchMode.semantic,
    String? traceId,
  }) async {
    final tid = traceId ?? InternalDatabaseService.instance.startTraceId('ctx');

    // 1. Pre-fetch sources using the configured search mode.
    final sources = await InternalDatabaseService.instance.traceAsync(
      'docs.search.${searchMode.name}',
      () => DocsSearchService.instance.searchByMode(
        selectedLabel,
        mode: searchMode,
        startIndex: 1,
        limit: 6,
        lang: lang,
      ),
      traceId: tid,
      attributes: {'query': selectedLabel, 'mode': searchMode.name},
    );

    // 2. Build citation-aware prompt.
    final isAr = lang.startsWith('ar');
    final sourcesBlock = sources.isEmpty
        ? '(no external sources matched — rely on verified scientific knowledge)'
        : sources.map((c) => '[${c.index}] ${c.title}: ${c.snippet}').join('\n');

    final prompt = isAr
        ? buildArabicContextPromptWithCitations(
            moondreamSummary, selectedLabel, sourcesBlock)
        : buildEnglishContextPromptWithCitations(
            moondreamSummary, selectedLabel, sourcesBlock);

    // 3. Stream LLM response.
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final sw = Stopwatch()..start();
    final buf = StringBuffer();
    await for (final chunk in streamChat(
      history: [
        ChatMessage(role: 'user', content: prompt, at: DateTime.now()),
      ],
      anchor: null,
      lang: lang,
      startModel: startModel,
    )) {
      buf.write(chunk);
    }
    sw.stop();
    unawaited(InternalDatabaseService.instance.recordSpan(
      traceId: tid,
      spanName: 'openrouter.scientificContext',
      startedAtMs: startedAt,
      durationMs: sw.elapsedMilliseconds,
      status: 'ok',
      attributes: {'model': lastModelUsed, 'chars': buf.length},
    ));

    final rawMarkdown = buf.toString();

    // 4. Fact-check every extracted claim against the sources.
    final fcResult = await InternalDatabaseService.instance.traceAsync(
      'fact_checker.check',
      () => FactCheckerService.instance.check(
        llmMarkdown: rawMarkdown,
        sources: sources,
      ),
      traceId: tid,
    );

    return AnnotatedMessage(
      body: fcResult.annotatedMarkdown,
      citations: sources,
      verifiedCount: fcResult.verifiedCount,
      unverifiedCount: fcResult.unverifiedCount,
    );
  }

  String buildArabicContextPromptWithCitations(
    String moondreamSummary,
    String selectedLabel,
    String sourcesBlock,
  ) {
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
      '6. أي مخاطر سلامة حقيقية يجب أن يعرفها الطالب؟ (اذكرها فقط إن وجدت فعلاً)',
      '7. سياق المشهد: ما الأشياء المحيطة بـ$selectedLabel ولماذا قد تكون مهمة؟',
      '',
      'تنسيق: Markdown. كل ادعاء علمي يجب أن يكون مذكوراً بمرجع [n] في نفس السطر.',
      'إذا لم تجد مرجعاً لادعاء معين، لا تخترع مرجعاً — فقط اتركه بدون [n].',
      'كن علمياً، مفصلاً، ودقيقاً. لا تخمن.',
    ];
    return parts.join('\n');
  }

  String buildEnglishContextPromptWithCitations(
    String moondreamSummary,
    String selectedLabel,
    String sourcesBlock,
  ) {
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
      '6. Any real safety hazards the student should know about? (mention only when genuinely hazardous)',
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
