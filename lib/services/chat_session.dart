import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/captured_frames.dart';
import '../models/chat_message.dart';
import '../models/citation.dart';
import '../models/conversation_context.dart';
import 'docs_search_service.dart';
import 'fact_checker_service.dart';
import 'internal_db_service.dart';
import 'moondream_service.dart';
import 'openrouter_service.dart';

/// Anchored chat session with:
///   1. Immutable/updatable visual anchor ([CapturedFrames] + [MoondreamStructuredAnalysis] + initial report)
///   2. Auto-updating structured [ConversationContext] embedded into EVERY LLM system prompt
///   3. Automatic in-app Docs + Wikipedia + PubChem + Web citations (`[n]`) & `FactCheckerService` on every turn
///   4. Automatic persistence of session metadata, messages, citations, and context deltas in [InternalDatabaseService]
class ChatSession extends ChangeNotifier {
  final String sessionId;
  AnchorContext _anchor;
  ConversationContext _runningContext;
  final List<ChatMessage> _history = [];
  final OpenRouterService _openRouter;
  DocsSearchMode searchMode;

  bool _streaming = false;
  bool get isStreaming => _streaming;

  AnchorContext get anchor => _anchor;
  ConversationContext get runningContext => _runningContext;
  List<ChatMessage> get history => List.unmodifiable(_history);

  final StreamController<String> _streamCtl =
      StreamController<String>.broadcast();
  Stream<String> get responseStream => _streamCtl.stream;

  ChatSession({
    String? sessionId,
    required CapturedFrames frames,
    required MoondreamStructuredAnalysis moondreamAnalysis,
    required String firstLlmContext,
    required OpenRouterService openRouter,
    List<Citation> initialCitations = const [],
    int initialVerifiedCount = 0,
    int initialUnverifiedCount = 0,
    String lang = 'en',
    this.searchMode = DocsSearchMode.semantic,
    bool persistToDb = true,
  })  : sessionId = sessionId ??
            InternalDatabaseService.instance.startTraceId('session'),
        _anchor = AnchorContext(
          selectedLabel: frames.selectedBox.label,
          moondreamSummary: moondreamAnalysis.toMergedSummary(),
          firstLlmContext: firstLlmContext,
          capturedAt: frames.capturedAt,
        ),
        _runningContext = ConversationContext(
          objectIdentified: frames.selectedBox.label,
          stateOfMatter: moondreamAnalysis.stateOfMatter,
          hazards: moondreamAnalysis.hazards,
          sceneContext: moondreamAnalysis.whatsAround,
          commonUses: moondreamAnalysis.howItsUsed.trim().isNotEmpty
              ? [moondreamAnalysis.howItsUsed.trim()]
              : const [],
          labFindings: moondreamAnalysis.whatItIs.trim().isNotEmpty
              ? moondreamAnalysis.whatItIs.trim()
              : moondreamAnalysis.caption.trim(),
          referencedEntities: [frames.selectedBox.label],
          lastUpdated: frames.capturedAt,
        ),
        _openRouter = openRouter {
    if (firstLlmContext.trim().isNotEmpty) {
      final (cleanedInitial, delta) =
          ConversationContext.extractFromResponse(firstLlmContext);
      if (delta != null) {
        _runningContext = _runningContext.merge(delta);
      }
      _history.add(
        ChatMessage(
          role: 'assistant',
          content: cleanedInitial,
          at: frames.capturedAt,
          citations: initialCitations,
          verifiedCount: initialVerifiedCount,
          unverifiedCount: initialUnverifiedCount,
        ),
      );
    }

    if (persistToDb) {
      unawaited(
        InternalDatabaseService.instance.saveChatSession(
          sessionId: this.sessionId,
          frames: frames,
          moondream: moondreamAnalysis,
          firstLlmContext: firstLlmContext,
          runningContext: _runningContext,
          messages: _history,
          locale: lang,
        ),
      );
    }
  }

