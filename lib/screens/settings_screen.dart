import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, rootBundle;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../main.dart' show appLocale;
import '../models/recognition_state.dart';
import '../services/docs_search_service.dart';
import '../services/internal_db_service.dart';
import '../services/local_vision_service.dart';
import '../services/moondream_service.dart';
import '../services/onnx_vision_service.dart';
import '../services/openrouter_service.dart';
import '../services/openrouter_tts_service.dart';
import '../services/phone_camera_service.dart';
import '../services/yolo_detector.dart';
import '../utils/app_theme.dart' as palette;
import '../utils/app_typography.dart';
import 'diagnostics_db_screen.dart';
import 'history_screen.dart';

/// Settings — full pipeline, YOLO26-Nano, Cloud-only policy, 3-mode RAG search,
/// API keys, Internal Database & Diagnostics, and Build/Version info.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

const String _envAppVersion = String.fromEnvironment('APP_VERSION');
const String _envAppBuild = String.fromEnvironment('APP_BUILD');
const String _envGitShaShort = String.fromEnvironment('GIT_SHA');
const String _envGitShaFull = String.fromEnvironment('GIT_SHA_FULL');
const String _envGitBranch = String.fromEnvironment('GIT_BRANCH');
const String _envGitDirty = String.fromEnvironment('GIT_DIRTY');
const String _envBuildDate = String.fromEnvironment('BUILD_DATE');

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _mdKeyCtl;
  late final TextEditingController _orLlmCtl;
  late final TextEditingController _orTtsCtl;

  bool _verifyingYolo = false;

  String _version = _envAppVersion.isNotEmpty ? _envAppVersion : '5.5.0';
  String _buildCode = _envAppBuild.isNotEmpty ? _envAppBuild : '15';
  String _gitSha = _envGitShaShort.isNotEmpty ? _envGitShaShort : 'dev';
  String _gitShaFull = _envGitShaFull.isNotEmpty ? _envGitShaFull : 'dev';
  String _gitBranch =
      _envGitBranch.isNotEmpty ? _envGitBranch : 'arena/f0a63bec-spectrulenpor';
  bool _gitDirty = _envGitDirty == 'true';
  String _buildDate = _envBuildDate.isNotEmpty ? _envBuildDate : 'unknown';

  @override
  void initState() {
    super.initState();
    final prefs = context.read<SharedPreferences>();
    _mdKeyCtl = TextEditingController(
      text: prefs.getString('moondream_api_key') ??
          MoondreamService.instance.apiKey,
    );
    _orLlmCtl = TextEditingController(
      text: prefs.getString('openrouter_llm_key') ??
          prefs.getString('openrouter_api_key') ??
          context.read<OpenRouterService>().apiKey,
    );
    _orTtsCtl = TextEditingController(
      text: prefs.getString('openrouter_tts_key') ??
          OpenRouterTtsService.instance.apiKey,
    );
    _loadFallbackVersionAsset();
  }

  Future<void> _loadFallbackVersionAsset() async {
    if (_envAppVersion.isNotEmpty && _envGitShaShort.isNotEmpty) return;
    try {
      final raw = await rootBundle.loadString('assets/version.json');
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        if (_envAppVersion.isEmpty && j['version'] != null) {
          _version = j['version'].toString();
        }
        if (_envAppBuild.isEmpty && j['versionCode'] != null) {
          _buildCode = j['versionCode'].toString();
        }
        if (_envGitShaShort.isEmpty && j['gitSha'] != null) {
          _gitSha = j['gitSha'].toString();
        }
        if (_envGitShaFull.isEmpty && j['gitShaFull'] != null) {
          _gitShaFull = j['gitShaFull'].toString();
        }
        if (_envGitBranch.isEmpty && j['gitBranch'] != null) {
          _gitBranch = j['gitBranch'].toString();
        }
        if (_envGitDirty.isEmpty && j['gitDirty'] is bool) {
          _gitDirty = j['gitDirty'] as bool;
        }
        if (_envBuildDate.isEmpty && j['buildDate'] != null) {
          _buildDate = j['buildDate'].toString();
        }
      });
    } catch (_) {}
  }

  Future<void> _verifyYoloModel() async {
    setState(() => _verifyingYolo = true);
    final ok = await YoloDetector.instance.ensureModel();
    if (!mounted) return;
    setState(() => _verifyingYolo = false);
    final st = YoloDetector.instance.status;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'YOLO26-Nano ready (${st.source}, ${(st.sizeBytes / (1024 * 1024)).toStringAsFixed(2)} MB)'
              : 'YOLO26-Nano native channel inactive on this host (${st.error ?? st.source})',
        ),
      ),
    );
  }

  String get _versionDisplay {
    final dirty = _gitDirty ? ' (dirty)' : '';
    return 'SpectruLenPor v$_version (build $_buildCode) — $_gitSha on $_gitBranch$dirty';
  }

  String get _fullVersionString {
    return '''SpectruLenPor
Version: $_version
Build code: $_buildCode
Git SHA (short): $_gitSha
Git SHA (full): $_gitShaFull
Git branch: $_gitBranch
Working tree dirty: ${_gitDirty ? 'YES' : 'no'}
Built at: $_buildDate''';
  }

  void _copyFullVersion() {
    Clipboard.setData(ClipboardData(text: _fullVersionString));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Full version copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  void dispose() {
    _mdKeyCtl.dispose();
    _orLlmCtl.dispose();
    _orTtsCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<RecognitionState>();
    final prefs = context.read<SharedPreferences>();
    final theme = Theme.of(context);
    final onnx = OnnxVisionService.instance;
    final md = MoondreamService.instance;
    final yolo = YoloDetector.instance;
    final l = AppLocalizations.of(context);
    final isAr = state.isArabic;

    return Scaffold(
      appBar: AppBar(title: Text(l.settings)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          // ---------------- Language ----------------
          _sectionHeader(theme, Icons.translate_rounded, 'Language · اللغة'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'en', label: Text('English')),
                  ButtonSegment(value: 'ar', label: Text('العربية')),
                ],
                selected: {state.localeCode.startsWith('ar') ? 'ar' : 'en'},
                onSelectionChanged: (sel) async {
                  await state.setLocale(sel.first);
                  appLocale.value = Locale(sel.first);
                },
                style: SegmentedButton.styleFrom(
                  selectedBackgroundColor: palette.AppColors.dustyLavender,
                  selectedForegroundColor: Colors.white,
                ),
              ),
            ),
          ),

          // ---------------- Execution Policy & YOLO26-Nano ----------------
          _sectionHeader(
            theme,
            Icons.cloud_sync_rounded,
            isAr
                ? 'سياسة النماذج السحابية والمحلية (YOLO26-Nano)'
                : 'Cloud-Only Policy & Local YOLO26-Nano',
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: Icon(
                      state.cloudOnly
                          ? Icons.cloud_done_rounded
                          : Icons.hub_rounded,
                      color: palette.AppColors.dustyLavender,
                    ),
                    title: Text(
                      isAr
                          ? 'النماذج السحابية فقط (باستثناء YOLO26-Nano)'
                          : 'Cloud-only models (except YOLO26-Nano)',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      isAr
                          ? 'يبقى نموذج الرؤية YOLO26-Nano محلياً دائماً لرصد الصناديق التفاعلية، بينما تعمل جميع النماذج الأخرى (Moondream3 وOpenRouter والصوت) سحابياً فقط بدون بدائل محلية.'
                          : 'Keeps YOLO26-Nano strictly local on-device for real-time bounding boxes while routing VLM (Moondream3), LLM (OpenRouter), and TTS exclusively to cloud models.',
                      style: const TextStyle(fontSize: 12.5, height: 1.4),
                    ),
                    value: state.cloudOnly,
                    onChanged: (v) => state.cloudOnly = v,
                  ),
                  const Divider(height: 20),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        yolo.isReady
                            ? Icons.verified_rounded
                            : Icons.memory_rounded,
                        size: 20,
                        color: yolo.isReady
                            ? palette.AppColors.success
                            : palette.AppColors.dustyMauve,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isAr
                                  ? 'محرك الرؤية المحلي YOLO26-Nano ONNX'
                                  : 'YOLO26-Nano Local ONNX Engine',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13.5,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              yolo.isReady
                                  ? 'Ready · source=${yolo.status.source} · ${(yolo.status.sizeBytes / (1024 * 1024)).toStringAsFixed(2)} MB · last=${yolo.lastInferenceMs} ms'
                                  : 'Bundled asset assets/models/yolo26n.onnx (5.04 MB) + first-startup staging & HTTPS auto-download ready.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: palette.AppColors.inkSoft,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: OutlinedButton.icon(
                      onPressed: _verifyingYolo ? null : _verifyYoloModel,
                      icon: const Icon(Icons.download_done_rounded, size: 17),
                      label: Text(
                        isAr
                            ? 'فحص / تجهيز نموذج YOLO26-Nano'
                            : 'Verify / Stage YOLO26-Nano',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ---------------- Knowledge Base & Search Mode ----------------
          _sectionHeader(
            theme,
            Icons.manage_search_rounded,
            isAr
                ? 'وضع البحث العلمي والمراجع المدمجة'
                : 'Scientific Knowledge Search Mode',
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SegmentedButton<DocsSearchMode>(
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
                    selected: {state.searchMode},
                    onSelectionChanged: (sel) => state.searchMode = sel.first,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    switch (state.searchMode) {
                      DocsSearchMode.strict => isAr
                          ? 'صارم: يطابق الرموز الكيميائية وأرقام CAS والأسماء الدقيقة فقط من الجدول الدوري وPubChem وويكيبيديا.'
                          : 'Strict: Exact symbol, formula, CAS, and canonical title matches across 119 elements, 110 compounds, PubChem & Wikipedia.',
                      DocsSearchMode.detailed => isAr
                          ? 'مفصل: يعرض الخصائص الذرية والفيزيائية والإلكترونية ومخاطر السلامة كاملة مع المراجع السحابية.'
                          : 'Detailed: Full atomic, physical, electronic & GHS safety property cards plus PubChem, Wikipedia & Web Search.',
                      DocsSearchMode.semantic => isAr
                          ? 'دلالي: يربط تسميات YOLO بالمواد والمركبات الكيميائية المرتبطة تلقائياً مع البحث الهجين.'
                          : 'Semantic: Expands visual object labels into constituent materials, chemicals, safety docs, PubChem, Wikipedia & Web Search.',
                    },
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: palette.AppColors.inkSoft,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ---------------- Internal Database & Saved History ----------------
          _sectionHeader(
            theme,
            Icons.storage_rounded,
            isAr
                ? 'قاعدة البيانات الداخلية والسجل'
                : 'Internal Database & History',
          ),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(
                    Icons.history_edu_rounded,
                    color: palette.AppColors.dustyLavender,
                  ),
                  title: Text(
                    isAr
                        ? 'المحادثات المحفوظة ومستكشف الموسوعة العلمية'
                        : 'Saved Chats, Docs Explorer & Activity',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    isAr
                        ? 'استعراض المحادثات السابقة والبحث في 119 عنصراً و110 مركبات'
                        : 'Resume past sessions, search bundled knowledge & inspect activity',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const HistoryScreen()),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(
                    Icons.troubleshoot_rounded,
                    color: palette.AppColors.dustyLavender,
                  ),
                  title: Text(
                    isAr
                        ? 'فاحص قاعدة البيانات والسجلات والأعطال'
                        : 'Database, Cache, Logs, Hangs & Traces',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    'Engine: ${InternalDatabaseService.instance.engineName} · 9 tables active',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const DiagnosticsDbScreen(),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ---------------- Moondream3 cloud (primary vision) ----------------
          _sectionHeader(
              theme, Icons.auto_awesome, 'Moondream3 cloud — primary vision'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _mdKeyCtl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: l.moondreamApiKeyLabel,
                      helperText: l.moondreamApiKeyHint,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) {
                      prefs.setString('moondream_api_key', v);
                      md.apiKey = v;
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        md.isCloudConfigured
                            ? Icons.cloud_done
                            : Icons.cloud_off,
                        size: 18,
                        color: md.isCloudConfigured
                            ? palette.AppColors.success
                            : palette.AppColors.silver,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          md.isCloudConfigured
                              ? l.moondreamCloudEnabled
                              : l.moondreamCloudDisabled,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: palette.AppColors.inkSoft),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Fallbacks when offline / rate-limited (2 req/s): local '
                    'Moondream GGUF → ONNX classifier → ML Kit OCR.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: palette.AppColors.inkSoft),
                  ),
                ],
              ),
            ),
          ),

          // ---------------- OpenRouter (LLM + TTS keys) ----------------
          _sectionHeader(theme, Icons.key, 'OpenRouter API'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _orLlmCtl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: l.openRouterLlmKeyLabel,
                      helperText: l.openRouterLlmKeyHint,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) {
                      prefs.setString('openrouter_llm_key', v);
                      context.read<OpenRouterService>().apiKey = v;
                    },
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _orTtsCtl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: l.openRouterTtsKeyLabel,
                      helperText: l.openRouterTtsKeyHint,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) {
                      prefs.setString('openrouter_tts_key', v);
                      OpenRouterTtsService.instance.configure(apiKey: v);
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Moondream3 produces the factual analysis; the LLM '
                    'grounds it with inline [n] citations and auto-updating '
                    'structured scientific context.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: palette.AppColors.inkSoft),
                  ),
                ],
              ),
            ),
          ),

          // ---------------- Text+reasoning chain ----------------
          _sectionHeader(theme, Icons.psychology_alt, l.upstreamFallbackHeader),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  for (var i = 0; i < OpenRouterService.modelChain.length; i++)
                    RadioListTile<int>(
                      title: Text(
                        switch (i) {
                          0 => l.modelGemma26,
                          1 => l.modelInkling,
                          _ => l.modelNemotron,
                        },
                        style: const TextStyle(fontSize: 13.5),
                      ),
                      value: i,
                      groupValue: state.upstreamStartModel,
                      onChanged: (v) => state.upstreamStartModel = v!,
                      activeColor: palette.AppColors.dustyLavender,
                    ),
                  const Divider(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      l.reasoningTokensLabel,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      l.reasoningTokensHint,
                      style: const TextStyle(fontSize: 12.5, height: 1.4),
                    ),
                    value: state.captureReasoningTokens,
                    onChanged: (v) => state.captureReasoningTokens = v,
                  ),
                  if (state.reasoningTokens != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          'Last run reasoning tokens: ${state.reasoningTokens} '
                          '· model: ${state.lastModelUsed}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: palette.AppColors.dustyLavender,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),

          // ---------------- Diagnostics ----------------
          _sectionHeader(theme, Icons.monitor_heart, l.diagnosticsHeader),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _diagRow(
                    theme,
                    l.diagnosticsCloud,
                    md.isCloudConfigured
                        ? l.moondreamCloudEnabled
                        : l.moondreamCloudDisabled,
                  ),
                  _diagRow(
                    theme,
                    l.diagnosticsLastModel,
                    state.upstreamStatus == UpstreamStatus.idle
                        ? '—'
                        : state.lastModelUsed,
                  ),
                  _diagRow(
                    theme,
                    l.diagnosticsReasoningTokens,
                    state.reasoningTokens?.toString() ?? '—',
                  ),
                  _diagRow(
                    theme,
                    l.diagnosticsTts,
                    OpenRouterTtsService.ttsModel,
                  ),
                ],
              ),
            ),
          ),

          // ---------------- Local AI status ----------------
          _sectionHeader(theme, Icons.memory, 'Local AI — offline fallbacks'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _engineRow(
                    theme,
                    ready: onnx.isReady,
                    readyText:
                        'ONNX Runtime Mobile — ${onnx.labelCount} classes loaded',
                    missingText:
                        'No ONNX classifier bundled — YOLO26-Nano ONNX object '
                        'detection runs natively via ONNX Runtime Android.',
                  ),
                  const SizedBox(height: 8),
                  _engineRow(
                    theme,
                    ready: LocalVisionService.instance.moondreamAvailable,
                    readyText:
                        'Local Moondream GGUF: ${LocalVisionService.instance.moondreamModelPath}',
                    missingText:
                        'Local Moondream not deployed (README → Moondream '
                        'native build). Cloud tier covers it for now.',
                  ),
                  const SizedBox(height: 10),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      l.ttsNative.split('(').first.trim(),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: const Text(
                      'Speak the analysis aloud automatically (native engine '
                      'offline, or streamed fish-audio when enabled below).',
                      style: TextStyle(fontSize: 12.5, height: 1.4),
                    ),
                    value: state.liveSpeak,
                    onChanged: (v) => state.liveSpeak = v,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      l.deepReasoning,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: const Text(
                      'Streams the local analysis through OpenRouter for a '
                      'cleaner spoken explanation + hazard check.',
                      style: TextStyle(fontSize: 12.5, height: 1.4),
                    ),
                    value: state.deepReasonEnabled,
                    onChanged: (v) => state.deepReasonEnabled = v,
                  ),
                ],
              ),
            ),
          ),

          // ---------------- Pipeline ----------------
          _sectionHeader(theme, Icons.speed, 'Pipeline'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Analysis cadence',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text(
                        '${state.fps} fps',
                        style: const TextStyle(
                          color: palette.AppColors.dustyLavender,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: state.fps.toDouble(),
                    min: 1,
                    max: 4,
                    divisions: 3,
                    label: '${state.fps}',
                    onChanged: (v) => state.fps = v.round(),
                  ),
                  Text(
                    '1 fps is the sweet spot for battery AND for the free '
                    'cloud tiers (Moondream allows 2 req/s).',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: palette.AppColors.inkSoft),
                  ),
                  const Divider(height: 24),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Camera rotation',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text(
                        '${context.read<PhoneCameraService>().quarterTurns * 90}°',
                        style: const TextStyle(
                          color: palette.AppColors.dustyLavender,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: context
                        .read<PhoneCameraService>()
                        .quarterTurns
                        .toDouble(),
                    min: 0,
                    max: 3,
                    divisions: 3,
                    label:
                        '${context.read<PhoneCameraService>().quarterTurns * 90}°',
                    onChanged: (v) {
                      context.read<PhoneCameraService>().quarterTurns =
                          v.round();
                      setState(() {});
                    },
                  ),
                ],
              ),
            ),
          ),

          // ---------------- TTS ----------------
          _sectionHeader(theme, Icons.record_voice_over, 'Voice output'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      l.fishAudioTts,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      l.fishAudioTtsSubtitle,
                      style: const TextStyle(fontSize: 12.5, height: 1.4),
                    ),
                    value: state.useOpenRouterTts,
                    onChanged: (v) => state.useOpenRouterTts = v,
                  ),
                  Text(
                    'Model: ${OpenRouterTtsService.ttsModel} — audio bytes are '
                    'streamed into the player as they download (first sound '
                    'without waiting for the full file). When off, the native '
                    'Android engine narrates per-sentence (lowest latency, '
                    'works offline).',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: palette.AppColors.inkSoft),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: state.useOpenRouterTts
                        ? () {
                            OpenRouterTtsService.instance.speakMarkdown(
                              'Voice test. This is SpectruLenPor, your '
                              'spectrum analysis assistant. أنا مساعدك '
                              'الصوتي للتحليل الطيفي.',
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('${l.testVoice} — streaming…'),
                              ),
                            );
                          }
                        : null,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(l.testVoice),
                  ),
                ],
              ),
            ),
          ),

          // ---------------- About ----------------
          _sectionHeader(theme, Icons.info_outline, 'About'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                l.aboutBody,
                style: AppTypography.paragraphOf(
                  context,
                  color: palette.AppColors.inkSoft,
                ),
              ),
            ),
          ),

          // ---------------- Version ----------------
          _sectionHeader(theme, Icons.verified_outlined, 'Build & Version'),
          _VersionCard(
            versionDisplay: _versionDisplay,
            version: _version,
            buildCode: _buildCode,
            gitShaShort: _gitSha,
            gitShaFull: _gitShaFull,
            gitBranch: _gitBranch,
            gitDirty: _gitDirty,
            buildDate: _buildDate,
            onCopy: _copyFullVersion,
          ),
        ],
      ),
    );
  }

  Widget _diagRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.AppColors.inkSoft,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.AppColors.dustyLavender,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _engineRow(
    ThemeData theme, {
    required bool ready,
    required String readyText,
    required String missingText,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          ready ? Icons.check_circle : Icons.info_outline,
          size: 18,
          color: ready ? palette.AppColors.success : palette.AppColors.silver,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            ready ? readyText : missingText,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: palette.AppColors.inkSoft, height: 1.4),
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(ThemeData theme, IconData icon, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: palette.AppColors.dustyLavender),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.0,
                color: palette.AppColors.inkSoft,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VersionCard extends StatelessWidget {
  final String versionDisplay;
  final String version;
  final String buildCode;
  final String gitShaShort;
  final String gitShaFull;
  final String gitBranch;
  final bool gitDirty;
  final String buildDate;
  final VoidCallback onCopy;

  const _VersionCard({
    required this.versionDisplay,
    required this.version,
    required this.buildCode,
    required this.gitShaShort,
    required this.gitShaFull,
    required this.gitBranch,
    required this.gitDirty,
    required this.buildDate,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shortFull = gitShaFull.length > 16
        ? '${gitShaFull.substring(0, 16)}…'
        : gitShaFull;

    return Card(
      child: InkWell(
        onTap: onCopy,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.tag,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      versionDisplay,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.content_copy,
                    size: 15,
                    color: theme.colorScheme.outline,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _versionRow('Version', 'v$version'),
              _versionRow('Build code', buildCode),
              _versionRow('Git SHA (short)', gitShaShort),
              _versionRow('Git SHA (full)', shortFull),
              _versionRow('Git branch', gitBranch),
              _versionRow(
                'Working tree dirty',
                gitDirty ? 'YES (uncommitted changes)' : 'no (clean)',
              ),
              _versionRow('Built at', buildDate),
              const SizedBox(height: 8),
              Text(
                'Tap to copy full version string to clipboard',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _versionRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1.5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 135,
              child: Text(
                k,
                style: const TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 12,
                ),
              ),
            ),
            Expanded(
              child: Text(
                v,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
      );
}
