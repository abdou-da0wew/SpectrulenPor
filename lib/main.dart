import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'l10n/app_localizations.dart';
import 'config/app_secrets.dart';
import 'models/recognition_state.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'services/bluetooth_camera_service.dart';
import 'services/local_vision_service.dart';
import 'services/moondream_service.dart';
import 'services/native_tts_service.dart';
import 'services/onnx_vision_service.dart';
import 'services/openrouter_service.dart';
import 'services/openrouter_tts_service.dart';
import 'services/phone_camera_service.dart';
import 'services/yolo_detector.dart';
import 'services/mic_service.dart';
import 'utils/app_theme.dart';

/// Reactive app locale — Settings flips this, MaterialApp rebuilds.
/// RTL directionality is handled automatically by Material for 'ar'.
final ValueNotifier<Locale> appLocale =
    ValueNotifier<Locale>(const Locale('en'));

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // All four families (Jaro / Rubik / Space Mono / Zain) ship in assets —
  // never hit the network for fonts (deterministic UI, offline demo safe).
  GoogleFonts.config.allowRuntimeFetching = false;

  final prefs = await SharedPreferences.getInstance();
  final secrets = await AppSecrets.load();

  await LocalVisionService.instance.init();
  await YoloDetector.instance.init();  // v5.0: load YOLO26-Nano ONNX model
  await MicService.instance.init();    // v5.0: init Android SpeechRecognizer
  await OnnxVisionService.instance.init(); // silent no-op if model missing
  await NativeTtsService.instance.init();
  await OpenRouterTtsService.instance.init();
  MoondreamService.instance.apiKey = prefs.getString('moondream_api_key') ??
      (secrets['moondream'] ?? MoondreamService.defaultApiKey);

  appLocale.value = Locale(prefs.getString('locale') ?? 'en');

  runApp(SpectruLenPorApp(prefs: prefs, secrets: secrets));
}

class SpectruLenPorApp extends StatelessWidget {
  final SharedPreferences prefs;
  final Map<String, String> _secrets;

  const SpectruLenPorApp({super.key, required this.prefs,
      required Map<String, String> secrets})
      : _secrets = secrets;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<SharedPreferences>.value(value: prefs),
        Provider<BluetoothCameraService>(
          create: (_) => BluetoothCameraService()..init(),
          dispose: (_, svc) => svc.dispose(),
        ),
        // v3.3: PhoneCameraService is a singleton now — don't dispose it via
        // Provider (it's a long-lived process service). Other widgets can grab
        // the same instance via PhoneCameraService.instance.
        Provider<PhoneCameraService>.value(value: PhoneCameraService.instance),
        Provider<LocalVisionService>.value(value: LocalVisionService.instance),
        Provider<MoondreamService>.value(value: MoondreamService.instance),
        Provider<OpenRouterService>(
          create: (ctx) => OpenRouterService(
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
    // v5.0 init YOLO + Mic (deferred)

            bluetooth: ctx.read<BluetoothCameraService>(),
            phoneCamera: ctx.read<PhoneCameraService>(),
            vision: ctx.read<LocalVisionService>(),
            openRouter: ctx.read<OpenRouterService>(),
            openRouterTts: ctx.read<OpenRouterTtsService>(),
            nativeTts: ctx.read<NativeTtsService>(),
            prefs: prefs,
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
            '/': (ctx) => const HomeScreen(),
            '/settings': (ctx) => const SettingsScreen(),
          },
        ),
      ),
    );
  }
}