  /// Restores a previously saved chat session from [InternalDatabaseService].
  factory ChatSession.fromHydrated({
    required HydratedChatRecord record,
    required OpenRouterService openRouter,
    DocsSearchMode searchMode = DocsSearchMode.semantic,
  }) {
    final s = ChatSession._restored(
      sessionId: record.summary.id,
      anchor: AnchorContext(
        selectedLabel: record.summary.selectedLabel,
        moondreamSummary: record.summary.moondreamAnalysis.toMergedSummary(),
        firstLlmContext: record.summary.firstLlmContext,
        capturedAt: record.summary.createdAt,
      ),
      runningContext: record.summary.runningContext,
      messages: record.messages,
      openRouter: openRouter,
      searchMode: searchMode,
    );
    return s;
  }

  ChatSession._restored({
    required this.sessionId,
    required AnchorContext anchor,
    required ConversationContext runningContext,
    required List<ChatMessage> messages,
    required OpenRouterService openRouter,
    required this.searchMode,
  })  : _anchor = anchor,
        _runningContext = runningContext,
        _openRouter = openRouter {
    _history.addAll(messages);
  }

  /// Appends a user note directly into the running [ConversationContext] so
  /// subsequent AI prompts incorporate it, and persists to the internal DB.
  Future<void> addUserNote(String note) async {
    final trimmed = note.trim();
    if (trimmed.isEmpty) return;
    _runningContext = _runningContext.merge(
      ConversationContext(userNotes: [trimmed]),
    );
    notifyListeners();
    await InternalDatabaseService.instance.putUserData(
      'note_${sessionId}_${DateTime.now().millisecondsSinceEpoch}',
      {'sessionId': sessionId, 'note': trimmed},
      category: 'chat_note',
    );
  }

  /// Sends a user message, retrieves relevant sources via [DocsSearchService],
  /// streams the grounded LLM reply, strips & merges `<context_update>`, runs
  /// [FactCheckerService], and persists both messages to [InternalDatabaseService].
  Future<void> sendUserMessage(
    String text, {
    String lang = 'en',
    int startModel = 0,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _streaming) return;

    final userMsg = ChatMessage(
      role: 'user',
      content: trimmed,
      at: DateTime.now(),
    );
    final userSeq = _history.length;
    _history.add(userMsg);
    _streaming = true;
    notifyListeners();

    unawaited(InternalDatabaseService.instance.appendChatMessage(
      sessionId: sessionId,
      seq: userSeq,
      message: userMsg,
      runningContext: _runningContext,
    ));
    unawaited(InternalDatabaseService.instance.recordActivity(
      'chat_message_sent',
      target: _anchor.selectedLabel,
      details: {'sessionId': sessionId, 'length': trimmed.length},
    ));

    final sw = Stopwatch()..start();
    final buffer = StringBuffer();
    try {
      // Retrieve grounded scientific sources for the question + anchored object.
      final combinedQuery = '${_anchor.selectedLabel} $trimmed';
      final sources = await DocsSearchService.instance.searchByMode(
        combinedQuery,
        mode: searchMode,
        startIndex: 1,
        limit: 5,
        lang: lang,
      );

      await for (final chunk in _openRouter.streamChat(
        history: _history,
        anchor: _anchor,
        runningContext: _runningContext,
        turnCitations: sources,
        lang: lang,
        startModel: startModel,
      )) {
        buffer.write(chunk);
        _streamCtl.add(buffer.toString());
      }
      sw.stop();

      final rawReply = buffer.toString();
      final (visibleReply, contextDelta) =
          ConversationContext.extractFromResponse(rawReply);

      if (contextDelta != null) {
        _runningContext = _runningContext.merge(contextDelta);
      }

      // Run fact-checking against retrieved sources when available.
      String finalMarkdown = visibleReply;
      int verified = 0;
      int unverified = 0;
      if (sources.isNotEmpty && visibleReply.isNotEmpty) {
        final fc = await FactCheckerService.instance.check(
          llmMarkdown: visibleReply,
          sources: sources,
        );
        finalMarkdown = fc.annotatedMarkdown;
        verified = fc.verifiedCount;
        unverified = fc.unverifiedCount;
      }

      final assistantMsg = ChatMessage(
        role: 'assistant',
        content: finalMarkdown,
        at: DateTime.now(),
        citations: sources,
        verifiedCount: verified,
        unverifiedCount: unverified,
      );
      final assistantSeq = _history.length;
      _history.add(assistantMsg);

      unawaited(InternalDatabaseService.instance.appendChatMessage(
        sessionId: sessionId,
        seq: assistantSeq,
        message: assistantMsg,
        runningContext: _runningContext,
        modelUsed: _openRouter.lastModelUsed,
        latencyMs: sw.elapsedMilliseconds,
      ));
      unawaited(InternalDatabaseService.instance.recordSpan(
        traceId: sessionId,
        spanName: 'openrouter.chatTurn',
        startedAtMs: DateTime.now().millisecondsSinceEpoch - sw.elapsedMilliseconds,
        durationMs: sw.elapsedMilliseconds,
        status: 'ok',
        attributes: {
          'model': _openRouter.lastModelUsed,
          'citations': sources.length,
          'verified': verified,
        },
      ));
    } catch (e, st) {
      sw.stop();
      final errMsg = ChatMessage(
        role: 'assistant',
        content: lang.startsWith('ar')
            ? '*خطأ في الاتصال بالنموذج: $e*'
            : '*Error contacting LLM: $e*',
        at: DateTime.now(),
      );
      final errSeq = _history.length;
      _history.add(errMsg);
      unawaited(InternalDatabaseService.instance.appendChatMessage(
        sessionId: sessionId,
        seq: errSeq,
        message: errMsg,
        runningContext: _runningContext,
      ));
      unawaited(InternalDatabaseService.instance.logError(
        'ChatSession',
        'sendUserMessage failed',
        error: e,
        stackTrace: st,
      ));
    } finally {
      _streaming = false;
      notifyListeners();
    }
  }

