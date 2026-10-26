import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';

import '../models/recognition_state.dart';
import '../utils/app_theme.dart' as palette;

/// Chat screen — anchored conversation about the captured object.
///
/// Layout:
///   Top:    anchored image thumbnail (clean + with-boxes) + selected label.
///   Middle: scrolling list of chat messages (user / assistant / system).
///   Bottom: input row with mic button (Android SpeechRecognizer) + send +
///           per-message "🔊 Talk out loud" action.
///
/// Each assistant message has a small speaker icon button — taps narrate
/// that message via fish-audio cloud TTS (or Android native fallback).
///
/// The mic button calls MicService.startListen → transcribed text streams
/// into the input field → user can edit + send.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  StreamSubscription<String>? _responseSub;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _responseSub?.cancel();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage(RecognitionState state) async {
    final text = _input.text.trim();
    if (text.isEmpty || state.chatSession == null) return;
    _input.clear();
    await state.chatSession!.sendUserMessage(text, lang: state.localeCode);
    _scrollToBottom();
  }

  Future<void> _toggleMic(RecognitionState state) async {
    if (state.mic.isListening) {
      await state.mic.stop();
      return;
    }
    final locale = state.isArabic ? 'ar-EG' : 'en-US';
    await state.mic.startListen(
      localeId: locale,
      onResult: (text, isFinal) {
        if (text.isEmpty) return;
        // Replace the input field with the latest transcription (free-form dictation).
        _input.text = text;
        _input.selection = TextSelection.fromPosition(
          TextPosition(offset: _input.text.length),
        );
        setState(() {});
        if (isFinal) _sendMessage(state);
      },
    );
  }

  Future<void> _speakMessage(RecognitionState state, String content) async {
    // Cloud fish-audio TTS if enabled + configured; otherwise native Android TTS.
    if (state.useOpenRouterTts) {
      await state.openRouterTts.speakMarkdown(content);
    } else {
      await state.nativeTts.speak(content);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<RecognitionState>();
    final session = state.chatSession;
    if (session == null) {
      return const Scaffold(body: Center(child: Text('No chat session active.')));
    }
    _scrollToBottom();

    return Scaffold(
      backgroundColor: palette.AppColors.alabasterGrey,
      appBar: AppBar(
        backgroundColor: palette.AppColors.dustyLavender,
        title: Text(
          'SpectruLenPor Chat',
          style: GoogleFonts.jaro().copyWith(color: Colors.white, fontSize: 18),
        ),
        actions: [
          IconButton(
            tooltip: 'Re-capture (new Moondream analysis)',
            icon: const Icon(Icons.camera_alt, color: Colors.white),
            onPressed: () => state.recaptureFromChat(),
          ),
        ],
      ),
      body: Column(
        children: [
          // Anchored image thumbnail
          _AnchorBar(state: state),
          // Messages list
          Expanded(
            child: StreamBuilder<String>(
              stream: session.responseStream,
              builder: (context, snapshot) {
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: session.history.length + (session.isStreaming ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i < session.history.length) {
                      return _MessageBubble(
                        msg: session.history[i],
                        onSpeak: () => _speakMessage(state, session.history[i].content),
                        isArabic: state.isArabic,
                      );
                    }
                    // Streaming partial
                    return _StreamingBubble(text: snapshot.data ?? '', isArabic: state.isArabic);
                  },
                );
              },
            ),
          ),
          // Input row with mic + send
          _InputRow(
            controller: _input,
            micListening: state.mic.isListening,
            onMic: () => _toggleMic(state),
            onSend: () => _sendMessage(state),
            isArabic: state.isArabic,
          ),
        ],
      ),
    );
  }
}

class _AnchorBar extends StatelessWidget {
  final RecognitionState state;
  const _AnchorBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final frames = state.capturedFrames;
    return Container(
      height: 88,
      color: palette.AppColors.alabasterGrey,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          if (frames != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.memory(
                frames.withBoxesJpeg,
                width: 72,
                height: 72,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            )
          else
            Container(width: 72, height: 72, color: palette.AppColors.silver),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Selected: ${frames?.selectedBox.label ?? '—'}',
                  style: GoogleFonts.rubik().copyWith(
                    fontWeight: FontWeight.w600,
                    color: palette.AppColors.dustyLavender,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Moondream analysis: ${state.moondreamAnalysis?.whatItIs.isNotEmpty == true ? state.moondreamAnalysis!.whatItIs : '—'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.spaceMono().copyWith(
                    fontSize: 11,
                    color: palette.AppColors.silver,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final dynamic msg; // ChatMessage
  final VoidCallback onSpeak;
  final bool isArabic;
  const _MessageBubble({required this.msg, required this.onSpeak, required this.isArabic});

  @override
  Widget build(BuildContext context) {
    final isUser = msg.role == 'user';
    final isSystem = msg.role == 'system' || msg.role == 'tool';
    final bg = isUser
        ? palette.AppColors.dustyLavender
        : isSystem
            ? palette.AppColors.alabasterGrey
            : Colors.white;
    final fg = isUser ? Colors.white : palette.AppColors.inkDark;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: isSystem
              ? Border.all(color: palette.AppColors.silver.withOpacity(0.4), width: 1)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            MarkdownBody(
              data: msg.content,
              styleSheet: MarkdownStyleSheet(
                p: GoogleFonts.rubik().copyWith(color: fg, fontSize: 14),
                code: GoogleFonts.spaceMono().copyWith(color: fg, fontSize: 12),
              ),
            ),
            if (!isUser && !isSystem)
              IconButton(
                icon: const Icon(Icons.volume_up, size: 18),
                onPressed: onSpeak,
                tooltip: 'Talk out loud',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                color: palette.AppColors.dustyMauve,
              ),
          ],
        ),
      ),
    );
  }
}

class _StreamingBubble extends StatelessWidget {
  final String text;
  final bool isArabic;
  const _StreamingBubble({required this.text, required this.isArabic});
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MarkdownBody(
              data: text.isEmpty ? '…' : text,
              styleSheet: MarkdownStyleSheet(
                p: GoogleFonts.rubik().copyWith(
                  color: palette.AppColors.inkDark,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(height: 4),
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ),
      ),
    );
  }
}

class _InputRow extends StatelessWidget {
  final TextEditingController controller;
  final bool micListening;
  final VoidCallback onMic;
  final VoidCallback onSend;
  final bool isArabic;
  const _InputRow({
    required this.controller,
    required this.micListening,
    required this.onMic,
    required this.onSend,
    required this.isArabic,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: palette.AppColors.dustyLavender.withOpacity(0.08),
            blurRadius: 6,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(micListening ? Icons.mic : Icons.mic_none,
                color: micListening ? Colors.red : palette.AppColors.dustyLavender),
            onPressed: onMic,
            tooltip: 'Voice input',
          ),
          Expanded(
            child: TextField(
              controller: controller,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              decoration: InputDecoration(
                hintText: isArabic ? 'اكتب أو تحدث…' : 'Type or speak…',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide(color: palette.AppColors.silver),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide(color: palette.AppColors.dustyLavender, width: 2),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton.filled(
            icon: const Icon(Icons.send, color: Colors.white),
            onPressed: onSend,
            style: IconButton.styleFrom(
              backgroundColor: palette.AppColors.dustyLavender,
            ),
          ),
        ],
      ),
    );
  }
}
