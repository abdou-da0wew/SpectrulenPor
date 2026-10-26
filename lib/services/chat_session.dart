import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/bounding_box.dart';
import '../models/captured_frames.dart';
import '../models/chat_message.dart';
import '../models/conversation_context.dart';
import 'moondream_service.dart';
import 'openrouter_service.dart';

/// Anchored chat session with AUTO-UPDATING CONTEXT.
///
/// The [ConversationContext] is the persistent structured knowledge:
///   * Initialized from Moondream analysis + first LLM context.
///   * Embedded into EVERY system prompt sent to the LLM (every turn).
///   * Auto-updated when the AI emits `<context_update>{...}</context_update>`
///     blocks in any response — the AI itself decides what to refine.
///
/// Result: every chat turn sees the FULL accumulated knowledge, not just
/// chat history. The AI can refine / correct / extend fields freely.
class ChatSession {
  ChatSession({
    required this.frames,
    required this.moondreamAnalysis,
    required this.firstLlmContext,
    required this.openRouter,
    String lang = 'en',
  }) : _lang = lang {
    // Initialize the running context from the Moondream analysis + first LLM.
    _context = ConversationContext(
      objectIdentified: moondreamAnalysis.whatItIs.isNotEmpty
          ? moondreamAnalysis.whatItIs
          : frames.selectedBox.label,
      chemicalFormula: _extractFormula(moondreamAnalysis),
      stateOfMatter: moondreamAnalysis.stateOfMatter.isNotEmpty
          ? moondreamAnalysis.stateOfMatter
          : null,
      hazards: moondreamAnalysis.hazards.isNotEmpty ? moondreamAnalysis.hazards : null,
      sceneContext: moondreamAnalysis.whatsAround.isNotEmpty
          ? moondreamAnalysis.whatsAround
          : null,
      moondreamAnalysis: moondreamAnalysis.toMergedSummary(),
      firstLlmContext: firstLlmContext,
      commonUses: const [],
      relatedCompounds: const [],
      userNotes: const [],
      openQuestions: const [],
    );
  }

  final CapturedFrames frames;
  final MoondreamStructuredAnalysis moondreamAnalysis;
  final String firstLlmContext;
  final OpenRouterService openRouter;
  final String _lang;

  late ConversationContext _context;
  ConversationContext get context => _context;

  final List<ChatMessage> _history = [];
  List<ChatMessage> get history => List.unmodifiable(_history);

  final StreamController<String> _streamCtl = StreamController<String>.broadcast();
  Stream<String> get responseStream => _streamCtl.stream;

  bool _streaming = false;
  bool get isStreaming => _streaming;

  /// Send a user message. Streams the AI's response, parses any
  /// `<context_update>` blocks, merges them into the running context.
  Future<void> sendUserMessage(String text, {String? lang}) async {
    if (_streaming) return;
    final loc = lang ?? _lang;
    _streaming = true;
    _history.add(ChatMessage(role: 'user', content: text, at: DateTime.now()));

    try {
      final buffer = StringBuffer();
      await for (final chunk in openRouter.streamChat(
        history: _history,
        anchor: AnchorContext(
          frames: frames,
          moondreamAnalysis: moondreamAnalysis,
          firstLlmContext: firstLlmContext,
        ),
        runningContext: _context,
        lang: loc,
      )) {
        buffer.write(chunk);
        _streamCtl.add(chunk);
      }

      // Strip <context_update> blocks + merge them into the running context.
      final fullResponse = buffer.toString();
      var cleanResponse = fullResponse;
      final updates = ConversationContext.extractUpdatesAndStrip(
        fullResponse,
        (stripped) => cleanResponse = stripped,
      );
      for (final u in updates) {
        _context.mergeFrom(u);
      }

      _history.add(ChatMessage(
        role: 'assistant',
        content: cleanResponse,
        at: DateTime.now(),
      ));
    } catch (e) {
      debugPrint('[ChatSession] stream failed: $e');
      _history.add(ChatMessage(
        role: 'assistant',
        content: '(error: $e)',
        at: DateTime.now(),
      ));
    } finally {
      _streaming = false;
    }
  }

