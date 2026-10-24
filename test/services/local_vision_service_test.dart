import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smart_glass_app/services/local_vision_service.dart';
import 'package:smart_glass_app/services/moondream_service.dart';

void main() {
  test('cloud tier wins when a key is configured', () async {
    var captionCalls = 0;
    var queryCalls = 0;
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
        return http.Response('{}', 404);
      }),
    )
      ..apiKey = 'tok';

    final vision = LocalVisionService.forTest(moondream: md)
      ..moondreamModelPath = '/fake/local.gguf'; // local tier ALSO available
    await vision.init();

    final desc = await vision.describe(Uint8List(8), lang: 'en');
    expect(desc, 'Moondream sees: a glass beaker on a bench');
    expect(vision.lastEngine, 'moondream_cloud');
    expect(captionCalls, 1);
    // Deep query runs fire-and-forget — give it a beat, then check.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(queryCalls, 1);
    expect(vision.lastCloudAnalysis, 'A borosilicate beaker.');
  });

  test('no key → falls through cloud, local Moondream path is attempted',
      () async {
    final md = MoondreamService(
      client: MockClient((req) async {
        // Should never be called — key is empty.
        fail('cloud must not be called without a key');
      }),
    )
      ..apiKey = '';

    final vision = LocalVisionService.forTest(moondream: md)
      ..moondreamModelPath = '/fake/local.gguf';
    await vision.init();

    // localCaption goes through the platform channel → MissingPluginException
    // in tests → null → ONNX (disabled) → ML Kit (plugin missing) → null.
    final desc = await vision.describe(Uint8List(8));
    expect(desc, isNull);
    expect(vision.lastEngine, 'idle');
    expect(vision.cloudEnabled, isFalse);
  });

  test('cloud failure (429) falls through to the next tier', () async {
    final md = MoondreamService(
      client: MockClient(
          (req) async => http.Response('rate limited', 429)),
    )
      ..apiKey = 'tok';

    final vision = LocalVisionService.forTest(moondream: md);
    await vision.init();

    final desc = await vision.describe(Uint8List(8));
    // ONNX + ML Kit unavailable in the VM test → idle.
    expect(desc, isNull);
    expect(vision.lastEngine, 'idle');
  });

  test('Arabic captions use the Arabic template', () async {
    final md = MoondreamService(
      client: MockClient(
          (req) async => http.Response(
              jsonEncode({'caption': 'a blue bottle'}), 200)),
    )
      ..apiKey = 'tok';

    final vision = LocalVisionService.forTest(moondream: md);
    await vision.init();

    final desc = await vision.describe(Uint8List(8), lang: 'ar');
    expect(desc, contains('موندريم يرى'));
    expect(desc, contains('a blue bottle'));
  });
}
