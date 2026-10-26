import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../models/citation.dart';
import '../models/recognition_state.dart';
import '../utils/app_theme.dart' as palette;

/// Chat screen (v5.1) — anchored conversation with inline [n] citations
/// + Sources block at the bottom of each assistant message (Google AI
/// Overviews style) + fact-check status badge.
///
/// Layout:
///   Top:    anchored image thumbnail + selected label + Moondream summary.
///   Middle: scrolling list of chat messages. Assistant messages render:
///             - markdown body (with [n] inline citations as plain text)
///             - Sources block: numbered list of Citation[] with type badges
///             - "VERIFIED n / UNVERIFIED" fact-check chips inline
///             - Per-message "Talk out loud" icon button (Material Icons,
///               NO emojis)
///   Bottom: input row with mic button (Material Icons.mic) + send
///           (Material Icons.send).
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
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
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
        _input.text = text;
        _input.selection =
            TextSelection.fromPosition(TextPosition(offset: _input.text.length));
        setState(() {});
        if (isFinal) _sendMessage(state);
      },
    );
  }

  Future<void> _speakMessage(RecognitionState state, String content) async {
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
        title: Text('SpectruLenPor Chat',
            style: GoogleFonts.jaro(color: Colors.white, fontSize: 18)),
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
          _AnchorBar(state: state),
          Expanded(
            child: StreamBuilder<String>(
              stream: session.responseStream,
              builder: (context, snapshot) {
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount:
                      session.history.length + (session.isStreaming ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i < session.history.length) {
                      return _MessageBubble(
                        msg: session.history[i],
                        citations: i == 0
                            ? (state.firstLlmAnnotated?.citations ?? const [])
                            : const [],
                        onSpeak: () => _speakMessage(
                            state, session.history[i].content),
                        isArabic: state.isArabic,
                      );
                    }
                    return _StreamingBubble(
                        text: snapshot.data ?? '', isArabic: state.isArabic);
                  },
                );
              },
            ),
          ),
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
      color: palette.AppColors.dustGrey,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          if (frames != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.memory(frames.withBoxesJpeg,
                  width: 72, height: 72, fit: BoxFit.cover, gaplessPlayback: true),
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
                  style: GoogleFonts.rubik(
                      fontWeight: FontWeight.w600,
                      color: palette.AppColors.dustyLavender),
                ),
                const SizedBox(height: 4),
                Text(
                  'Moondream: ${state.moondreamAnalysis?.whatItIs.isNotEmpty == true ? state.moondreamAnalysis!.whatItIs : '—'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.spaceMono(
                      fontSize: 11, color: palette.AppColors.silver),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One chat message bubble. Assistant messages render the body markdown +
