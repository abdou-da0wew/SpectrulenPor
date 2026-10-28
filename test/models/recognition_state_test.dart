import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_glass_app/models/bluetooth_status.dart';
import 'package:smart_glass_app/models/bounding_box.dart';
import 'package:smart_glass_app/models/frame_data.dart';
import 'package:smart_glass_app/models/recognition_state.dart';
import 'package:smart_glass_app/models/spectrum_reading.dart';
import 'package:smart_glass_app/services/bluetooth_camera_service.dart';
import 'package:smart_glass_app/services/docs_search_service.dart';
import 'package:smart_glass_app/services/internal_db_service.dart';
import 'package:smart_glass_app/services/local_vision_service.dart';
import 'package:smart_glass_app/services/moondream_service.dart';
import 'package:smart_glass_app/services/native_tts_service.dart';
import 'package:smart_glass_app/services/openrouter_service.dart';
import 'package:smart_glass_app/services/openrouter_tts_service.dart';
import 'package:smart_glass_app/services/phone_camera_service.dart';

Uint8List _makeCheckeredJpeg() {
  final image = img.Image(width: 64, height: 64);
  for (var y = 0; y < 64; y++) {
    for (var x = 0; x < 64; x++) {
      final v = ((x + y) % 2 == 0) ? 210 : 60;
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

Future<RecognitionState> buildState({
  Map<String, Object> initialPrefs = const {},
  OpenRouterService? openRouter,
  void Function(String)? onLocaleChanged,
}) async {
  SharedPreferences.setMockInitialValues(initialPrefs);
  final prefs = await SharedPreferences.getInstance();
  await InternalDatabaseService.instance.init();
  return RecognitionState(
    bluetooth: BluetoothCameraService(),
    phoneCamera: PhoneCameraService(),
    vision: LocalVisionService.forTest(
      moondream: MoondreamService()..apiKey = '',
    ),
    openRouter: openRouter ?? OpenRouterService(apiKey: ''),
    openRouterTts: OpenRouterTtsService.instance,
    nativeTts: NativeTtsService.instance,
    prefs: prefs,
    onLocaleChanged: onLocaleChanged,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults load from empty prefs including semantic DocsSearchMode',
      () async {
    final state = await buildState();
    addTearDown(state.dispose);

    expect(state.liveSpeak, isTrue);
    expect(state.deepReasonEnabled, isTrue);
    expect(state.useOpenRouterTts, isFalse);
    expect(state.cloudOnly, isFalse);
    expect(state.searchMode, DocsSearchMode.semantic);
    expect(state.fps, 1);
    expect(state.localeCode, 'en');
    expect(state.isArabic, isFalse);
    expect(state.source, CameraSource.phone);
    expect(state.btStatus, BluetoothStatus.disconnected);
    expect(state.visionSource, VisionSource.idle);
  });

  test('settings persist through SharedPreferences & notify onLocaleChanged',
      () async {
    String? notifiedLocale;
    final state = await buildState(
      onLocaleChanged: (code) => notifiedLocale = code,
    );
    addTearDown(state.dispose);

    state.liveSpeak = false;
    state.deepReasonEnabled = false;
    state.cloudOnly = true;
    state.searchMode = DocsSearchMode.strict;
    state.fps = 7; // clamped to 4
    state.upstreamStartModel = 99; // clamped to chain end
    await state.setLocale('ar');

    expect(state.fps, 4);
    expect(state.cloudOnly, isTrue);
    expect(state.searchMode, DocsSearchMode.strict);
    expect(
      state.upstreamStartModel,
      OpenRouterService.modelChain.length - 1,
    );
    expect(state.isArabic, isTrue);
    expect(notifiedLocale, 'ar');

    final reloaded = await buildState(
      initialPrefs: const {
        'live_speak': false,
        'deep_reason': false,
        'cloud_only': true,
        'docs_search_mode': 'strict',
        'fps': 4,
        'upstream_start_model': 2,
        'locale': 'ar',
      },
    );
    addTearDown(reloaded.dispose);

    expect(reloaded.liveSpeak, isFalse);
    expect(reloaded.deepReasonEnabled, isFalse);
    expect(reloaded.cloudOnly, isTrue);
    expect(reloaded.searchMode, DocsSearchMode.strict);
    expect(reloaded.fps, 4);
    expect(reloaded.localeCode, 'ar');
  });

  test('keys seeded by main() are preserved when prefs are empty', () async {
    MoondreamService.instance.apiKey = 'seeded-md';
    final state = await buildState();
    addTearDown(state.dispose);

    expect(
      MoondreamService.instance.apiKey,
      'seeded-md',
      reason: 'empty prefs must not clobber secrets.json-seeded keys',
    );
    MoondreamService.instance.apiKey = '';
  });

  test('strict capture gating: refuses capture when no bounding box is selected',
      () async {
    final state = await buildState();
    addTearDown(state.dispose);

    state.debugPushFrame(FrameData(
      jpegBytes: _makeCheckeredJpeg(),
      width: 64,
      height: 64,
      capturedAt: DateTime.now(),
    ));

    // No box selected -> captureAndAnalyzeSelected MUST return false and NOT capture
    expect(state.selectedBox, isNull);
    final blocked = await state.captureAndAnalyzeSelected();
    expect(blocked, isFalse);
    expect(state.capturedFrames, isNull);
  });

  test(
      'selectBox + captureAndAnalyzeSelected paints marked JPEG, runs cloud LLM under cloudOnly, persists & resumes session',
      () async {
    final sseResponse = [
      'data: ${jsonEncode({
        'id': 'c1',
        'model': OpenRouterService.modelChain.first,
        'choices': [
          {
            'delta': {
              'content':
                  'Copper sulfate is a blue solid crystalline compound. Warning: toxic if ingested [1].\n<context_update>{"chemicalFormula":"CuSO4·5H2O","stateOfMatter":"solid"}</context_update>'
            },
            'index': 0,
          }
        ],
      })}',
      'data: [DONE]',
    ].join('\n\n');

    final or = OpenRouterService(
      apiKey: 'test-key',
      clientFactory: () => MockClient.streaming(
        (req, _) async => http.StreamedResponse(
          http.ByteStream.fromBytes(utf8.encode(sseResponse)),
          200,
        ),
      ),
    );

    final state = await buildState(
      initialPrefs: const {'cloud_only': true, 'live_speak': false},
      openRouter: or,
    );
    addTearDown(state.dispose);

    final clean = _makeCheckeredJpeg();
    state.debugPushFrame(FrameData(
      jpegBytes: clean,
      width: 64,
      height: 64,
      capturedAt: DateTime.now(),
    ));

    const box = BoundingBox(
      x: 0.1,
      y: 0.1,
      w: 0.6,
      h: 0.6,
      label: 'Copper(II) Sulfate',
      confidence: 0.91,
    );
    state.selectBox(box);
    expect(state.hasUnanalyzedSelection, isTrue);

    final ok = await state.captureAndAnalyzeSelected();
    expect(ok, isTrue);
    expect(state.capturedFrames, isNotNull);
    expect(state.capturedFrames!.cleanJpeg, equals(clean));
    // Marked frame has the painted target reticle & SELECTED banner
    expect(state.capturedFrames!.withBoxesJpeg, isNot(equals(clean)));

    expect(state.chatSession, isNotNull);
    expect(state.chatSession!.history, hasLength(1));
    expect(
      state.chatSession!.runningContext.chemicalFormula,
      'CuSO4·5H2O',
    );
    expect(state.matterState, MatterState.solid);
    expect(state.hazardActive, isTrue);

    // Verify session was persisted into InternalDatabaseService and can be resumed
    final savedId = state.chatSession!.sessionId;
    final state2 = await buildState(openRouter: or);
    addTearDown(state2.dispose);
    final resumed = await state2.resumeSavedChatSession(savedId);
    expect(resumed, isTrue);
    expect(state2.chatSession, isNotNull);
    expect(state2.chatSession!.runningContext.chemicalFormula, 'CuSO4·5H2O');
  });

  test('sensor hazard triggers the banner + logs telemetry', () async {
    final state = await buildState();
    addTearDown(state.dispose);
    expect(state.hazardActive, isFalse);

    state.debugPushSensor(SpectrumReading(
      uvRaw: 4000,
      irRaw: 100,
      at: DateTime.now(),
    ));
    expect(state.lastReading, isNotNull);
    expect(state.hazardActive, isTrue);

    state.clearHazard();
    expect(state.hazardActive, isFalse);
  });

  test('flashlight toggle and source switching work cleanly', () async {
    final state = await buildState();
    addTearDown(state.dispose);
    await state.setFlashlight(true);
    expect(state.flashOn, isTrue);
    await state.switchSource(CameraSource.glasses);
    expect(state.source, CameraSource.glasses);
    expect(state.usingPhoneCamera, isFalse);
  });
}
