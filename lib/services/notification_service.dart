import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'native_tts_service.dart';
import 'openrouter_tts_service.dart';
import 'supertonic_tts_service.dart';

/// Interactive local notifications for completed explanations and hazards.
class AppNotificationService {
  AppNotificationService._();
  static final AppNotificationService instance = AppNotificationService._();

  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _permissionGranted = false;
  bool get isEnabled => _initialized && _permissionGranted;

  String _lastSpokenText = '';
  Future<void> Function(String text)? _repeatSpeech;
  Future<void> Function()? _stopSpeech;

  void configureSpeechActions({
    required Future<void> Function(String text) repeatSpeech,
    required Future<void> Function() stopSpeech,
  }) {
    _repeatSpeech = repeatSpeech;
    _stopSpeech = stopSpeech;
  }

  Future<void> initialize() async {
    if (kIsWeb || _initialized) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onResponse,
    );
    const channel = AndroidNotificationChannel(
      'spectrulenpor_updates',
      'SpectruLenPor updates',
      description: 'Analysis results and smart-glasses safety alerts',
      importance: Importance.high,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
    final enabled = await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.areNotificationsEnabled();
    _permissionGranted = enabled ?? false;
    _initialized = true;
  }

  Future<bool> requestPermission() async {
    if (kIsWeb) return false;
    await initialize();
    final result = await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    _permissionGranted = result ?? _permissionGranted;
    return _permissionGranted;
  }

  Future<void> showAnalysisCompleted({
    required String title,
    required String body,
  }) async {
    _lastSpokenText = body;
    await _show(
      id: 5101,
      title: title,
      body: body,
      payload: 'analysis',
    );
  }

  Future<void> showHazardAlert({
    required String title,
    required String body,
  }) async {
    _lastSpokenText = body;
    await _show(
      id: 5102,
      title: title,
      body: body,
      payload: 'hazard',
      hazard: true,
    );
  }

  Future<void> _show({
    required int id,
    required String title,
    required String body,
    required String payload,
    bool hazard = false,
  }) async {
    if (kIsWeb || !_initialized || !_permissionGranted) return;
    final android = AndroidNotificationDetails(
      'spectrulenpor_updates',
      'SpectruLenPor updates',
      channelDescription: 'Analysis results and smart-glasses safety alerts',
      importance: Importance.high,
      priority: Priority.high,
      category: hazard
          ? AndroidNotificationCategory.alarm
          : AndroidNotificationCategory.status,
      styleInformation: BigTextStyleInformation(body),
      actions: <AndroidNotificationAction>[
        const AndroidNotificationAction(
          'open_app',
          'Open app',
          showsUserInterface: true,
          cancelNotification: true,
        ),
        const AndroidNotificationAction(
          'repeat',
          'Read again',
          showsUserInterface: true,
          cancelNotification: false,
        ),
        const AndroidNotificationAction(
          'stop_speech',
          'Stop speech',
          showsUserInterface: true,
          cancelNotification: false,
        ),
      ],
    );
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(android: android),
        payload: payload,
      );
    } catch (error) {
      debugPrint('[Notifications] show failed: $error');
    }
  }

  static Future<void> _stopAllSpeech() async {
    await OpenRouterTtsService.instance.stop();
    await NativeTtsService.instance.stop();
    await SupertonicTtsService.instance.stop();
  }

  static Future<void> _repeatWithDefaultEngine(String text) async {
    final spoken = await OpenRouterTtsService.instance.speakMarkdown(text);
    if (!spoken) await NativeTtsService.instance.speak(text);
  }

  static void _onResponse(NotificationResponse response) {
    switch (response.actionId) {
      case 'stop_speech':
        unawaited(instance._stopSpeech?.call() ?? _stopAllSpeech());
        break;
      case 'repeat':
        final text = instance._lastSpokenText;
        if (text.isNotEmpty) {
          final repeat = instance._repeatSpeech;
          unawaited(repeat?.call(text) ?? _repeatWithDefaultEngine(text));
        }
        break;
      case 'open_app':
      default:
        navigatorKey.currentState?.pushNamed('/');
        break;
    }
  }
}
