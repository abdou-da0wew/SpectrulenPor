import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/citation.dart';
import '../models/recognition_state.dart';
import '../services/docs_search_service.dart';
import '../services/internal_db_service.dart';
import '../utils/app_theme.dart' as palette;
import '../utils/app_typography.dart';
import 'chat_screen.dart';

/// Saved Chat History, 3-Mode Scientific Knowledge Explorer, and Activity Log.
class HistoryScreen extends StatefulWidget {
  final int initialTab;
  const HistoryScreen({super.key, this.initialTab = 0});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: 3,
    vsync: this,
    initialIndex: widget.initialTab.clamp(0, 2),
  );

  bool _loading = true;
  List<SavedChatSummary> _sessions = const [];
  List<Map<String, dynamic>> _activities = const [];

  final TextEditingController _searchCtl = TextEditingController();
  DocsSearchMode _docsMode = DocsSearchMode.semantic;
  bool _searchingDocs = false;
  bool _includeCloudDocs = true;
  List<Citation> _docResults = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = context.read<RecognitionState>();
      _docsMode = state.searchMode;
      _refreshAll();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchCtl.dispose();
    super.dispose();
  }

  Future<void> _refreshAll() async {
    setState(() => _loading = true);
    final sessions = await InternalDatabaseService.instance.listChatSessions();
    final acts = await InternalDatabaseService.instance.getRecentActivities();
    if (!mounted) return;
    setState(() {
      _sessions = sessions;
      _activities = acts;
      _loading = false;
    });
  }

  Future<void> _runDocsSearch([String? preset]) async {
    final query = (preset ?? _searchCtl.text).trim();
    if (preset != null) {
      _searchCtl.text = preset;
    }
    if (query.isEmpty) return;

    setState(() => _searchingDocs = true);
    final lang = context.read<RecognitionState>().localeCode;
    try {
      final hits = await DocsSearchService.instance.searchByMode(
        query,
        mode: _docsMode,
        startIndex: 1,
        limit: 12,
        lang: lang,
        allowNetwork: _includeCloudDocs,
      );
      if (!mounted) return;
      setState(() {
        _docResults = hits;
        _searchingDocs = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _searchingDocs = false);
    }
  }

  Future<void> _resumeSession(SavedChatSummary s) async {
    final state = context.read<RecognitionState>();
    final ok = await state.resumeSavedChatSession(s.id);
    if (!mounted) return;
    if (ok) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ChatScreen()),
      );
      _refreshAll();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            state.isArabic
                ? 'تعذّر استعادة المحادثة المحفوظة.'
                : 'Could not restore saved chat session.',
          ),
        ),
      );
    }
  }

  Future<void> _deleteSession(SavedChatSummary s) async {
    await InternalDatabaseService.instance.deleteChatSession(s.id);
    await _refreshAll();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<RecognitionState>();
    final isAr = state.isArabic;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          isAr ? 'السجل والموسوعة العلمية' : 'History & Scientific Docs',
        ),
        actions: [
          IconButton(
            tooltip: isAr ? 'تحديث' : 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _refreshAll,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          indicatorColor: Colors.white,
          tabs: [
            Tab(
              icon: const Icon(Icons.forum_rounded, size: 18),
              text: isAr ? 'المحادثات' : 'Saved Chats',
            ),
            Tab(
              icon: const Icon(Icons.science_rounded, size: 18),
              text: isAr ? 'المراجع العلمية' : 'Knowledge Docs',
            ),
            Tab(
              icon: const Icon(Icons.timeline_rounded, size: 18),
              text: isAr ? 'النشاط' : 'Activity',
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildSavedChatsTab(isAr),
          _buildDocsExplorerTab(isAr),
          _buildActivityTab(isAr),
        ],
      ),
    );
  }

  Widget _buildSavedChatsTab(bool isAr) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_sessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.chat_bubble_outline_rounded,
                size: 48,
                color: palette.AppColors.dustyMauve,
              ),
              const SizedBox(height: 12),
              Text(
                isAr
                    ? 'لا توجد محادثات محفوظة بعد. حدّد عنصراً من الكاميرا واضغط التقاط وتحليل.'
                    : 'No saved chats yet. Select a detected object on camera and press Capture & Analyze.',
                textAlign: TextAlign.center,
                style: AppTypography.bodyOf(
                  context,
                  color: palette.AppColors.inkSoft,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final fmt = DateFormat('yyyy-MM-dd HH:mm');
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _sessions.length,
      itemBuilder: (ctx, i) {
        final s = _sessions[i];
        final ctxObj = s.runningContext;
        return Card(
          child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            leading: CircleAvatar(
              backgroundColor:
                  palette.AppColors.dustyLavender.withOpacity(0.14),
              child: const Icon(
                Icons.biotech_rounded,
                color: palette.AppColors.dustyLavender,
              ),
            ),
            title: Text(
              s.title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    _miniTag(
                      Icons.chat_outlined,
                      isAr
                          ? '${s.messageCount} رسائل'
                          : '${s.messageCount} msgs',
                    ),
                    _miniTag(
                      Icons.schedule_rounded,
                      fmt.format(s.updatedAt),
                    ),
                    if (ctxObj.chemicalFormula.isNotEmpty)
                      _miniTag(
                        Icons.functions_rounded,
                        ctxObj.chemicalFormula,
                      ),
                  ],
                ),
                if (s.moondreamAnalysis.whatItIs.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    s.moondreamAnalysis.whatItIs,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: palette.AppColors.inkSoft,
                    ),
                  ),
                ],
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: isAr ? 'فتح المحادثة' : 'Resume chat',
                  icon: const Icon(
                    Icons.open_in_new_rounded,
                    color: palette.AppColors.dustyLavender,
                  ),
                  onPressed: () => _resumeSession(s),
                ),
                IconButton(
                  tooltip: isAr ? 'حذف' : 'Delete',
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    color: palette.AppColors.danger,
                  ),
                  onPressed: () => _deleteSession(s),
                ),
              ],
            ),
            onTap: () => _resumeSession(s),
          ),
        );
      },
    );
  }

  Widget _buildDocsExplorerTab(bool isAr) {
    final presets = <String>[
      'Gold',
      'Uranium',
      'Sodium Chloride',
      'Sulfuric Acid',
      'Borosilicate Glass',
      'Caffeine',
      'GHS06',
    ];

    return Column(
      children: [
        Container(
          color: palette.AppColors.surfaceLight,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchCtl,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _runDocsSearch(),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.manage_search_rounded),
                        hintText: isAr
                            ? 'ابحث في 119 عنصراً، 110 مركبات، السلامة، PubChem، ويكيبيديا…'
                            : 'Search 119 elements, 110 compounds, GHS, PubChem, Wiki…',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _searchingDocs ? null : () => _runDocsSearch(),
                    icon: const Icon(Icons.search_rounded, size: 18),
                    label: Text(isAr ? 'بحث' : 'Search'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: SegmentedButton<DocsSearchMode>(
                      segments: [
                        ButtonSegment(
                          value: DocsSearchMode.strict,
                          icon: const Icon(Icons.gavel_rounded, size: 16),
                          label: Text(isAr ? 'صارم' : 'Strict'),
                        ),
                        ButtonSegment(
                          value: DocsSearchMode.detailed,
                          icon: const Icon(Icons.list_alt_rounded, size: 16),
                          label: Text(isAr ? 'مفصل' : 'Detailed'),
                        ),
                        ButtonSegment(
                          value: DocsSearchMode.semantic,
                          icon: const Icon(Icons.hub_rounded, size: 16),
                          label: Text(isAr ? 'دلالي' : 'Semantic'),
                        ),
                      ],
                      selected: {_docsMode},
                      onSelectionChanged: (sel) {
                        setState(() => _docsMode = sel.first);
                        if (_searchCtl.text.trim().isNotEmpty) {
                          _runDocsSearch();
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    _includeCloudDocs
                        ? Icons.public_rounded
                        : Icons.offline_bolt_rounded,
                    size: 16,
                    color: palette.AppColors.dustyLavender,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      isAr
                          ? 'تضمين PubChem + Wikipedia + البحث السحابي'
                          : 'Include live PubChem + Wikipedia + Web Search',
                      style: const TextStyle(
                        fontSize: 12,
                        color: palette.AppColors.inkSoft,
                      ),
                    ),
                  ),
                  Switch(
                    value: _includeCloudDocs,
                    onChanged: (v) {
                      setState(() => _includeCloudDocs = v);
                      if (_searchCtl.text.trim().isNotEmpty) {
                        _runDocsSearch();
                      }
                    },
                  ),
                ],
              ),
              SizedBox(
                height: 32,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: presets.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (_, idx) => ActionChip(
                    avatar: const Icon(Icons.bolt_rounded, size: 14),
                    label: Text(
                      presets[idx],
                      style: const TextStyle(fontSize: 12),
                    ),
                    onPressed: () => _runDocsSearch(presets[idx]),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _searchingDocs
              ? const Center(child: CircularProgressIndicator())
              : _docResults.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          isAr
                              ? 'اختر وضع البحث (صارم / مفصل / دلالي) وابحث عن أي عنصر كيميائي أو مركب أو معيار سلامة.'
                              : 'Choose a search mode (Strict / Detailed / Semantic) and query any element, compound, material, or safety standard.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: palette.AppColors.inkSoft,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _docResults.length,
                      itemBuilder: (ctx, i) {
                        final c = _docResults[i];
                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      _sourceIcon(c.type),
                                      size: 18,
                                      color: palette.AppColors.dustyLavender,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        '[${c.index}] ${c.title}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                    _miniTag(
                                      Icons.verified_outlined,
                                      _sourceLabel(c.type),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                SelectableText(
                                  c.snippet,
                                  style: AppTypography.paragraphOf(
                                    context,
                                    fontSize: 12.5,
                                    color: palette.AppColors.inkDark,
                                  ),
                                ),
                                if (c.url.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  InkWell(
                                    onTap: () {
                                      Clipboard.setData(
                                        ClipboardData(text: c.url),
                                      );
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            isAr
                                                ? 'تم نسخ الرابط'
                                                : 'Copied reference URL',
                                          ),
                                        ),
                                      );
                                    },
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.link_rounded,
                                          size: 14,
                                          color: palette.AppColors.dustyMauve,
                                        ),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            c.url,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color:
                                                  palette.AppColors.dustyMauve,
                                              decoration:
                                                  TextDecoration.underline,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Widget _buildActivityTab(bool isAr) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_activities.isEmpty) {
      return Center(
        child: Text(
          isAr ? 'لا يوجد سجل نشاط بعد.' : 'No recorded user activity yet.',
          style: const TextStyle(color: palette.AppColors.inkSoft),
        ),
      );
    }
    final fmt = DateFormat('MM-dd HH:mm:ss');
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _activities.length,
      itemBuilder: (ctx, i) {
        final a = _activities[i];
        final action = (a['action'] ?? '').toString();
        final target = (a['target'] ?? '').toString();
        final ts = (a['created_at'] as num?)?.toInt() ?? 0;
        final dt = DateTime.fromMillisecondsSinceEpoch(ts);
        return ListTile(
          leading: Icon(
            _activityIcon(action),
            color: palette.AppColors.dustyLavender,
          ),
          title: Text(
            target.isEmpty ? action : '$action · $target',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
          ),
          subtitle: Text(
            fmt.format(dt),
            style: const TextStyle(
              fontSize: 11.5,
              color: palette.AppColors.inkSoft,
            ),
          ),
        );
      },
    );
  }

  IconData _sourceIcon(CitationType s) => switch (s) {
        CitationType.bundledDoc => Icons.menu_book_rounded,
        CitationType.pubchem => Icons.science_rounded,
        CitationType.wikipedia => Icons.travel_explore_rounded,
        CitationType.web => Icons.language_rounded,
        CitationType.factCheck => Icons.verified_rounded,
        CitationType.moondream => Icons.visibility_rounded,
      };

  String _sourceLabel(CitationType s) => switch (s) {
        CitationType.bundledDoc => 'DOCS',
        CitationType.pubchem => 'PUBCHEM',
        CitationType.wikipedia => 'WIKIPEDIA',
        CitationType.web => 'WEB',
        CitationType.factCheck => 'FACT-CHECK',
        CitationType.moondream => 'MOONDREAM',
      };

  IconData _activityIcon(String action) {
    if (action.contains('box')) return Icons.gps_fixed_rounded;
    if (action.contains('capture')) return Icons.camera_enhance_rounded;
    if (action.contains('chat')) return Icons.forum_rounded;
    if (action.contains('hazard')) return Icons.warning_amber_rounded;
    if (action.contains('camera')) return Icons.cameraswitch_rounded;
    return Icons.bolt_rounded;
  }

  Widget _miniTag(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: palette.AppColors.dustGrey.withOpacity(0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: palette.AppColors.inkSoft),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: palette.AppColors.inkDark,
            ),
          ),
        ],
      ),
    );
  }
}