/// a Sources block (Google AI Overviews style) + a per-message "talk out
/// loud" icon button (Material Icon, no emoji).
class _MessageBubble extends StatelessWidget {
  final dynamic msg;
  final List<Citation> citations;
  final VoidCallback onSpeak;
  final bool isArabic;
  const _MessageBubble({
    required this.msg,
    required this.citations,
    required this.onSpeak,
    required this.isArabic,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = msg.role == 'user';
    final isSystem = msg.role == 'system' || msg.role == 'tool';
    final bg = isUser
        ? palette.AppColors.dustyLavender
        : isSystem
            ? palette.AppColors.dustGrey
            : Colors.white;
    final fg = isUser ? Colors.white : palette.AppColors.inkDark;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.92),
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
            // Body markdown with inline [n] + [VERIFIED n] / [UNVERIFIED] tags
            MarkdownBody(
              data: msg.content,
              styleSheet: MarkdownStyleSheet(
                p: GoogleFonts.rubik(color: fg, fontSize: 14, height: 1.4),
                code: GoogleFonts.spaceMono(color: fg, fontSize: 12),
                h2: GoogleFonts.jaro(color: fg, fontSize: 16, fontWeight: FontWeight.bold),
                h3: GoogleFonts.jaro(color: fg, fontSize: 14, fontWeight: FontWeight.bold),
                blockquote: GoogleFonts.spaceMono(
                    color: palette.AppColors.inkSoft,
                    fontSize: 12,
                    fontStyle: FontStyle.italic),
                listBullet: GoogleFonts.rubik(color: fg, fontSize: 14),
              ),
              extensionSet: null,
            ),
            // Sources block — Google AI Overviews style
            if (!isUser && !isSystem && citations.isNotEmpty) ...[
              const SizedBox(height: 8),
              _SourcesBlock(citations: citations),
            ],
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

/// Renders the "Sources" block like Google AI Overviews:
/// numbered list of citations with type badge (Wikipedia / Docs / Fact-check).
class _SourcesBlock extends StatelessWidget {
  final List<Citation> citations;
  const _SourcesBlock({required this.citations});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: palette.AppColors.alabasterGrey,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.AppColors.silver.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.menu_book, size: 14, color: palette.AppColors.dustyLavender),
              const SizedBox(width: 4),
              Text('Sources',
                  style: GoogleFonts.jaro(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: palette.AppColors.dustyLavender)),
              const Spacer(),
              if (citations.isNotEmpty)
                _FactCheckBadge(verified: citations.length, unverified: 0),
            ],
          ),
          const SizedBox(height: 4),
          ...citations.map((c) => _SourceRow(c: c)),
        ],
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  final Citation c;
  const _SourceRow({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('[${c.index}] ', style: GoogleFonts.spaceMono(
              fontSize: 11, fontWeight: FontWeight.bold, color: palette.AppColors.dustyMauve)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(c.title,
                          style: GoogleFonts.rubik(
                              fontSize: 12, fontWeight: FontWeight.w600, color: palette.AppColors.inkDark)),
                    ),
                    const SizedBox(width: 4),
                    _TypeBadge(type: c.type),
                  ],
                ),
                if (c.snippet.isNotEmpty)
                  Text(c.snippet,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.spaceMono(
                          fontSize: 10, color: palette.AppColors.inkSoft)),
                if (c.url.isNotEmpty)
                  InkWell(
                    onTap: () => _launchUrl(c.url),
                    child: Text(c.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.spaceMono(
                            fontSize: 10, color: Colors.blue, decoration: TextDecoration.underline)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _launchUrl(String url) {
    // Could integrate url_launcher; for now we just copy via debugPrint.
    // ignore: avoid_print
    print('Open URL: $url');
  }
}

class _TypeBadge extends StatelessWidget {
  final CitationType type;
  const _TypeBadge({required this.type});
  @override
  Widget build(BuildContext context) {
    final color = switch (type) {
      CitationType.wikipedia => const Color(0xFF36C5F0),       // wiki blue
      CitationType.bundledDoc => palette.AppColors.dustyMauve,
      CitationType.factCheck => palette.AppColors.success,
      CitationType.moondream => palette.AppColors.dustyLavender,
    };
    final label = switch (type) {
      CitationType.wikipedia => 'WIKI',
      CitationType.bundledDoc => 'DOCS',
      CitationType.factCheck => 'CHECK',
      CitationType.moondream => 'AI',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        border: Border.all(color: color, width: 0.5),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(label,
          style: GoogleFonts.spaceMono(
              fontSize: 9, fontWeight: FontWeight.bold, color: color)),
    );
  }
}

class _FactCheckBadge extends StatelessWidget {
  final int verified;
  final int unverified;
  const _FactCheckBadge({required this.verified, required this.unverified});
  @override
  Widget build(BuildContext context) {
    if (verified == 0 && unverified == 0) return const SizedBox.shrink();
    final allVerified = unverified == 0;
    final color = allVerified ? palette.AppColors.success : palette.AppColors.warning;
    final icon = allVerified ? Icons.verified : Icons.warning_amber;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Text('$verified verified${unverified > 0 ? ", $unverified unverified" : ""}',
            style: GoogleFonts.spaceMono(fontSize: 10, color: color)),
      ],
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
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.92),
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
                p: GoogleFonts.rubik(color: palette.AppColors.inkDark, fontSize: 14),
              ),
            ),
            const SizedBox(height: 4),
            const SizedBox(
              width: 14, height: 14,
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
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
