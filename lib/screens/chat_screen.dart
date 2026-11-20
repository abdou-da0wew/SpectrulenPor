import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../models/captured_frames.dart';
import '../models/chat_message.dart';
import '../models/citation.dart';
import '../models/conversation_context.dart';
import '../models/recognition_state.dart';
import '../services/docs_search_service.dart';
import '../utils/app_theme.dart' as palette;
import '../utils/app_typography.dart';
import 'history_screen.dart';
import '../utils/app_icons.dart';

/// Grounded scientific chat screen:
///   * Dual-frame visual anchor (`Clean` + `Marked Target` JPEGs with zoom viewer)
///   * Live Auto-Updating Structured `ConversationContext` inspector + Lab Notes
///   * 3-mode RAG selector (`Strict` / `Detailed` / `Semantic`)
///   * Google-Search-style `[n]` inline citations + Sources cards + Fact-Check badges
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  int _lastHistoryLen = 0;
  bool _showContextPanel = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage(RecognitionState state) async {
    final text = _input.text.trim();
    if (text.isEmpty || state.chatSession == null) return;
    _input.clear();
    _scrollToBottom();
    await state.chatSession!.sendUserMessage(
      text,
      lang: state.localeCode,
      startModel: state.upstreamStartModel,
    );
    _scrollToBottom();
  }

  Future<void> _toggleMic(RecognitionState state) async {
    if (state.mic.isListening) {
      await state.mic.stop();
      if (mounted) setState(() {});
      return;
    }
    final locale = state.isArabic ? 'ar-EG' : 'en-US';
    final started = await state.mic.startListen(
      localeId: locale,
      onResult: (text, isFinal) {
        if (!mounted || text.isEmpty) return;
        _input.text = text;
        _input.selection = TextSelection.fromPosition(
          TextPosition(offset: _input.text.length),
        );
        setState(() {});
        if (isFinal) {
          _sendMessage(state);
        }
      },
    );
    if (mounted) setState(() {});
    if (started) return;
    if (!mounted) return;

    final isAr = state.isArabic;
    final reason = state.mic.lastError ?? '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            isAr ? 'تعذّر تشغيل المايك: $reason' : 'Mic unavailable: $reason'),
        duration: const Duration(seconds: 4),
      ),
    );
    if (state.mic.permissionStatus == PermissionStatus.permanentlyDenied) {
      await openAppSettings();
    } else if (state.mic.permissionStatus == PermissionStatus.denied) {
      await state.mic.ensurePermission();
      await state.mic.init();
    }
  }

  Future<void> _speakMessage(RecognitionState state, String content) async {
    await state.speakText(content);
  }

  Future<void> _promptAddNote(RecognitionState state) async {
    final session = state.chatSession;
    if (session == null) return;
    final ctl = TextEditingController();
    final isAr = state.isArabic;
    final submitted = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(
              AppIcons.editNoteRounded,
              color: palette.AppColors.dustyLavender,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isAr
                    ? 'إضافة ملاحظة للسياق العلمي'
                    : 'Add Note to Scientific Context',
              ),
            ),
          ],
        ),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: 3,
          decoration: InputDecoration(
            hintText: isAr
                ? 'مثال: العينة في محلول مائي بدرجة حرارة 25°C…'
                : 'e.g., Sample is dissolved in 50 mL deionized water at 25°C…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(isAr ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            icon: const Icon(AppIcons.checkRounded, size: 16),
            label: Text(isAr ? 'حفظ في السياق' : 'Pin to Context'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (submitted != null && submitted.isNotEmpty) {
      await session.addUserNote(submitted);
      if (mounted) setState(() {});
    }
  }

  void _openDualFrameViewer(CapturedFrames frames, bool isAr) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    AppIcons.compareRounded,
                    color: palette.AppColors.dustyLavender,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isAr
                          ? 'الصورتان الملتقطتان (${frames.selectedBox.label})'
                          : 'Dual Captured Frames (${frames.selectedBox.label})',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(AppIcons.closeRounded),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _FramePreviewCard(
                        title: isAr
                            ? '1. الإطار المعلّم بالهدف المختار (withBoxesJpeg)'
                            : '1. Marked Target Frame (withBoxesJpeg)',
                        bytes: frames.withBoxesJpeg,
                      ),
                      const SizedBox(height: 10),
                      _FramePreviewCard(
                        title: isAr
                            ? '2. الإطار النظيف بدون علامات (cleanJpeg)'
                            : '2. Unobstructed Clean Frame (cleanJpeg)',
                        bytes: frames.cleanJpeg,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<RecognitionState>();
    final session = state.chatSession;
    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('SpectruLenPor Chat')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                AppIcons.forumOutlined,
                size: 46,
                color: palette.AppColors.dustyMauve,
              ),
              const SizedBox(height: 10),
              Text(
                state.isArabic
                    ? 'لا توجد محادثة نشطة حالياً.'
                    : 'No chat session active.',
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(AppIcons.historyEduRounded, size: 18),
                label: Text(
                  state.isArabic
                      ? 'فتح المحادثات المحفوظة'
                      : 'Open Saved Chats',
                ),
                onPressed: () {
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const HistoryScreen()),
                  );
                },
              ),
            ],
          ),
        ),
      );
    }

    return AnimatedBuilder(
      animation: session,
      builder: (context, _) {
        if (session.history.length != _lastHistoryLen) {
          _lastHistoryLen = session.history.length;
          _scrollToBottom();
        }

        return Scaffold(
          backgroundColor: palette.AppColors.alabasterGrey,
          appBar: AppBar(
            backgroundColor: palette.AppColors.dustyLavender,
            title: Text(
              state.isArabic ? 'محادثة سبكترو لِن بور' : 'SpectruLenPor Chat',
              style: AppTypography.displayOf(
                context,
                color: Colors.white,
                fontSize: 18,
              ),
            ),
            actions: [
              PopupMenuButton<DocsSearchMode>(
                tooltip:
                    state.isArabic ? 'وضع البحث العلمي' : 'Docs Search Mode',
                icon: const Icon(AppIcons.manageSearchRounded,
                    color: Colors.white),
                initialValue: state.searchMode,
                onSelected: (m) => state.searchMode = m,
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: DocsSearchMode.strict,
                    child: _modeMenuRow(
                      AppIcons.gavelRounded,
                      state.isArabic ? 'بحث صارم (Strict)' : 'Strict Search',
                      state.searchMode == DocsSearchMode.strict,
                    ),
                  ),
                  PopupMenuItem(
                    value: DocsSearchMode.detailed,
                    child: _modeMenuRow(
                      AppIcons.listAltRounded,
                      state.isArabic
                          ? 'بحث مفصل (Detailed)'
                          : 'Detailed Search',
                      state.searchMode == DocsSearchMode.detailed,
                    ),
                  ),
                  PopupMenuItem(
                    value: DocsSearchMode.semantic,
                    child: _modeMenuRow(
                      AppIcons.hubRounded,
                      state.isArabic
                          ? 'بحث دلالي (Semantic)'
                          : 'Semantic Search',
                      state.searchMode == DocsSearchMode.semantic,
                    ),
                  ),
                ],
              ),
              IconButton(
                tooltip: state.isArabic
                    ? 'السياق العلمي التلقائي'
                    : 'Anchored Scientific Context',
                icon: Icon(
                  _showContextPanel
                      ? AppIcons.psychologyRounded
                      : AppIcons.psychologyAltOutlined,
                  color: Colors.white,
                ),
                onPressed: () =>
                    setState(() => _showContextPanel = !_showContextPanel),
              ),
              IconButton(
                tooltip: state.isArabic
                    ? 'إعادة الالتقاط (تحليل جديد)'
                    : 'Re-capture (new Moondream analysis)',
                icon:
                    const Icon(AppIcons.cameraAltRounded, color: Colors.white),
                onPressed: () => state.recaptureFromChat(),
              ),
            ],
          ),
          body: Column(
            children: [
              _AnchorBar(
                state: state,
                contextOpen: _showContextPanel,
                onToggleContext: () =>
                    setState(() => _showContextPanel = !_showContextPanel),
                onInspectFrames: state.capturedFrames == null
                    ? null
                    : () => _openDualFrameViewer(
                          state.capturedFrames!,
                          state.isArabic,
                        ),
              ),
              if (_showContextPanel)
                _RunningContextDrawer(
                  ctx: session.runningContext,
                  isArabic: state.isArabic,
                  onAddNote: () => _promptAddNote(state),
                ),
              Expanded(
                child: StreamBuilder<String>(
                  stream: session.responseStream,
                  builder: (context, snapshot) {
                    final streaming = session.isStreaming;
                    final items = session.history.length + (streaming ? 1 : 0);
                    return ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(12),
                      itemCount: items,
                      itemBuilder: (context, i) {
                        if (i < session.history.length) {
                          final msg = session.history[i];
                          return _MessageBubble(
                            msg: msg,
                            onSpeak: () => _speakMessage(state, msg.content),
                            isArabic: state.isArabic,
                          );
                        }
                        final previewText =
                            ConversationContext.stripPartialStreamBlock(
                          snapshot.data ?? '',
                        );
                        return _StreamingBubble(
                          text: previewText,
                          isArabic: state.isArabic,
                        );
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
      },
    );
  }

  Widget _modeMenuRow(IconData icon, String title, bool active) {
    return Row(
      children: [
        Icon(
          icon,
          size: 18,
          color: active
              ? palette.AppColors.dustyLavender
              : palette.AppColors.inkSoft,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
        if (active)
          const Icon(
            AppIcons.checkRounded,
            size: 16,
            color: palette.AppColors.dustyLavender,
          ),
      ],
    );
  }
}

class _FramePreviewCard extends StatelessWidget {
  final String title;
  final Uint8List bytes;
  const _FramePreviewCard({required this.title, required this.bytes});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: palette.AppColors.dustyLavender,
          ),
        ),
        const SizedBox(height: 6),
        if (bytes.isNotEmpty)
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const SizedBox(
                height: 100,
                child: Center(child: Icon(AppIcons.brokenImageOutlined)),
              ),
            ),
          )
        else
          Container(
            height: 80,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.AppColors.dustGrey,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(AppIcons.imageNotSupportedOutlined),
          ),
      ],
    );
  }
}

