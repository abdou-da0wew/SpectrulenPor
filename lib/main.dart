import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/recognition_state.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'services/bluetooth_camera_service.dart';
import 'services/local_vision_service.dart';
import 'services/native_tts_service.dart';
import 'services/openrouter_service.dart';
import 'services/openrouter_tts_service.dart';
import 'utils/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();

  await LocalVisionService.instance.init();
  await NativeTtsService.instance.init();
  await OpenRouterTtsService.instance.init();

  runApp(SpectrulenPorApp(prefs: prefs));
}

class SpectrulenPorApp extends StatelessWidget {
  final SharedPreferences prefs;

  const SpectrulenPorApp({super.key, required this.prefs});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<SharedPreferences>.value(value: prefs),
        Provider<BluetoothCameraService>(
          create: (_) => BluetoothCameraService()..init(),
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
            vision: ctx.read<LocalVisionService>(),
            openRouter: ctx.read<OpenRouterService>(),
            openRouterTts: ctx.read<OpenRouterTtsService>(),
            nativeTts: ctx.read<NativeTtsService>(),
            prefs: prefs,
          ),
        ),
      ],
      child: MaterialApp(
        title: 'SpectrulenPor — Smart Scientific Glasses',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        initialRoute: '/',
        routes: {
          '/': (ctx) => const HomeScreen(),
          '/settings': (ctx) => const SettingsScreen(),
        },
      ),
    );
  }
}
