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
import '../services/home_screen_widget_service.dart';
import '../services/notification_service.dart';
import '../services/onnx_vision_service.dart';
import '../services/openrouter_service.dart';
import '../services/openrouter_tts_service.dart';
import '../services/supertonic_tts_service.dart';
import '../services/phone_camera_service.dart';
import '../services/yolo_detector.dart';
import '../utils/app_theme.dart' as palette;
import '../utils/app_typography.dart';
import 'diagnostics_db_screen.dart';
import 'benchmark_lab_screen.dart';
import 'history_screen.dart';
import '../utils/app_icons.dart';
import '../widgets/openrouter_model_selector.dart';

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
  bool _installingSupertonic = false;
  bool _installingVosk = false;
  String? _speechInstallStatus;
  int _selectedCategory = 0;

  String _version = _envAppVersion.isNotEmpty ? _envAppVersion : 'not supplied';
  String _buildCode = _envAppBuild.isNotEmpty ? _envAppBuild : 'not supplied';
  String _gitSha =
      _envGitShaShort.isNotEmpty ? _envGitShaShort : 'not supplied';
  String _gitShaFull =
      _envGitShaFull.isNotEmpty ? _envGitShaFull : 'not supplied';
  String _gitBranch = _envGitBranch.isNotEmpty ? _envGitBranch : 'not supplied';
  bool? _gitDirty = _envGitDirty == 'true'
      ? true
      : _envGitDirty == 'false'
          ? false
          : null;
  String _buildDate = _envBuildDate.isNotEmpty ? _envBuildDate : 'not supplied';

  @override
  void initState() {
    super.initState();
    final prefs = context.read<SharedPreferences>();
    _selectedCategory = (prefs.getInt('settings_category') ?? 0).clamp(0, 6);
    context.read<RecognitionState>().mic.loadSettings().then((_) {
      if (mounted) setState(() {});
    });
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

  void _selectCategory(int index) {
    if (_selectedCategory == index) return;
    setState(() => _selectedCategory = index);
    context.read<SharedPreferences>().setInt('settings_category', index);
  }

  Future<void> _installSupertonic() async {
    setState(() {
      _installingSupertonic = true;
      _speechInstallStatus = 'Downloading local speech models…';
    });
    try {
      await SupertonicTtsService.instance.downloadModels(
        onProgress: (file, received, total) {
          if (!mounted) return;
          final progress =
              total > 0 ? ' ${(received / total * 100).round()}%' : '';
          setState(() => _speechInstallStatus = 'Downloading $file$progress');
        },
      );
      if (!mounted) return;
      setState(() => _speechInstallStatus =
          'Supertonic-3 is installed and ready offline.');
      _showSettingsSaved();
    } catch (error) {
      if (!mounted) return;
      setState(
          () => _speechInstallStatus = 'Model installation failed: $error');
    } finally {
      if (mounted) setState(() => _installingSupertonic = false);
    }
  }

  Future<void> _installVosk() async {
    final state = context.read<RecognitionState>();
    setState(() {
      _installingVosk = true;
      _speechInstallStatus = 'Installing offline speech model…';
    });
    final ready = await state.mic.prepareOfflineModel(
      localeId: state.isArabic ? 'ar-EG' : 'en-US',
    );
    if (!mounted) return;
    setState(() {
      _installingVosk = false;
      _speechInstallStatus = ready
          ? (state.isArabic
              ? 'Arabic offline model is ready.'
              : 'English offline model is ready.')
          : (state.mic.lastError ?? 'Could not install the offline model.');
    });
    if (ready) _showSettingsSaved();
  }

  void _showSettingsSaved() {
    if (!mounted) return;
    final isAr = context.read<RecognitionState>().isArabic;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(isAr ? 'تم تحديث الإعدادات' : 'Settings updated'),
          duration: const Duration(milliseconds: 1300),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _loadFallbackVersionAsset() async {
    if (_envAppVersion.isNotEmpty && _envAppBuild.isNotEmpty) return;
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
      });
    } catch (_) {}
  }

  Future<void> _verifyYoloModel() async {
    setState(() => _verifyingYolo = true);
    final ok = (await YoloDetector.instance.ensureModel()).ready;
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
    final dirtySuffix = _gitDirty == null
        ? ' (source metadata unavailable)'
        : _gitDirty!
            ? ' (dirty)'
            : ' (clean)';
    return 'SpectruLenPor v$_version (build $_buildCode) — '
        '$_gitSha on $_gitBranch$dirtySuffix';
  }

  String get _fullVersionString {
    final dirtyState = _gitDirty == null
        ? 'unknown (metadata not injected)'
        : _gitDirty!
            ? 'YES (uncommitted changes)'
            : 'no (clean)';
    return '''SpectruLenPor
Version: $_version
Build code: $_buildCode
Git SHA (short): $_gitSha
Git SHA (full): $_gitShaFull
Git branch: $_gitBranch
Working tree dirty: $dirtyState
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
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 760;
          final categoryLabels = isAr
              ? const [
                  'عام',
                  'الذكاء الاصطناعي',
                  'الصوت',
                  'الأداء',
                  'النظارة',
                  'البيانات',
                  'حول'
                ]
              : const [
                  'General',
                  'AI & Models',
                  'Voice',
                  'Performance',
                  'Glasses',
                  'Data',
                  'About'
                ];
          const categoryIcons = <IconData>[
            AppIcons.settingsOutlined,
            AppIcons.psychologyAlt,
            AppIcons.recordVoiceOver,
            AppIcons.speed,
            AppIcons.wifiRounded,
            AppIcons.storageRounded,
            AppIcons.infoOutline,
          ];
          return Column(
            children: [
              if (!wide)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 12, 4),
                  child: Row(
                    children: [
                      for (var i = 0; i < categoryLabels.length; i++) ...[
                        if (i > 0) const SizedBox(width: 7),
                        ChoiceChip(
                          selected: _selectedCategory == i,
                          avatar: Icon(categoryIcons[i], size: 16),
                          label: Text(categoryLabels[i]),
                          onSelected: (_) => _selectCategory(i),
                        ),
                      ],
                    ],
                  ),
                ),
              Expanded(
                child: Row(
                  children: [
                    if (wide)
                      NavigationRail(
                        selectedIndex: _selectedCategory,
                        onDestinationSelected: _selectCategory,
                        labelType: NavigationRailLabelType.all,
                        minWidth: 86,
                        destinations: [
                          for (var i = 0; i < categoryLabels.length; i++)
                            NavigationRailDestination(
                              icon: Icon(categoryIcons[i]),
                              label: Text(categoryLabels[i]),
                            ),
                        ],
                      ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        children: [
                          if (_selectedCategory == 0) ...[
                            // ---------------- Language ----------------
                            _sectionHeader(theme, AppIcons.translateRounded,
                                'Language · اللغة'),
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: SegmentedButton<String>(
                                  segments: const [
                                    ButtonSegment(
                                        value: 'en', label: Text('English')),
                                    ButtonSegment(
                                        value: 'ar', label: Text('العربية')),
                                  ],
                                  selected: {
                                    state.localeCode.startsWith('ar')
                                        ? 'ar'
                                        : 'en'
                                  },
                                  onSelectionChanged: (sel) async {
                                    await state.setLocale(sel.first);
                                    appLocale.value = Locale(sel.first);
                                    _showSettingsSaved();
                                  },
                                  style: SegmentedButton.styleFrom(
                                    selectedBackgroundColor:
                                        palette.AppColors.dustyLavender,
                                    selectedForegroundColor: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                            _sectionHeader(
                              theme,
                              AppIcons.infoOutline,
                              isAr
                                  ? 'اختصارات الشاشة الرئيسية والتنبيهات'
                                  : 'Home screen & notifications',
                            ),
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    OutlinedButton.icon(
                                      onPressed: () async {
                                        final granted =
                                            await AppNotificationService
                                                .instance
                                                .requestPermission();
                                        if (!mounted) return;
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content: Text(granted
                                                ? (isAr
                                                    ? 'تم تفعيل التنبيهات'
                                                    : 'Notifications enabled')
                                                : (isAr
                                                    ? 'لم يتم منح إذن التنبيهات'
                                                    : 'Notification permission was not granted')),
                                          ),
                                        );
                                      },
                                      icon:
                                          const Icon(AppIcons.volumeUpRounded),
                                      label: Text(isAr
                                          ? 'تفعيل التنبيهات التفاعلية'
                                          : 'Enable interactive notifications'),
                                    ),
                                    const SizedBox(height: 6),
                                    OutlinedButton.icon(
                                      onPressed: () async {
                                        final added =
                                            await HomeScreenWidgetService
                                                .instance
                                                .requestPin();
                                        if (!mounted) return;
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content: Text(added
                                                ? (isAr
                                                    ? 'تم إرسال طلب إضافة الأداة'
                                                    : 'Home screen widget request sent')
                                                : (isAr
                                                    ? 'أضف الأداة من قائمة الأدوات في الشاشة الرئيسية'
                                                    : 'Use your launcher widget picker to add SpectruLenPor')),
                                          ),
                                        );
                                      },
                                      icon: const Icon(
                                          AppIcons.smartphoneRounded),
                                      label: Text(isAr
                                          ? 'إضافة أداة للشاشة الرئيسية'
                                          : 'Add home screen widget'),
                                    ),
                                    Text(
                                      isAr
                                          ? 'تعرض الأداة حالة التحليل والنموذج النشط، مع اختصارات لفتح التطبيق والتقاط صورة.'
                                          : 'The widget shows the latest analysis and active model, with shortcuts to open the app or start a capture.',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            // ---------------- Execution Policy & YOLO26-Nano ----------------
                            _sectionHeader(
                              theme,
                              AppIcons.cloudSyncRounded,
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
                                            ? AppIcons.cloudDoneRounded
                                            : AppIcons.hubRounded,
                                        color: palette.AppColors.dustyLavender,
                                      ),
                                      title: Text(
                                        isAr
                                            ? 'النماذج السحابية فقط (باستثناء YOLO26-Nano)'
                                            : 'Cloud-only models (except YOLO26-Nano)',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w700),
                                      ),
                                      subtitle: Text(
                                        isAr
                                            ? 'يبقى نموذج الرؤية YOLO26-Nano محلياً دائماً لرصد الصناديق التفاعلية، بينما تعمل جميع النماذج الأخرى (Moondream3 وOpenRouter والصوت) سحابياً فقط بدون بدائل محلية.'
                                            : 'Keeps YOLO26-Nano strictly local on-device for real-time bounding boxes while routing VLM (Moondream3), LLM (OpenRouter), and TTS exclusively to cloud models.',
                                        style: const TextStyle(
                                            fontSize: 12.5, height: 1.4),
                                      ),
                                      value: state.cloudOnly,
                                      onChanged: (v) {
                                        state.cloudOnly = v;
                                        _showSettingsSaved();
                                      },
                                    ),
                                    const Divider(height: 20),
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Icon(
                                          yolo.isReady
                                              ? AppIcons.verifiedRounded
                                              : AppIcons.memoryRounded,
                                          size: 20,
                                          color: yolo.isReady
                                              ? palette.AppColors.success
                                              : palette.AppColors.dustyMauve,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
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
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                  color:
                                                      palette.AppColors.inkSoft,
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
                                        onPressed: _verifyingYolo
                                            ? null
                                            : _verifyYoloModel,
                                        icon: const Icon(
                                            AppIcons.downloadDoneRounded,
                                            size: 17),
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
                              AppIcons.manageSearchRounded,
                              isAr
                                  ? 'وضع البحث العلمي والمراجع المدمجة'
                                  : 'Scientific Knowledge Search Mode',
                            ),
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    SegmentedButton<DocsSearchMode>(
                                      segments: [
                                        ButtonSegment(
                                          value: DocsSearchMode.strict,
                                          icon: const Icon(
                                              AppIcons.gavelRounded,
                                              size: 16),
                                          label: Text(isAr ? 'صارم' : 'Strict'),
                                        ),
                                        ButtonSegment(
                                          value: DocsSearchMode.detailed,
                                          icon: const Icon(
                                              AppIcons.listAltRounded,
                                              size: 16),
                                          label:
                                              Text(isAr ? 'مفصل' : 'Detailed'),
                                        ),
                                        ButtonSegment(
                                          value: DocsSearchMode.semantic,
                                          icon: const Icon(AppIcons.hubRounded,
                                              size: 16),
                                          label:
                                              Text(isAr ? 'دلالي' : 'Semantic'),
                                        ),
                                      ],
                                      selected: {state.searchMode},
                                      onSelectionChanged: (sel) {
                                        state.searchMode = sel.first;
                                        prefs.setString(
                                            'docs_search_mode', sel.first.name);
                                        _showSettingsSaved();
                                      },
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
                                      style:
                                          theme.textTheme.bodySmall?.copyWith(
                                        color: palette.AppColors.inkSoft,
                                        height: 1.4,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                          if (_selectedCategory == 5) ...[
                            // ---------------- Internal Database & Saved History ----------------
                            _sectionHeader(
                              theme,
                              AppIcons.storageRounded,
                              isAr
                                  ? 'قاعدة البيانات الداخلية والسجل'
                                  : 'Internal Database & History',
                            ),
                            Card(
                              child: Column(
                                children: [
                                  ListTile(
                                    leading: const Icon(
                                      AppIcons.historyEduRounded,
                                      color: palette.AppColors.dustyLavender,
                                    ),
                                    title: Text(
                                      isAr
                                          ? 'المحادثات المحفوظة ومستكشف الموسوعة العلمية'
                                          : 'Saved Chats, Docs Explorer & Activity',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600),
                                    ),
                                    subtitle: Text(
                                      isAr
                                          ? 'استعراض المحادثات السابقة والبحث في 119 عنصراً و110 مركبات'
                                          : 'Resume past sessions, search bundled knowledge & inspect activity',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    trailing: const Icon(
                                        AppIcons.chevronRightRounded),
                                    onTap: () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                          builder: (_) =>
                                              const HistoryScreen()),
                                    ),
                                  ),
                                  const Divider(height: 1),
                                  ListTile(
                                    leading: const Icon(
                                      AppIcons.troubleshootRounded,
                                      color: palette.AppColors.dustyLavender,
                                    ),
                                    title: Text(
                                      isAr
                                          ? 'فاحص قاعدة البيانات والسجلات والأعطال'
                                          : 'Database, Cache, Logs, Hangs & Traces',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600),
                                    ),
                                    subtitle: Text(
                                      'Engine: ${InternalDatabaseService.instance.engineName} · 9 tables active',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    trailing: const Icon(
                                        AppIcons.chevronRightRounded),
                                    onTap: () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const DiagnosticsDbScreen(),
                                      ),
                                    ),
                                  ),
                                  const Divider(height: 1),
                                  ListTile(
                                    leading: const Icon(
                                      AppIcons.speed,
                                      color: palette.AppColors.dustyLavender,
                                    ),
                                    title: Text(
                                      isAr ? 'مختبر الأداء والدقة' : 'Benchmark Lab',
                                      style: const TextStyle(fontWeight: FontWeight.w600),
                                    ),
                                    subtitle: Text(
                                      isAr
                                          ? 'قياس السرعة والدقة والصوت والنماذج مع تقارير JSON'
                                          : 'Measure latency, accuracy, speech engines and models; export JSON reports',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    trailing: const Icon(AppIcons.chevronRightRounded),
                                    onTap: () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => const BenchmarkLabScreen(),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          if (_selectedCategory == 1) ...[
                            // ---------------- Moondream3 cloud (primary vision) ----------------
                            _sectionHeader(
                              theme,
                              AppIcons.autoAwesome,
                              'Moondream3 cloud — primary vision',
                            ),
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
                                      onEditingComplete: _showSettingsSaved,
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Icon(
                                          md.isCloudConfigured
                                              ? AppIcons.cloudDone
                                              : AppIcons.cloudOff,
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
                                                ?.copyWith(
                                              color: palette.AppColors.inkSoft,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      'Fallbacks when offline / rate-limited (2 req/s): local '
                                      'Moondream GGUF → ONNX classifier → ML Kit OCR.',
                                      style:
                                          theme.textTheme.bodySmall?.copyWith(
                                        color: palette.AppColors.inkSoft,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            // ---------------- OpenRouter (LLM + TTS keys) ----------------
                            _sectionHeader(
                                theme, AppIcons.key, 'OpenRouter API'),
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
                                        prefs.setString(
                                            'openrouter_llm_key', v);
                                        context
                                            .read<OpenRouterService>()
                                            .apiKey = v;
                                      },
                                      onEditingComplete: _showSettingsSaved,
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
                                        prefs.setString(
                                            'openrouter_tts_key', v);
                                        OpenRouterTtsService.instance
                                            .configure(apiKey: v);
                                      },
                                      onEditingComplete: _showSettingsSaved,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Moondream3 produces the factual analysis; the LLM '
                                      'grounds it with inline [n] citations and auto-updating '
                                      'structured scientific context.',
                                      style:
                                          theme.textTheme.bodySmall?.copyWith(
                                        color: palette.AppColors.inkSoft,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            // ---------------- Live OpenRouter model catalogue ----------------
                            _sectionHeader(
                              theme,
                              AppIcons.psychologyAlt,
                              isAr
                                  ? 'النماذج المجانية واختبارها'
                                  : 'Free models & model testing',
                            ),
                            OpenRouterModelSelector(
                              preferences: prefs,
                              service: context.read<OpenRouterService>(),
                            ),
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: Column(
                                  children: [
                                    SwitchListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(
                                        l.reasoningTokensLabel,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600),
                                      ),
                                      subtitle: Text(
                                        l.reasoningTokensHint,
                                        style: const TextStyle(
                                            fontSize: 12.5, height: 1.4),
                                      ),
                                      value: state.captureReasoningTokens,
                                      onChanged: (v) {
                                        state.captureReasoningTokens = v;
                                        _showSettingsSaved();
                                      },
                                    ),
                                    if (state.reasoningTokens != null)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 16),
                                        child: Align(
                                          alignment:
                                              AlignmentDirectional.centerStart,
                                          child: Text(
                                            'Last run reasoning tokens: \${state.reasoningTokens} '
                                            '· model: \${state.lastModelUsed}',
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                              color: palette
                                                  .AppColors.dustyLavender,
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
                            _sectionHeader(theme, AppIcons.monitorHeart,
                                l.diagnosticsHeader),
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
                                      state.upstreamStatus ==
                                              UpstreamStatus.idle
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
                          ],
                          if (_selectedCategory == 2) ...[
                            // ---------------- Local AI status ----------------
                            _sectionHeader(theme, AppIcons.memory,
                                'Local AI — offline fallbacks'),
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
                                      ready: LocalVisionService
                                          .instance.moondreamAvailable,
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
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600),
                                      ),
                                      subtitle: const Text(
                                        'Speak the analysis aloud automatically (native engine '
                                        'offline, or streamed fish-audio when enabled below).',
                                        style: TextStyle(
                                            fontSize: 12.5, height: 1.4),
                                      ),
                                      value: state.liveSpeak,
                                      onChanged: (v) {
                                        state.liveSpeak = v;
                                        _showSettingsSaved();
                                      },
                                    ),
                                    SwitchListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(
                                        l.deepReasoning,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600),
                                      ),
                                      subtitle: const Text(
                                        'Streams the local analysis through OpenRouter for a '
                                        'cleaner spoken explanation + hazard check.',
                                        style: TextStyle(
                                            fontSize: 12.5, height: 1.4),
                                      ),
                                      value: state.deepReasonEnabled,
                                      onChanged: (v) {
                                        state.deepReasonEnabled = v;
                                        _showSettingsSaved();
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                          if (_selectedCategory == 3) ...[
                            // ---------------- Pipeline ----------------
                            _sectionHeader(theme, AppIcons.speed, 'Pipeline'),
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
                                            style: TextStyle(
                                                fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                        Text(
                                          '${state.fps} fps',
                                          style: const TextStyle(
                                            color:
                                                palette.AppColors.dustyLavender,
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
                                      onChangeEnd: (_) => _showSettingsSaved(),
                                    ),
                                    Text(
                                      '1 fps is the sweet spot for battery AND for the free '
                                      'cloud tiers (Moondream allows 2 req/s).',
                                      style:
                                          theme.textTheme.bodySmall?.copyWith(
                                        color: palette.AppColors.inkSoft,
                                      ),
                                    ),
                                    const Divider(height: 24),
                                    Row(
                                      children: [
                                        const Expanded(
                                          child: Text(
                                            'Camera rotation',
                                            style: TextStyle(
                                                fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                        Text(
                                          '${context.read<PhoneCameraService>().quarterTurns * 90}°',
                                          style: const TextStyle(
                                            color:
                                                palette.AppColors.dustyLavender,
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
                                        context
                                            .read<PhoneCameraService>()
                                            .quarterTurns = v.round();
                                        setState(() {});
                                      },
                                      onChangeEnd: (_) => _showSettingsSaved(),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                          if (_selectedCategory == 2) ...[
                            // ---------------- TTS ----------------
                            _sectionHeader(theme, AppIcons.recordVoiceOver,
                                'Voice output'),
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Speech output engine',
                                        style: theme.textTheme.titleSmall),
                                    const SizedBox(height: 10),
                                    SegmentedButton<String>(
                                      showSelectedIcon: false,
                                      segments: const [
                                        ButtonSegment(
                                            value: 'fish',
                                            label: Text('Fish Audio')),
                                        ButtonSegment(
                                            value: 'supertonic',
                                            label: Text('Supertonic')),
                                        ButtonSegment(
                                            value: 'native',
                                            label: Text('System')),
                                      ],
                                      selected: {state.ttsEngine},
                                      onSelectionChanged: (selection) {
                                        state.ttsEngine = selection.first;
                                        _showSettingsSaved();
                                      },
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      switch (state.ttsEngine) {
                                        'supertonic' =>
                                          'Supertonic-3 runs locally on the device. Arabic and English are supported; its model bundle is downloaded once (about 400 MB), then works offline.',
                                        'native' =>
                                          'Android system TTS. Small footprint and offline when a matching voice is installed.',
                                        _ =>
                                          'Fish Audio through OpenRouter. Streams generated speech as audio arrives and requires an internet connection.',
                                      },
                                      style:
                                          theme.textTheme.bodySmall?.copyWith(
                                        color: palette.AppColors.inkSoft,
                                      ),
                                    ),
                                    if (state.ttsEngine == 'supertonic') ...[
                                      const SizedBox(height: 10),
                                      OutlinedButton.icon(
                                        onPressed: _installingSupertonic
                                            ? null
                                            : _installSupertonic,
                                        icon: _installingSupertonic
                                            ? const SizedBox(
                                                width: 16,
                                                height: 16,
                                                child:
                                                    CircularProgressIndicator(
                                                        strokeWidth: 2),
                                              )
                                            : const Icon(
                                                AppIcons.downloadDoneRounded),
                                        label: Text(_installingSupertonic
                                            ? 'Installing models…'
                                            : 'Install / update offline models'),
                                      ),
                                    ],
                                    if (_speechInstallStatus != null) ...[
                                      const SizedBox(height: 6),
                                      Text(_speechInstallStatus!,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                            color: palette.AppColors.inkSoft,
                                          )),
                                    ],
                                    const SizedBox(height: 12),
                                    OutlinedButton.icon(
                                      onPressed: () => state.speakText(
                                        'Voice test. This is SpectruLenPor, your spectrum analysis assistant. أنا مساعدك الصوتي للتحليل الطيفي.',
                                      ),
                                      icon: const Icon(AppIcons.playArrow),
                                      label: Text(l.testVoice),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                            _sectionHeader(
                                theme, AppIcons.recordVoiceOver, 'Voice input'),
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SegmentedButton<String>(
                                      showSelectedIcon: false,
                                      segments: const [
                                        ButtonSegment(
                                            value: 'system',
                                            label: Text('System')),
                                        ButtonSegment(
                                            value: 'vosk',
                                            label: Text('Vosk offline')),
                                      ],
                                      selected: {state.mic.engine},
                                      onSelectionChanged: (selection) async {
                                        await state.mic
                                            .setEngine(selection.first);
                                        if (mounted) setState(() {});
                                        _showSettingsSaved();
                                      },
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      state.mic.engine == 'vosk'
                                          ? (state.isArabic
                                              ? 'Arabic offline model (MGB-2, about 318 MB). It is trained mainly on broadcast Arabic, not specifically Egyptian dialect.'
                                              : 'English offline model (about 40 MB). Recognition runs on-device without a network connection.')
                                          : 'Uses the Android speech recognizer and whichever recognition service is installed on the phone.',
                                      style:
                                          theme.textTheme.bodySmall?.copyWith(
                                        color: palette.AppColors.inkSoft,
                                      ),
                                    ),
                                    if (state.mic.engine == 'vosk') ...[
                                      const SizedBox(height: 10),
                                      OutlinedButton.icon(
                                        onPressed: _installingVosk
                                            ? null
                                            : _installVosk,
                                        icon: _installingVosk
                                            ? const SizedBox(
                                                width: 16,
                                                height: 16,
                                                child:
                                                    CircularProgressIndicator(
                                                        strokeWidth: 2),
                                              )
                                            : const Icon(
                                                AppIcons.downloadDoneRounded),
                                        label: Text(_installingVosk
                                            ? 'Installing language model…'
                                            : 'Install current language model'),
                                      ),
                                      Text(
                                        'Automatic cleanup normalizes Arabic letter forms, common project terms, spacing and punctuation without rewriting uncertain words.',
                                        style:
                                            theme.textTheme.bodySmall?.copyWith(
                                          color: palette.AppColors.inkSoft,
                                        ),
                                      ),
                                    ],
                                    if (state.mic.lastError != null)
                                      Text(
                                        state.mic.lastError!,
                                        style:
                                            theme.textTheme.bodySmall?.copyWith(
                                          color: theme.colorScheme.error,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                          if (_selectedCategory == 6) ...[
                            // ---------------- About ----------------
                            _sectionHeader(
                                theme, AppIcons.infoOutline, 'About'),
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
                            _sectionHeader(theme, AppIcons.verifiedOutlined,
                                'Build & Version'),
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
                          if (_selectedCategory == 4) ...[
                            // ---------------- WiFi for glasses (UDP video) ----------------
                            _sectionHeader(
                                theme, AppIcons.wifiRounded, l.wifiConfigTitle),
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      state.wifiConnected
                                          ? (state.udpVideo.isStreaming
                                              ? l.wifiConnected
                                              : l.videoPaused)
                                          : l.wifiDisconnected,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13.5,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    if (state.wifiSsid.isNotEmpty)
                                      Text(
                                        l.setupNetwork(state.wifiSsid),
                                        style: const TextStyle(
                                          color: palette.AppColors.inkSoft,
                                          fontSize: 12,
                                          fontFamily: 'monospace',
                                        ),
                                      ),
                                    if (state.wifiIp.isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        l.setupEndpoint(state.wifiIp),
                                        style: const TextStyle(
                                          color: palette.AppColors.inkSoft,
                                          fontSize: 12,
                                          fontFamily: 'monospace',
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 10),
                                    Wrap(
                                      spacing: 8,
                                      children: [
                                        OutlinedButton.icon(
                                          onPressed: state.canUseBleControls
                                              ? state.requestWifiStatus
                                              : null,
                                          icon: const Icon(
                                              AppIcons.refreshRounded,
                                              size: 16),
                                          label: Text(l.refreshStatus),
                                        ),
                                        OutlinedButton.icon(
                                          onPressed: state.canUseBleControls
                                              ? state.restartGlasses
                                              : null,
                                          icon: const Icon(
                                              AppIcons.restartAltRounded,
                                              size: 16),
                                          label: Text(l.restartEsp),
                                        ),
                                        OutlinedButton.icon(
                                          onPressed: state.canUseBleControls
                                              ? state.shutdownGlasses
                                              : null,
                                          icon: const Icon(
                                            AppIcons.powerSettingsNewRounded,
                                            size: 16,
                                          ),
                                          label: Text(l.shutdownGlasses),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      state.canUseBleControls
                                          ? l.setupManualIpHint
                                          : l.wifiOnlyControlsUnavailable,
                                      style:
                                          theme.textTheme.bodySmall?.copyWith(
                                        color: palette.AppColors.inkSoft,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
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
          ready ? AppIcons.checkCircle : AppIcons.infoOutline,
          size: 18,
          color: ready ? palette.AppColors.success : palette.AppColors.silver,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            ready ? readyText : missingText,
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.AppColors.inkSoft,
              height: 1.4,
            ),
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
  final bool? gitDirty;
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
    final shortFull =
        gitShaFull.length > 16 ? '${gitShaFull.substring(0, 16)}…' : gitShaFull;

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
                  Icon(AppIcons.tag,
                      size: 18, color: theme.colorScheme.primary),
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
                    AppIcons.contentCopy,
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
                gitDirty == null
                    ? 'unknown (build metadata not injected)'
                    : gitDirty!
                        ? 'YES (uncommitted changes)'
                        : 'no (clean)',
              ),
              _versionRow('Built at', buildDate),
              const SizedBox(height: 8),
              Text(
                'Tap to copy full version string to clipboard',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
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
                style:
                    const TextStyle(fontWeight: FontWeight.w500, fontSize: 12),
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