  /// Re-captures a new frame pair, runs Moondream `analyzeSelected`, merges new
  /// findings into [_runningContext], appends a system event, and persists to DB.
  Future<MoondreamStructuredAnalysis?> recapture(
    Uint8List cleanJpeg,
    Uint8List withBoxesJpeg, {
    required String selectedLabel,
    String lang = 'en',
  }) async {
    final analysis = await MoondreamService.instance.analyzeSelected(
      cleanJpeg,
      withBoxesJpeg,
      selectedLabel: selectedLabel,
      lang: lang,
    );
    if (analysis == null) return null;

    _anchor = AnchorContext(
      selectedLabel: selectedLabel,
      moondreamSummary: analysis.toMergedSummary(),
      firstLlmContext: _anchor.firstLlmContext,
      capturedAt: DateTime.now(),
    );

    _runningContext = _runningContext.merge(
      ConversationContext(
        objectIdentified: selectedLabel,
        stateOfMatter: analysis.stateOfMatter,
        hazards: analysis.hazards,
        sceneContext: analysis.whatsAround,
        labFindings: analysis.whatItIs.isNotEmpty
            ? analysis.whatItIs
            : analysis.caption,
        referencedEntities: [selectedLabel],
      ),
    );

    final sysMsg = ChatMessage(
      role: 'system',
      content: lang.startsWith('ar')
          ? 'تم التقاط صورة جديدة وتحليل "$selectedLabel": ${analysis.caption}'
          : 'Re-captured "$selectedLabel": ${analysis.caption}',
      at: DateTime.now(),
    );
    final seq = _history.length;
    _history.add(sysMsg);
    notifyListeners();

    unawaited(InternalDatabaseService.instance.appendChatMessage(
      sessionId: sessionId,
      seq: seq,
      message: sysMsg,
      runningContext: _runningContext,
    ));
    unawaited(InternalDatabaseService.instance.recordActivity(
      'recapture',
      target: selectedLabel,
      details: {'sessionId': sessionId},
    ));
    return analysis;
  }

  @override
  void dispose() {
    if (!_streamCtl.isClosed) {
      _streamCtl.close();
    }
    super.dispose();
  }
}