  /// Tool: re-capture — re-runs Moondream analyzeSelected with new frames.
  /// The resulting analysis is merged into the running context AND a system
  /// message is pushed describing the re-capture.
  Future<MoondreamStructuredAnalysis?> recapture(
    Uint8List cleanJpeg,
    Uint8List withBoxesJpeg, {
    String selectedLabel = 'the new object',
    String? lang,
  }) async {
    final analysis = await MoondreamService.instance.analyzeSelected(
      cleanJpeg, withBoxesJpeg,
      selectedLabel: selectedLabel, lang: lang ?? _lang,
    );
    if (analysis != null) {
      // Merge new Moondream findings into the running context.
      _context.mergeFrom(ConversationContext(
        objectIdentified: analysis.whatItIs.isNotEmpty ? analysis.whatItIs : null,
        stateOfMatter: analysis.stateOfMatter.isNotEmpty ? analysis.stateOfMatter : null,
        hazards: analysis.hazards.isNotEmpty ? analysis.hazards : null,
        sceneContext: analysis.whatsAround.isNotEmpty ? analysis.whatsAround : null,
        moondreamAnalysis: analysis.toMergedSummary(),
      ));
      _history.add(ChatMessage(
        role: 'system',
        content: 'Re-captured: ${analysis.toMergedSummary()}',
        at: DateTime.now(),
        toolUsed: 'recapture',
      ));
    }
    return analysis;
  }

  /// User can manually append a note to the running context (UI button).
  void addUserNote(String note) {
    _context.userNotes ??= [];
    if (!_context.userNotes!.contains(note)) {
      _context.userNotes!.add(note);
      _context.lastUpdated = DateTime.now();
    }
  }

  void dispose() => _streamCtl.close();

  /// Heuristic: extract a chemical formula from Moondream's whatItIs text
  /// (looks for the pattern "CuSO4", "H2O", etc.).
  static String? _extractFormula(MoondreamStructuredAnalysis a) {
    final re = RegExp(r'\b([A-Z][a-z]?\d*(?:[A-Z][a-z]?\d*)+)\b');
    final match = re.firstMatch(a.whatItIs);
    return match?.group(1);
  }
}

/// Immutable anchor for the chat session — the captured images + Moondream
/// structured analysis + first LLM context write-up. The OpenRouter
/// chat-mode prompt receives this AS WELL AS the running [ConversationContext].
class AnchorContext {
  const AnchorContext({
    required this.frames,
    required this.moondreamAnalysis,
    required this.firstLlmContext,
  });

  final CapturedFrames frames;
  final MoondreamStructuredAnalysis moondreamAnalysis;
  final String firstLlmContext;

  String toSystemPrompt({String lang = 'en'}) {
    final isAr = lang.startsWith('ar');
    return isAr
        ? 'أنت مساعد علمي ذكي لطالب ثانوي. تم التقاط صورة بواسطة نظارة '
            'SpectruLenPor الذكية وتحليلها بواسطة Moondream3.1 + سلسلة LLM '
            '(gemma→inkling→nemotron). الصورة الملتقطة + التحليل المهيكل + '
            'السياق العلمي الأولي مرفقة في السياق المتراكم. المستخدم سيتحدث '
            'معك الآن. ردودك يجب أن تكون علمية ومفصلة. إذا تعلمت معلومات '
            'جديدة، أصدر كتلة `<context_update>` لتحديث السياق.'
        : 'You are an intelligent scientific assistant for a high-school student. '
            'An image captured by the SpectruLenPor smart glasses has been analyzed '
            'by Moondream3.1 + the LLM chain (gemma→inkling→nemotron). The captured '
            'image, structured Moondream analysis, and first scientific context are '
            'all in the accumulated context below. The user will now chat with you. '
            'Your responses must be scientific, detailed, and accurate. If you learn '
            'new information during this conversation, emit a `<context_update>` block '
            'to update the running context for all subsequent turns.';
  }
}
