import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/recognition_state.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'services/bluetooth_camera_service.dart';
import 'services/local_vision_service.dart';
import 'services/native_tts_service.dart';
import 'services/onnx_vision_service.dart';
import 'services/openrouter_service.dart';
import 'services/openrouter_tts_service.dart';
import 'services/phone_camera_service.dart';
import 'utils/app_theme.dart';

/// Reactive app locale — Settings flips this, MaterialApp rebuilds.
/// RTL directionality is handled automatically by Material for 'ar'.
final ValueNotifier<Locale> appLocale =
    ValueNotifier<Locale>(const Locale('en'));

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();

  await LocalVisionService.instance.init();
  await OnnxVisionService.instance.init(); // silent no-op if model missing
  await NativeTtsService.instance.init();
  await OpenRouterTtsService.instance.init();

  appLocale.value = Locale(prefs.getString('locale') ?? 'en');

  runApp(SpectruLenPorApp(prefs: prefs));
}

class SpectruLenPorApp extends StatelessWidget {
  final SharedPreferences prefs;

  const SpectruLenPorApp({super.key, required this.prefs});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<SharedPreferences>.value(value: prefs),
        Provider<BluetoothCameraService>(
          create: (_) => BluetoothCameraService()..init(),
          dispose: (_, svc) => svc.dispose(),
        ),
        Provider<PhoneCameraService>(
          create: (_) => PhoneCameraService(),
          dispose: (_, svc) => svc.dispose(),
        ),
        Provider<LocalVisionService>.value(value: LocalVisionService.instance),
        Provider<OpenRouterService>(
          create: (ctx) => OpenRouterService(
            apiKey: prefs.getString('openrouter_api_key') ?? '',
          ),
        ),
        Provider<OpenRouterTtsService>.value(
          value: OpenRouterTtsService.instance,
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
          ),
        ),
      ],
      child: ValueListenableBuilder<Locale>(
        valueListenable: appLocale,
        builder: (context, locale, _) => MaterialApp(
          title: 'SpectruLenPor — Smart Scientific Glasses',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          locale: locale,
          supportedLocales: const [Locale('en'), Locale('ar')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
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
