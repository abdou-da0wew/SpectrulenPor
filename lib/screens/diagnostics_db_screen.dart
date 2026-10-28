import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/recognition_state.dart';
import '../services/internal_db_service.dart';
import '../utils/app_theme.dart' as palette;

/// Full Internal Database & Telemetry/Logs/Traces/Crash-Hang Inspector.
class DiagnosticsDbScreen extends StatefulWidget {
  const DiagnosticsDbScreen({super.key});

  @override
  State<DiagnosticsDbScreen> createState() => _DiagnosticsDbScreenState();
}

class _DiagnosticsDbScreenState extends State<DiagnosticsDbScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController =
      TabController(length: 4, vsync: this);

  bool _loading = true;
  String? _levelFilter;
  Map<String, int> _stats = const {};
  List<Map<String, dynamic>> _logs = const [];
  List<Map<String, dynamic>> _crashes = const [];
  List<Map<String, dynamic>> _traces = const [];
  List<Map<String, dynamic>> _telemetry = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final db = InternalDatabaseService.instance;
    final stats = await db.getStats();
    final logs = await db.getLogs(level: _levelFilter, limit: 150);
    final crashes = await db.getCrashHangReports(limit: 80);
    final traces = await db.getRecentTraces(limit: 120);
    final telemetry = await db.getRecentTelemetry(limit: 80);
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _logs = logs;
      _crashes = crashes;
      _traces = traces;
      _telemetry = telemetry;
      _loading = false;
    });
  }

  Future<void> _copyExportJson() async {
    final dump = await InternalDatabaseService.instance.exportDiagnosticsDump();
    final pretty = const JsonEncoder.withIndent('  ').convert(dump);
    await Clipboard.setData(ClipboardData(text: pretty));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Diagnostics JSON exported to clipboard'),
      ),
    );
  }

  Future<void> _clearCache({required bool all}) async {
    await InternalDatabaseService.instance.pruneCache(clearAll: all);
    await _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          all ? 'Cleared all cached responses' : 'Pruned expired cache entries',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = context.watch<RecognitionState>().isArabic;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          isAr ? 'قاعدة البيانات والتشخيص' : 'Internal DB & Diagnostics',
        ),
        actions: [
          IconButton(
            tooltip: isAr ? 'نسخ تقرير JSON' : 'Export Diagnostics JSON',
            icon: const Icon(Icons.data_object_rounded),
            onPressed: _copyExportJson,
          ),
          IconButton(
            tooltip: isAr ? 'تحديث' : 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _refresh,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          indicatorColor: Colors.white,
          tabs: [
            Tab(
              icon: const Icon(Icons.storage_rounded, size: 18),
              text: isAr ? 'نظرة عامة' : 'Overview & Cache',
            ),
            Tab(
              icon: const Icon(Icons.receipt_long_rounded, size: 18),
              text: isAr ? 'السجلات' : 'Logs & Errors',
            ),
            Tab(
              icon: const Icon(Icons.warning_amber_rounded, size: 18),
              text: isAr ? 'الأعطال والتعليق' : 'Crashes & Hangs',
            ),
            Tab(
              icon: const Icon(Icons.speed_rounded, size: 18),
              text: isAr ? 'التتبع والقياسات' : 'Traces & Telemetry',
            ),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildOverviewTab(isAr),
                _buildLogsTab(isAr),
                _buildCrashesTab(isAr),
                _buildTracesTab(isAr),
              ],
            ),
    );
  }

  Widget _buildOverviewTab(bool isAr) {
    final db = InternalDatabaseService.instance;
    final rows = <(IconData, String, int)>[
      (Icons.forum_rounded, 'chat_sessions', _stats['chat_sessions'] ?? 0),
      (Icons.chat_rounded, 'chat_messages', _stats['chat_messages'] ?? 0),
      (Icons.cached_rounded, 'response_cache', _stats['response_cache'] ?? 0),
      (Icons.receipt_long_rounded, 'app_logs', _stats['app_logs'] ?? 0),
      (
        Icons.report_problem_rounded,
        'crash_hang_reports',
        _stats['crash_hang_reports'] ?? 0
      ),
      (
        Icons.sensors_rounded,
        'telemetry_events',
        _stats['telemetry_events'] ?? 0
      ),
      (
        Icons.account_tree_rounded,
        'pipeline_traces',
        _stats['pipeline_traces'] ?? 0
      ),
      (Icons.person_pin_rounded, 'user_data', _stats['user_data'] ?? 0),
      (Icons.timeline_rounded, 'user_activity', _stats['user_activity'] ?? 0),
    ];

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 10),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(
              Icons.dns_rounded,
              color: palette.AppColors.dustyLavender,
            ),
            title: Text(
              isAr ? 'محرك التخزين الداخلي' : 'Active Storage Engine',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              'Engine: ${db.engineName} · Watchdog: active',
            ),
            trailing: FilledButton.tonalIcon(
              onPressed: _copyExportJson,
              icon: const Icon(Icons.copy_all_rounded, size: 16),
              label: Text(isAr ? 'تصدير' : 'Export JSON'),
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isAr ? 'إحصائيات الجداول (9 جداول)' : 'Table Row Counts (9 Tables)',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const Divider(),
                for (final r in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        Icon(
                          r.$1,
                          size: 18,
                          color: palette.AppColors.dustyLavender,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            r.$2,
                            style: const TextStyle(
                              fontFamily: 'SpaceMono',
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: palette.AppColors.dustGrey,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${r.$3}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
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
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isAr
                      ? 'إدارة ذاكرة التخزين المؤقت للاستجابات'
                      : 'Response & Knowledge Cache Controls',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _clearCache(all: false),
                      icon: const Icon(Icons.cleaning_services_rounded, size: 17),
                      label: Text(
                        isAr ? 'حذف المنتهي صلاحيته' : 'Prune Expired TTL',
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _clearCache(all: true),
                      icon: const Icon(Icons.delete_sweep_rounded, size: 17),
                      label: Text(
                        isAr ? 'مسح الكاش بالكامل' : 'Clear All Cache',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLogsTab(bool isAr) {
    final fmt = DateFormat('HH:mm:ss.SSS');
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: SegmentedButton<String?>(
            segments: const [
              ButtonSegment(value: null, label: Text('ALL')),
              ButtonSegment(value: 'INFO', label: Text('INFO')),
              ButtonSegment(value: 'WARN', label: Text('WARN')),
              ButtonSegment(value: 'ERROR', label: Text('ERROR')),
            ],
            selected: {_levelFilter},
            onSelectionChanged: (s) {
              setState(() => _levelFilter = s.first);
              _refresh();
            },
          ),
        ),
        Expanded(
          child: _logs.isEmpty
              ? Center(
                  child: Text(
                    isAr ? 'لا توجد سجلات مطابقة.' : 'No matching log entries.',
                  ),
                )
              : ListView.builder(
                  itemCount: _logs.length,
                  itemBuilder: (ctx, i) {
                    final l = _logs[i];
                    final lvl = (l['level'] ?? 'INFO').toString();
                    final tag = (l['tag'] ?? '').toString();
                    final msg = (l['message'] ?? '').toString();
                    final stack = (l['stack_trace'] ?? '').toString();
                    final ts = (l['created_at'] as num?)?.toInt() ?? 0;
                    final color = switch (lvl) {
                      'ERROR' => palette.AppColors.danger,
                      'WARN' => palette.AppColors.warning,
                      _ => palette.AppColors.dustyLavender,
                    };
                    return Card(
                      child: ExpansionTile(
                        leading: Icon(
                          lvl == 'ERROR'
                              ? Icons.error_outline_rounded
                              : lvl == 'WARN'
                                  ? Icons.warning_amber_rounded
                                  : Icons.info_outline_rounded,
                          color: color,
                        ),
                        title: Text(
                          '[$lvl] $tag — $msg',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          fmt.format(DateTime.fromMillisecondsSinceEpoch(ts)),
                          style: const TextStyle(fontSize: 11),
                        ),
                        children: [
                          if (stack.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: SelectableText(
                                stack,
                                style: const TextStyle(
                                  fontFamily: 'SpaceMono',
                                  fontSize: 11,
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildCrashesTab(bool isAr) {
    if (_crashes.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.verified_user_rounded,
              size: 46,
              color: palette.AppColors.success,
            ),
            const SizedBox(height: 10),
            Text(
              isAr
                  ? 'لم يتم تسجيل أي انهيارات أو تعليق في الواجهة.'
                  : 'Zero crashes or UI hangs detected.',
              style: const TextStyle(color: palette.AppColors.inkSoft),
            ),
          ],
        ),
      );
    }

    final fmt = DateFormat('yyyy-MM-dd HH:mm:ss');
    return ListView.builder(
      itemCount: _crashes.length,
      itemBuilder: (ctx, i) {
        final c = _crashes[i];
        final kind = (c['kind'] ?? 'crash').toString().toUpperCase();
        final summary = (c['summary'] ?? '').toString();
        final stack = (c['stack_trace'] ?? '').toString();
        final ts = (c['created_at'] as num?)?.toInt() ?? 0;
        return Card(
          child: ExpansionTile(
            leading: Icon(
              kind == 'HANG'
                  ? Icons.hourglass_bottom_rounded
                  : Icons.bug_report_rounded,
              color: palette.AppColors.danger,
            ),
            title: Text(
              '[$kind] $summary',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            subtitle: Text(fmt.format(DateTime.fromMillisecondsSinceEpoch(ts))),
            children: [
              if (stack.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    stack,
                    style: const TextStyle(
                      fontFamily: 'SpaceMono',
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTracesTab(bool isAr) {
    final fmt = DateFormat('HH:mm:ss');
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Text(
            isAr ? 'مراحل خط الأنابيب (Pipeline Spans)' : 'Pipeline Execution Spans',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
        ),
        if (_traces.isEmpty)
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              isAr ? 'لا توجد آثار تنفيذ بعد.' : 'No execution spans recorded yet.',
              style: const TextStyle(color: palette.AppColors.inkSoft),
            ),
          ),
        for (final t in _traces.take(50))
          Card(
            child: ListTile(
              dense: true,
              leading: Icon(
                t['status'] == 'ok'
                    ? Icons.check_circle_outline_rounded
                    : Icons.error_outline_rounded,
                color: t['status'] == 'ok'
                    ? palette.AppColors.success
                    : palette.AppColors.danger,
              ),
              title: Text(
                '${t['span_name']} (${t['duration_ms']} ms)',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                'trace=${t['trace_id']} · ${fmt.format(DateTime.fromMillisecondsSinceEpoch((t['started_at'] as num?)?.toInt() ?? 0))}',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
        const Divider(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Text(
            isAr ? 'قياسات الطيف والمستشعرات (Telemetry)' : 'Sensor & Spectrum Telemetry',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
        ),
        if (_telemetry.isEmpty)
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              isAr ? 'لا توجد قراءات طيفية مسجلة.' : 'No sensor telemetry logged yet.',
              style: const TextStyle(color: palette.AppColors.inkSoft),
            ),
          ),
        for (final ev in _telemetry.take(30))
          ListTile(
            dense: true,
            leading: Icon(
              ((ev['hazard'] as num?)?.toInt() ?? 0) == 1
                  ? Icons.warning_rounded
                  : Icons.sensors_rounded,
              color: ((ev['hazard'] as num?)?.toInt() ?? 0) == 1
                  ? palette.AppColors.danger
                  : palette.AppColors.dustyLavender,
            ),
            title: Text(
              'UV ${ev['uv_mw_cm2'] ?? '-'} mW/cm² · IR ${ev['ir_mw_cm2'] ?? '-'} mW/cm² · ${ev['ambient_lux'] ?? '-'} lx',
              style: const TextStyle(fontSize: 12.5),
            ),
            subtitle: Text(
              fmt.format(DateTime.fromMillisecondsSinceEpoch(
                  (ev['created_at'] as num?)?.toInt() ?? 0)),
              style: const TextStyle(fontSize: 11),
            ),
          ),
      ],
    );
  }
}
