import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/bounding_box.dart';
import '../models/captured_frames.dart';
import '../models/chat_message.dart';
import 'moondream_service.dart';
import 'openrouter_service.dart';

/// Anchored chat session. The "anchor" is a captured image-pair + the
/// Moondream structured analysis + the LLM's first scientific context write-up.
/// Each user message extends the conversation; the AI has tools to re-capture,
/// zoom, highlight, and (later) web-search.
///
/// Flow:
///   1. User taps a YOLO box on the live preview.
///   2. CapturedFrames is recorded (clean + with-boxes JPEGs).
///   3. MoondreamStructuredAnalysis is produced from those frames.
///   4. The LLM writes the first scientific context (auto-narrated via TTS).
///   5. This ChatSession holds the conversation from that point forward.
class ChatSession {
  ChatSession({
    required this.frames,
    required this.moondreamAnalysis,
    required this.firstLlmContext,
    required this.openRouter,
  });

  final CapturedFrames frames;
  final MoondreamStructuredAnalysis moondreamAnalysis;
  final String firstLlmContext;
  final OpenRouterService openRouter;

  final List<ChatMessage> _history = [];
  List<ChatMessage> get history => List.unmodifiable(_history);

  /// Stream controller for the streaming LLM response.
  final StreamController<String> _streamCtl = StreamController<String>.broadcast();
  Stream<String> get responseStream => _streamCtl.stream;

  bool _streaming = false;
  bool get isStreaming => _streaming;

  /// Send a user message. Streams the AI's response.
  Future<void> sendUserMessage(String text, {String lang = 'en'}) async {
    if (_streaming) return;
    _streaming = true;
    _history.add(ChatMessage(
      role: 'user',
      content: text,
      at: DateTime.now(),
    ));

    try {
      final buffer = StringBuffer();
      await for (final chunk in openRouter.streamChat(
        history: _history,
        anchor: AnchorContext(
          frames: frames,
          moondreamAnalysis: moondreamAnalysis,
          firstLlmContext: firstLlmContext,
        ),
        lang: lang,
      )) {
        buffer.write(chunk);
        _streamCtl.add(chunk);
      }
      _history.add(ChatMessage(
        role: 'assistant',
        content: buffer.toString(),
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

  /// Tool: re-capture. The user points the camera at the same object again
  /// (or a different one). Returns new Moondream analysis — caller should
  /// update the anchor + push a system message describing the re-capture.
  Future<MoondreamStructuredAnalysis?> recapture(
    Uint8List cleanJpeg,
    Uint8List withBoxesJpeg, {
    String selectedLabel = 'the new object',
    String lang = 'en',
  }) async {
    final analysis = await MoondreamService.instance.analyzeSelected(
      cleanJpeg, withBoxesJpeg,
      selectedLabel: selectedLabel, lang: lang,
    );
    if (analysis != null) {
      _history.add(ChatMessage(
        role: 'system',
        content: 'Re-captured: ${analysis.toMergedSummary()}',
        at: DateTime.now(),
        toolUsed: 'recapture',
      ));
    }
    return analysis;
  }

  void dispose() {
    _streamCtl.close();
  }
}

/// Immutable anchor for the chat session — the captured images + Moondream
/// structured analysis + the LLM's first scientific context write-up. The
/// OpenRouter chat-mode prompt receives this as the system message.
class AnchorContext {
  const AnchorContext({
    required this.frames,
    required this.moondreamAnalysis,
    required this.firstLlmContext,
  });

  final CapturedFrames frames;
  final MoondreamStructuredAnalysis moondreamAnalysis;
  final String firstLlmContext;

  /// Build the system prompt that introduces the anchor + the chat rules.
  String toSystemPrompt({String lang = 'en'}) {
    final isAr = lang.startsWith('ar');
    if (isAr) {
      return [
        'You are an intelligent scientific assistant for a high-school student. An image captured by the SpectruLenPor smart glasses has been analyzed.',
        '',
        'The clean image (no boxes) and a boxes-painted image were sent to Moondream3.1 which produced a structured analysis.',
        '',
        'Structured analysis from Moondream:',
        moondreamAnalysis.toMergedSummary(),
        '',
        'First scientific context (auto-generated, narrated to user via TTS):',
        firstLlmContext,
        '',
        'The user will now chat with you to ask questions, request more details, or add information. Your response must be scientific, detailed, and accurate. If you are unsure, say so honestly. You may use available tools: re-capture (take a new image), highlight (mark a region), zoom (enlarge the image).',
      ].join('\n');
    }
    return [
      'You are an intelligent scientific assistant for a high-school student. An image captured by the SpectruLenPor smart glasses has been analyzed.',
      '',
      'The clean image (no boxes) and a boxes-painted image were sent to Moondream3.1 which produced a structured analysis.',
      '',
      'Structured analysis from Moondream:',
      moondreamAnalysis.toMergedSummary(),
      '',
      'First scientific context (auto-generated, narrated to user via TTS):',
      firstLlmContext,
      '',
      'The user will now chat with you to ask questions, request more details, or add information. Your response must be scientific, detailed, and accurate. If you are unsure, say so honestly. You may use available tools: re-capture (take a new image), highlight (mark a region), zoom (enlarge the image).',
    ].join('\n');
  }
}
