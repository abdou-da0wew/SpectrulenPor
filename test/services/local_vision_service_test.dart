import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smart_glass_app/services/local_vision_service.dart';
import 'package:smart_glass_app/services/moondream_service.dart';
import 'package:smart_glass_app/services/onnx_prediction.dart';
import 'package:smart_glass_app/services/onnx_vision_service.dart';
import 'package:smart_glass_app/services/vision_gate.dart';

class _FakeOnnxVisionService implements OnnxVisionService {
  final List<OnnxPrediction> predictions;
  _FakeOnnxVisionService(this.predictions);

  @override
  bool get isReady => predictions.isNotEmpty;

  @override
  int get labelCount => predictions.length;

  @override
  Future<void> init() async {}

  @override
  Future<List<OnnxPrediction>?> classify(
    Uint8List jpegBytes, {
    int k = 3,
  }) async =>
      predictions.take(k).toList(growable: false);

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cloud tier wins when a key is configured', () async {
    var captionCalls = 0;
    var queryCalls = 0;
    var detectCalls = 0;
    final md = MoondreamService(
      client: MockClient((req) async {
        if (req.url.path.endsWith('/caption')) {
          captionCalls++;
          return http.Response(
              jsonEncode({'caption': 'a glass beaker on a bench'}), 200);
        }
        if (req.url.path.endsWith('/query')) {
          queryCalls++;
          return http.Response(
              jsonEncode({'answer': 'A borosilicate beaker.'}), 200);
        }
        if (req.url.path.endsWith('/detect')) {
          detectCalls++;
          return http.Response(jsonEncode({'objects': <dynamic>[]}), 200);
        }
        return http.Response('{}', 404);
      }),
    )
      ..apiKey = 'tok';

    final vision = LocalVisionService.forTest(moondream: md)
      ..moondreamModelPath = '/fake/local.gguf';
    await vision.init();

    final desc = await vision.describe(Uint8List(8), lang: 'en');
    expect(desc, 'Moondream sees: a glass beaker on a bench');
    expect(vision.lastEngine, 'moondream_cloud');
    expect(captionCalls, 1);
    expect(queryCalls, 2);
    expect(detectCalls, 1);
    expect(vision.lastCloudAnalysis, contains('A borosilicate beaker.'));
  });

  test('cloudOnly: true skips local GGUF/ONNX/MLKit fallbacks when cloud fails',
      () async {
    final md = MoondreamService(
      client: MockClient((req) async => http.Response('rate limited', 429)),
    )
      ..apiKey = 'tok';

    final fakeOnnx = _FakeOnnxVisionService([
      OnnxPrediction('Cup', 0.87, 0),
    ]);
    final vision = LocalVisionService.forTest(moondream: md, onnx: fakeOnnx)
      ..moondreamModelPath = '/fake/local.gguf';
    await vision.init();

    // With cloudOnly: true, ONNX must NOT be used as fallback.
    final cloudOnlyRes =
        await vision.describe(Uint8List(8), lang: 'en', cloudOnly: true);
    expect(cloudOnlyRes, isNull);
    expect(vision.lastEngine, 'idle');

    // With cloudOnly: false, ONNX fallback succeeds.
    final hybridRes =
        await vision.describe(Uint8List(8), lang: 'en', cloudOnly: false);
    expect(hybridRes, 'Cup (87%)');
    expect(vision.lastEngine, 'onnx');
  });

  test('no key -> falls through cloud, local Moondream path is attempted',
      () async {
    final md = MoondreamService(
      client: MockClient((req) async {
        fail('cloud must not be called without a key');
      }),
    )
      ..apiKey = '';

    final vision = LocalVisionService.forTest(moondream: md)
      ..moondreamModelPath = '/fake/local.gguf';
    await vision.init();

    final desc = await vision.describe(Uint8List(8));
    expect(desc, isNull);
    expect(vision.lastEngine, 'idle');
    expect(vision.cloudEnabled, isFalse);
  });

  test('vision gate blocks dark / obstructed frames before cloud calls',
      () async {
    final md = MoondreamService(
      client: MockClient((req) async {
        fail('cloud must not be called when gate blocks the frame');
      }),
    )
      ..apiKey = 'tok';

    final vision = LocalVisionService.forTest(
      moondream: md,
      gateCheck: (_) async => const VisionGateResult(
        visible: false,
        blocked: false,
        brightness: 4,
        variance: 12,
        blurScore: 100,
        reason: 'too-dark',
      ),
    );
    await vision.init();

    final desc = await vision.describe(Uint8List(8));
    expect(desc, isNull);
    expect(vision.lastEngine, 'gate_blocked');
  });

  test('Arabic captions use the Arabic template', () async {
    final md = MoondreamService(
      client: MockClient(
        (req) async =>
            http.Response(jsonEncode({'caption': 'a blue bottle'}), 200),
      ),
    )
      ..apiKey = 'tok';

    final vision = LocalVisionService.forTest(moondream: md);
    await vision.init();

    final desc = await vision.describe(Uint8List(8), lang: 'ar');
    expect(desc, contains('موندريم يرى'));
    expect(desc, contains('a blue bottle'));
  });
}