class _AnchorBar extends StatelessWidget {
  final RecognitionState state;
  final bool contextOpen;
  final VoidCallback onToggleContext;
  final VoidCallback? onInspectFrames;

  const _AnchorBar({
    required this.state,
    required this.contextOpen,
    required this.onToggleContext,
    required this.onInspectFrames,
  });

  @override
  Widget build(BuildContext context) {
    final frames = state.capturedFrames;
    final session = state.chatSession;
    final label =
        frames?.selectedBox.label ?? session?.anchor.selectedLabel ?? '—';
    final mdText = state.moondreamAnalysis?.whatItIs.isNotEmpty == true
        ? state.moondreamAnalysis!.whatItIs
        : (state.moondreamAnalysis?.caption.isNotEmpty == true
            ? state.moondreamAnalysis!.caption
            : (session?.anchor.moondreamSummary ?? '—'));

    return Container(
      color: palette.AppColors.dustGrey,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          GestureDetector(
            onTap: onInspectFrames,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _thumb(frames?.withBoxesJpeg, AppIcons.gpsFixedRounded),
                const SizedBox(width: 6),
                _thumb(frames?.cleanJpeg, AppIcons.photoOutlined),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(
                      AppIcons.gpsFixedRounded,
                      size: 14,
                      color: palette.AppColors.dustyLavender,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        state.isArabic ? 'المحدد: $label' : 'Selected: $label',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.bodyOf(
                          context,
                          fontWeight: FontWeight.w700,
                          color: palette.AppColors.dustyLavender,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  'Moondream: $mdText',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.paragraphOf(
                    context,
                    fontSize: 11,
                    color: palette.AppColors.inkSoft,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: onToggleContext,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: palette.AppColors.dustyLavender.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: palette.AppColors.dustyLavender.withValues(alpha: 0.5),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    AppIcons.autoAwesomeMosaicRounded,
                    size: 14,
                    color: palette.AppColors.dustyLavender,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'T${session?.runningContext.turnCount ?? 0}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: palette.AppColors.dustyLavender,
                    ),
                  ),
                  Icon(
                    contextOpen
                        ? AppIcons.expandLessRounded
                        : AppIcons.expandMoreRounded,
                    size: 15,
                    color: palette.AppColors.dustyLavender,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _thumb(Uint8List? bytes, IconData badgeIcon) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: bytes != null && bytes.isNotEmpty
              ? Image.memory(
                  bytes,
                  width: 54,
                  height: 54,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => _emptyThumb(),
                )
              : _emptyThumb(),
        ),
        Positioned(
          right: 2,
          bottom: 2,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: palette.AppColors.inkDark.withValues(alpha: 0.75),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(badgeIcon, size: 10, color: Colors.white),
          ),
        ),
      ],
    );
  }

