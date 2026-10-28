import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config/app_secrets.dart';
import 'l10n/app_localizations.dart';
import 'models/recognition_state.dart';
import 'screens/diagnostics_db_screen.dart';
import 'screens/history_screen.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'services/bluetooth_camera_service.dart';
import 'services/docs_search_service.dart';
import 'services/internal_db_service.dart';
import 'services/local_vision_service.dart';
import 'services/mic_service.dart';
import 'services/moondream_service.dart';
import 'services/native_tts_service.dart';
import 'services/onnx_vision_service.dart';
import 'services/openrouter_service.dart';
import 'services/openrouter_tts_service.dart';
import 'services/phone_camera_service.dart';
import 'services/yolo_detector.dart';
import 'utils/app_theme.dart';

/// Reactive app locale — Settings and Home flip this, MaterialApp rebuilds.
final ValueNotifier<Locale> appLocale =
    ValueNotifier<Locale>(const Locale('en'));

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  // 1. Initialize Internal Database (SQLite WAL on Android / atomic file store fallback)
  await InternalDatabaseService.instance.init();

  // 2. Wire global crash & uncaught exception persistence + UI HangWatchdog
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    unawaited(InternalDatabaseService.instance.recordCrashOrHang(
      kind: 'flutter_error',
      summary: details.exceptionAsString(),
      stackTrace: details.stack?.toString(),
      context: {'library': details.library ?? 'flutter'},
    ));
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    unawaited(InternalDatabaseService.instance.recordCrashOrHang(
      kind: 'uncaught_async',
      summary: error.toString(),
      stackTrace: stack.toString(),
    ));
    return true;
  };
  HangWatchdog.instance.start();

  final prefs = await SharedPreferences.getInstance();
  final secrets = await AppSecrets.load();

  // 3. Stage & initialize YOLO26-Nano (bundled asset + auto-download verification)
  //    alongside all local/cloud scientific services.
  await LocalVisionService.instance.init();
  await YoloDetector.instance.init();
  await MicService.instance.init();
  await DocsSearchService.instance.init();
  await OnnxVisionService.instance.init();
  await NativeTtsService.instance.init();
  await OpenRouterTtsService.instance.init();
  MoondreamService.instance.apiKey = prefs.getString('moondream_api_key') ??
      (secrets['moondream'] ?? MoondreamService.defaultApiKey);

  appLocale.value = Locale(prefs.getString('locale') ?? 'en');
  unawaited(InternalDatabaseService.instance.recordActivity('app_startup'));

  runApp(SpectruLenPorApp(prefs: prefs, secrets: secrets));
}

class SpectruLenPorApp extends StatelessWidget {
  final SharedPreferences prefs;
  final Map<String, String> _secrets;

  const SpectruLenPorApp({
    super.key,
    required this.prefs,
    required Map<String, String> secrets,
  }) : _secrets = secrets;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<SharedPreferences>.value(value: prefs),
        Provider<InternalDatabaseService>.value(
          value: InternalDatabaseService.instance,
        ),
        Provider<BluetoothCameraService>(
          create: (_) => BluetoothCameraService()..init(),
          dispose: (_, svc) => svc.dispose(),
        ),
        Provider<PhoneCameraService>.value(value: PhoneCameraService.instance),
        Provider<LocalVisionService>.value(value: LocalVisionService.instance),
        Provider<MoondreamService>.value(value: MoondreamService.instance),
        Provider<OpenRouterService>(
          create: (_) => OpenRouterService(
            apiKey: prefs.getString('openrouter_llm_key') ??
                prefs.getString('openrouter_api_key') ??
                _secrets['openrouter_llm'] ??
                OpenRouterService.defaultApiKey,
          ),
        ),
        Provider<OpenRouterTtsService>.value(
          value: OpenRouterTtsService.instance
            ..configure(
              apiKey: prefs.getString('openrouter_tts_key') ??
                  _secrets['openrouter_tts'] ??
                  OpenRouterTtsService.defaultApiKey,
            ),
        ),
        Provider<NativeTtsService>.value(value: NativeTtsService.instance),
        ChangeNotifierProvider(
          create: (ctx) => RecognitionState(
            bluetooth: ctx.read<BluetoothCameraService>(),
            phoneCamera: ctx.read<PhoneCameraService>(),
            vision: ctx.read<LocalVisionService>(),
            openRouter: ctx.read<OpenRouterService>(),
            openRouterTts: ctx.read<OpenRouterTtsService>(),
            nativeTts: ctx.read<NativeTtsService>(),
            prefs: prefs,
            onLocaleChanged: (code) {
              if (appLocale.value.languageCode != code) {
                appLocale.value = Locale(code);
              }
            },
          ),
        ),
      ],
      child: ValueListenableBuilder<Locale>(
        valueListenable: appLocale,
        builder: (context, locale, _) => MaterialApp(
          onGenerateTitle: (ctx) =>
              '${AppLocalizations.of(ctx).appName} — Smart Scientific Glasses',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(locale),
          locale: locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          initialRoute: '/',
          routes: {
            '/': (_) => const HomeScreen(),
            '/settings': (_) => const SettingsScreen(),
            '/history': (_) => const HistoryScreen(),
            '/diagnostics': (_) => const DiagnosticsDbScreen(),
          },
        ),
      ),
    );
  }
}
