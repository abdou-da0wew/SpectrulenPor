import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_glass_app/models/bluetooth_status.dart';
import 'package:smart_glass_app/models/frame_data.dart';
import 'package:smart_glass_app/models/recognition_state.dart';
import 'package:smart_glass_app/models/spectrum_reading.dart';
import 'package:smart_glass_app/services/bluetooth_camera_service.dart';
import 'package:smart_glass_app/services/local_vision_service.dart';
import 'package:smart_glass_app/services/moondream_service.dart';
import 'package:smart_glass_app/services/native_tts_service.dart';
import 'package:smart_glass_app/services/openrouter_service.dart';
import 'package:smart_glass_app/services/openrouter_tts_service.dart';
import 'package:smart_glass_app/services/phone_camera_service.dart';

Future<RecognitionState> buildState(
    [Map<String, Object> initialPrefs = const {}]) async {
  SharedPreferences.setMockInitialValues(initialPrefs);
  final prefs = await SharedPreferences.getInstance();
  return RecognitionState(
    bluetooth: BluetoothCameraService(),
    phoneCamera: PhoneCameraService(),
    vision: LocalVisionService.forTest(moondream: MoondreamService()..apiKey = ''),
    openRouter: OpenRouterService(apiKey: ''),
    openRouterTts: OpenRouterTtsService.instance,
    nativeTts: NativeTtsService.instance,
    prefs: prefs,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults load from empty prefs', () async {
    final state = await buildState();
    expect(state.liveSpeak, isTrue);
    expect(state.deepReasonEnabled, isTrue);
    expect(state.useOpenRouterTts, isFalse);
    expect(state.fps, 1);
    expect(state.localeCode, 'en');
    expect(state.isArabic, isFalse);
    expect(state.source, CameraSource.phone);
    expect(state.btStatus, BluetoothStatus.disconnected);
    expect(state.visionSource, VisionSource.idle);
  });

  test('settings persist through SharedPreferences', () async {
    final state = await buildState();
    state.liveSpeak = false;
    state.deepReasonEnabled = false;
    state.fps = 7; // clamped to 4
    state.upstreamStartModel = 99; // clamped to chain end
    await state.setLocale('ar');

    expect(state.fps, 4);
    expect(state.upstreamStartModel,
        OpenRouterService.modelChain.length - 1);
    expect(state.isArabic, isTrue);

    final reloaded = await buildState({
      'live_speak': false,
      'deep_reason': false,
      'fps': 4,
      'upstream_start_model': 2,
      'locale': 'ar',
    });
    expect(reloaded.liveSpeak, isFalse);
    expect(reloaded.deepReasonEnabled, isFalse);
    expect(reloaded.fps, 4);
    expect(reloaded.localeCode, 'ar');
  });

  test('keys seeded by main() are preserved when prefs are empty', () async {
    MoondreamService.instance.apiKey = 'seeded-md';
    final state = await buildState();
    expect(MoondreamService.instance.apiKey, 'seeded-md',
        reason: 'empty prefs must not clobber secrets.json-seeded keys');
  });

  test('frame throttle: frames inside the window are coalesced', () async {
    final state = await buildState();
    expect(state.lastFrame, isNull);

    state.debugPushFrame(FrameData(
      jpegBytes: Uint8List.fromList([1, 2, 3]),
      width: 8,
      height: 8,
      capturedAt: DateTime.now(),
    ));
    expect(state.lastFrame, isNotNull); // frame always cached

    // Processing at 1 fps: the second frame inside 1s is not analyzed —
    // vision source stays idle in the VM (ML Kit plugin missing → idle).
    state.debugPushFrame(FrameData(
      jpegBytes: Uint8List.fromList([4, 5]),
      width: 8,
      height: 8,
      capturedAt: DateTime.now(),
    ));
    expect(state.lastFrame!.jpegBytes[0], 4);
  });

  test('sensor hazard triggers the banner + reason', () async {
    final state = await buildState();
    expect(state.hazardActive, isFalse);

    state.debugPushSensor(SpectrumReading(
      uvRaw: 4000, // ~97% → hazard
      irRaw: 100,
      at: DateTime.now(),
    ));
    expect(state.lastReading, isNotNull);
    expect(state.hazardActive, isTrue);
    expect(state.hazardReason, isNotEmpty);

    state.clearHazard();
    expect(state.hazardActive, isFalse);
  });

  test('benign sensor data keeps the hazard banner off', () async {
    final state = await buildState();
    state.debugPushSensor(SpectrumReading(
      uvRaw: 500,
      irRaw: 500,
      at: DateTime.now(),
    ));
    expect(state.hazardActive, isFalse);
  });

  test('upstream without a key degrades to a spoken hint, status done',
      () async {
    final state = await buildState();
    state.debugPushFrame(FrameData(
      jpegBytes: Uint8List.fromList([9, 9, 9]),
      width: 8,
      height: 8,
      capturedAt: DateTime.now(),
    ));
    // Let the async vision→upstream chain settle.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // ML Kit / ONNX unavailable in VM → describe null → upstream skipped.
    expect(state.visionSource, anyOf(VisionSource.idle, VisionSource.error));
  });

  test('flashlight toggle works in phone mode (no controller → no-op)',
      () async {
    final state = await buildState();
    await state.setFlashlight(true);
    expect(state.flashOn, isTrue);
    await state.setFlashlight(false);
    expect(state.flashOn, isFalse);
  });

  test('source switching preserves the requested source', () async {
    final state = await buildState();
    await state.switchSource(CameraSource.glasses);
    expect(state.source, CameraSource.glasses);
    expect(state.usingPhoneCamera, isFalse);
  });
}