  Widget _emptyThumb() => Container(
        width: 54,
        height: 54,
        color: palette.AppColors.silver,
        child: const Icon(
          AppIcons.imageOutlined,
          size: 18,
          color: Colors.white,
        ),
      );
}

class _RunningContextDrawer extends StatelessWidget {
  final ConversationContext ctx;
  final bool isArabic;
  final VoidCallback onAddNote;

  const _RunningContextDrawer({
    required this.ctx,
    required this.isArabic,
    required this.onAddNote,
  });

  @override
  Widget build(BuildContext context) {
    final fields = <(IconData, String, String)>[
      if (ctx.objectIdentified.isNotEmpty)
        (
          AppIcons.categoryRounded,
          isArabic ? 'العنصر' : 'Object',
          ctx.objectIdentified
        ),
      if (ctx.chemicalFormula.isNotEmpty)
        (
          AppIcons.functionsRounded,
          isArabic ? 'الصيغة' : 'Formula',
          ctx.chemicalFormula
        ),
      if (ctx.stateOfMatter.isNotEmpty)
        (
          AppIcons.blurOnRounded,
          isArabic ? 'الحالة' : 'State',
          ctx.stateOfMatter
        ),
      if (ctx.composition.isNotEmpty)
        (
          AppIcons.scienceRounded,
          isArabic ? 'التركيب' : 'Composition',
          ctx.composition
        ),
      if (ctx.physicalProperties.isNotEmpty)
        (
          AppIcons.straightenRounded,
          isArabic ? 'فيزيائياً' : 'Physical',
          ctx.physicalProperties
        ),
      if (ctx.chemicalProperties.isNotEmpty)
        (
          AppIcons.biotechRounded,
          isArabic ? 'كيميائياً' : 'Chemical',
          ctx.chemicalProperties
        ),
      if (ctx.hazards.isNotEmpty)
        (
          AppIcons.warningAmberRounded,
          isArabic ? 'المخاطر' : 'Hazards',
          ctx.hazards
        ),
      if (ctx.commonUses.isNotEmpty)
        (
          AppIcons.handymanRounded,
          isArabic ? 'الاستخدامات' : 'Uses',
          ctx.commonUses.join(', ')
        ),
      if (ctx.establishedFacts.isNotEmpty)
        (
          AppIcons.verifiedRounded,
          isArabic ? 'حقائق مثبتة' : 'Facts',
          ctx.establishedFacts.join(' · ')
        ),
      if (ctx.openQuestions.isNotEmpty)
        (
          AppIcons.helpOutlineRounded,
          isArabic ? 'أسئلة مفتوحة' : 'Open Qs',
          ctx.openQuestions.join(' · ')
        ),
      if (ctx.userNotes.isNotEmpty)
        (
          AppIcons.stickyNote2Outlined,
          isArabic ? 'ملاحظاتك' : 'Lab Notes',
          ctx.userNotes.join(' · ')
        ),
    ];

    return Container(
      constraints: const BoxConstraints(maxHeight: 205),
      width: double.infinity,
      decoration: BoxDecoration(
        color: palette.AppColors.surfaceLight,
        border: Border(
          bottom: BorderSide(
              color: palette.AppColors.silver.withValues(alpha: 0.8)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                const Icon(
                  AppIcons.psychologyRounded,
                  size: 16,
                  color: palette.AppColors.dustyLavender,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    isArabic
                        ? 'السياق العلمي المدمج تلقائياً في كل رسالة (تحديث #${ctx.turnCount})'
                        : 'Auto-Updating System Prompt Context (Turn #${ctx.turnCount})',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: palette.AppColors.dustyLavender,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: onAddNote,
                  icon: const Icon(AppIcons.addCommentRounded, size: 14),
                  label: Text(
                    isArabic ? 'ملاحظة' : 'Add Note',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final f in fields)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2.5),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            f.$1,
                            size: 13,
                            color: palette.AppColors.dustyMauve,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${f.$2}: ',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: palette.AppColors.inkDark,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              f.$3,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: palette.AppColors.inkSoft,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage msg;
  final VoidCallback onSpeak;
  final bool isArabic;

  const _MessageBubble({
    required this.msg,
    required this.onSpeak,
    required this.isArabic,
  });

  /// Formats candidate source-match markers for display; legacy markers are
  /// accepted when rendering older saved conversations.
  static String _prettifySourceMatchMarkers(
    String raw, {
    required bool isArabic,
  }) {
    return raw
        .replaceAllMapped(
          RegExp(r'\[(?:SOURCE MATCH|VERIFIED)\s+(\d+)\]'),
          (m) => isArabic
              ? '[تطابق مصدر #' + m.group(1)! + ']'
              : '[Source match #' + m.group(1)! + ']',
        )
        .replaceAll(
          '[NO SOURCE MATCH]',
          isArabic ? '[لا يوجد تطابق مصدر]' : '[No source match]',
        )
        .replaceAll(
          '[UNVERIFIED]',
          isArabic ? '[لا يوجد تطابق مصدر]' : '[No source match]',
        );
  }

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context);
    final isUser = msg.role == 'user';
    final isSystem = msg.role == 'system' || msg.role == 'tool';
    final bg = isUser
        ? palette.AppColors.dustyLavender
        : isSystem
            ? palette.AppColors.dustGrey
            : Colors.white;
    final fg = isUser ? Colors.white : palette.AppColors.inkDark;

    final displayMarkdown = isUser
        ? msg.content
        : _prettifySourceMatchMarkers(msg.content, isArabic: isArabic);

    return Align(
      alignment: isUser
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.93,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: isSystem
              ? Border.all(
                  color: palette.AppColors.silver.withValues(alpha: 0.5),
                  width: 1,
                )
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MarkdownBody(
              data: displayMarkdown,
              selectable: true,
              styleSheet: MarkdownStyleSheet(
                p: AppTypography.body(
                  locale,
                  color: fg,
                  fontSize: 14,
                  height: 1.48,
                ),
                code: GoogleFonts.spaceMono(
                  color:
                      isUser ? Colors.white : palette.AppColors.dustyLavender,
                  backgroundColor:
                      isUser ? Colors.white24 : palette.AppColors.alabasterGrey,
                  fontSize: 11,
                ),
                h2: AppTypography.display(
                  locale,
                  color: fg,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
                h3: AppTypography.display(
                  locale,
                  color: fg,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
                blockquote: AppTypography.paragraph(
                  locale,
                  color: palette.AppColors.inkSoft,
                  fontSize: 12,
                ),
                listBullet: AppTypography.body(locale, color: fg, fontSize: 14),
              ),
            ),
            if (!isUser && !isSystem && msg.citations.isNotEmpty) ...[
              const SizedBox(height: 10),
              _CitationChipsStrip(citations: msg.citations),
              const SizedBox(height: 6),
              _SourcesBlock(
                citations: msg.citations,
                sourceMatchCount: msg.sourceMatchCount,
                noSourceMatchCount: msg.noSourceMatchCount,
              ),
            ],
            if (!isUser && !isSystem)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: IconButton(
                  icon: const Icon(AppIcons.volumeUpRounded, size: 18),
                  onPressed: onSpeak,
                  tooltip: isArabic ? 'نطق صوتي' : 'Talk out loud',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  color: palette.AppColors.dustyMauve,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Interactive Google-AI-Overviews-style `[n]` citation pills: a compact
/// stadium chip with a brand-colored favicon avatar (per source type), the
/// source display name (domain for web results), and a mono `[n]` badge.
/// Tapping any pill opens a bottom sheet with the full snippet & source URL.
class _CitationChipsStrip extends StatelessWidget {
  final List<Citation> citations;
  const _CitationChipsStrip({required this.citations});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final c in citations)
          _GoogleStyleChip(
            citation: c,
            onTap: () => _showCitationSheet(context, c),
          ),
      ],
    );
  }

  static IconData _iconForType(CitationType type) => switch (type) {
        CitationType.bundledDoc => AppIcons.menuBookRounded,
        CitationType.pubchem => AppIcons.scienceRounded,
        CitationType.wikipedia => AppIcons.travelExploreRounded,
        CitationType.web => AppIcons.languageRounded,
        CitationType.factCheck => AppIcons.verifiedRounded,
        CitationType.moondream => AppIcons.visibilityRounded,
      };

  static Color _brandColor(CitationType type) => switch (type) {
        CitationType.wikipedia => const Color(0xFF2B8CBE),
        CitationType.bundledDoc => palette.AppColors.dustyMauve,
        CitationType.pubchem => const Color(0xFF2E7D32),
        CitationType.web => const Color(0xFF6A51A3),
        CitationType.factCheck => palette.AppColors.success,
        CitationType.moondream => palette.AppColors.dustyLavender,
      };

  /// Google-style short source label: canonical product names for known
  /// providers, the site domain for generic web results.
  static String _sourceName(Citation c) {
    switch (c.type) {
      case CitationType.wikipedia:
        return 'Wikipedia';
      case CitationType.pubchem:
        return 'PubChem';
      case CitationType.bundledDoc:
        return 'Lab Docs';
      case CitationType.factCheck:
        return 'Fact Check';
      case CitationType.moondream:
        return 'Vision AI';
      case CitationType.web:
        final uri = Uri.tryParse(c.url);
        if (uri != null && uri.host.isNotEmpty) {
          return uri.host.replaceFirst(RegExp(r'^www\.'), '');
        }
        return 'Web';
    }
  }

  static void _showCitationSheet(BuildContext context, Citation c) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _iconForType(c.type),
                  color: palette.AppColors.dustyLavender,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '[${c.index}] ${c.title}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ),
                _TypeBadge(type: c.type),
              ],
            ),
            const SizedBox(height: 10),
            Flexible(
              child: SingleChildScrollView(
                child: SelectableText(
                  c.snippet,
                  style: GoogleFonts.spaceMono(
                    fontSize: 12,
                    color: palette.AppColors.inkDark,
                    height: 1.45,
                  ),
                ),
              ),
            ),
            if (c.url.isNotEmpty) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: c.url));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Source URL copied: ${c.url}')),
                  );
                },
                icon: const Icon(AppIcons.copyRounded, size: 16),
                label: Text(
                  c.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Compact Google-AI-Overviews-style source chip: white stadium pill with a
/// brand-colored circular favicon avatar, the short source name, and a
/// space-mono `[n]` badge.
class _GoogleStyleChip extends StatelessWidget {
  final Citation citation;
  final VoidCallback onTap;
  const _GoogleStyleChip({required this.citation, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = _CitationChipsStrip._brandColor(citation.type);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 3, 8, 3),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
              color: palette.AppColors.silver.withValues(alpha: 0.7)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Icon(
                _CitationChipsStrip._iconForType(citation.type),
                size: 11,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 132),
              child: Text(
                _CitationChipsStrip._sourceName(citation),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: palette.AppColors.inkDark,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '[${citation.index}]',
              style: GoogleFonts.spaceMono(
                fontSize: 9.5,
                fontWeight: FontWeight.bold,
                color: palette.AppColors.dustyMauve,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourcesBlock extends StatelessWidget {
  final List<Citation> citations;
  final int sourceMatchCount;
  final int noSourceMatchCount;

  const _SourcesBlock({
    required this.citations,
    required this.sourceMatchCount,
    required this.noSourceMatchCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: palette.AppColors.alabasterGrey,
        borderRadius: BorderRadius.circular(10),
        border:
            Border.all(color: palette.AppColors.silver.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                AppIcons.menuBookRounded,
                size: 14,
                color: palette.AppColors.dustyLavender,
              ),
              const SizedBox(width: 5),
              Text(
                AppLocalizations.of(context).factCheckHeader,
                style: GoogleFonts.jaro(
                  fontSize: 12.5,
                  color: palette.AppColors.dustyLavender,
                ),
              ),
              const Spacer(),
              _FactCheckBadge(
                sourceMatches: sourceMatchCount,
                unmatched: noSourceMatchCount,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            AppLocalizations.of(context).factCheckMethodHint,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: palette.AppColors.inkSoft,
                ),
          ),
          const SizedBox(height: 6),
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
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Favicon-style brand avatar (Google AI Overviews look).
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: _CitationChipsStrip._brandColor(c.type),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              _CitationChipsStrip._iconForType(c.type),
              size: 12,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '[${c.index}]',
            style: GoogleFonts.spaceMono(
              fontSize: 10.5,
              fontWeight: FontWeight.bold,
              color: palette.AppColors.dustyMauve,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        c.title,
                        style: AppTypography.bodyOf(
                          context,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: palette.AppColors.inkDark,
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                    _TypeBadge(type: c.type),
                  ],
                ),
                if (c.snippet.isNotEmpty)
                  Text(
                    c.snippet,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.spaceMono(
                      fontSize: 10,
                      color: palette.AppColors.inkSoft,
                    ),
                  ),
                if (c.url.isNotEmpty)
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: c.url));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Source URL copied: ${c.url}'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
                    child: Text(
                      c.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.spaceMono(
                        fontSize: 10,
                        color: palette.AppColors.dustyLavender,
                        decoration: TextDecoration.underline,
                      ),
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

class _TypeBadge extends StatelessWidget {
  final CitationType type;
  const _TypeBadge({required this.type});

  @override
  Widget build(BuildContext context) {
    final (color, icon, label) = switch (type) {
      CitationType.wikipedia => (
          const Color(0xFF2B8CBE),
          AppIcons.travelExploreRounded,
          'WIKI'
        ),
      CitationType.bundledDoc => (
          palette.AppColors.dustyMauve,
          AppIcons.menuBookRounded,
          'DOCS'
        ),
      CitationType.pubchem => (
          const Color(0xFF2E7D32),
          AppIcons.scienceRounded,
          'PUBCHEM'
        ),
      CitationType.web => (
          const Color(0xFF6A51A3),
          AppIcons.languageRounded,
          'WEB'
        ),
      CitationType.factCheck => (
          palette.AppColors.dustyLavender,
          AppIcons.manageSearchRounded,
          'MATCH'
        ),
      CitationType.moondream => (
          palette.AppColors.dustyLavender,
          AppIcons.visibilityRounded,
          'VLM'
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        border: Border.all(color: color, width: 0.6),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: GoogleFonts.spaceMono(
              fontSize: 9,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _FactCheckBadge extends StatelessWidget {
  final int sourceMatches;
  final int unmatched;

  const _FactCheckBadge({
    required this.sourceMatches,
    required this.unmatched,
  });

  @override
  Widget build(BuildContext context) {
    if (sourceMatches == 0 && unmatched == 0) return const SizedBox.shrink();
    final color = palette.AppColors.dustyLavender;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(AppIcons.manageSearchRounded, size: 13, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            AppLocalizations.of(context)
                .factCheckSourceMatchSummary(sourceMatches, unmatched),
            textAlign: TextAlign.end,
            style: GoogleFonts.spaceMono(fontSize: 10, color: color),
          ),
        ),
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
    final locale = Localizations.localeOf(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.93,
        ),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MarkdownBody(
              data: text.isEmpty ? '…' : text,
              styleSheet: MarkdownStyleSheet(
                p: AppTypography.body(
                  locale,
                  color: palette.AppColors.inkDark,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(height: 6),
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
            color: palette.AppColors.dustyLavender.withValues(alpha: 0.08),
            blurRadius: 6,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              micListening ? AppIcons.micRounded : AppIcons.micNoneRounded,
              color: micListening
                  ? palette.AppColors.danger
                  : palette.AppColors.dustyLavender,
            ),
            onPressed: onMic,
            tooltip: isArabic ? 'إدخال صوتي' : 'Voice input',
          ),
          Expanded(
            child: TextField(
              controller: controller,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              decoration: InputDecoration(
                hintText: isArabic
                    ? 'اسأل علمياً (مراجع تلقائية + تحقق من الحقائق)…'
                    : 'Ask anything scientific (auto [n] citations + fact-check)…',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: palette.AppColors.silver),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(
                    color: palette.AppColors.dustyLavender,
                    width: 2,
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton.filled(
            icon: const Icon(AppIcons.sendRounded, color: Colors.white),
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
