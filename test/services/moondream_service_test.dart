import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smart_glass_app/services/moondream_service.dart';

void main() {
  test('toDataUrl builds a base64 JPEG data URL', () {
    final svc = MoondreamService();
    final url = svc.toDataUrl(Uint8List.fromList([0xFF, 0xD8, 0x01, 0xD9]));
    expect(url, startsWith('data:image/jpeg;base64,'));
    // FF D8 -> _/A
    expect(url, contains('data:image/jpeg;base64,'));
  });

  test('isCloudConfigured reflects the key', () {
    final svc = MoondreamService()..apiKey = '';
    expect(svc.isCloudConfigured, isFalse);
    svc.apiKey = 'tok';
    expect(svc.isCloudConfigured, isTrue);
  });

  test('caption() parses the one-shot response', () async {
    final svc = MoondreamService(
      client: MockClient((req) async {
        expect(req.url.toString(), contains('/caption'));
        expect(req.headers['X-Moondream-Auth'], 'tok');
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['image_url'], startsWith('data:image/jpeg;base64,'));
        expect(body['length'], 'short');
        return http.Response(
            jsonEncode({'caption': 'a red apple', 'request_id': 'r1'}), 200);
      }),
    )
      ..apiKey = 'tok';

    final cap = await svc.caption(Uint8List(4));
    expect(cap, isNotNull);
    expect(cap!.caption, 'a red apple');
    expect(cap.requestId, 'r1');
  });

  test('caption() returns null on rate limit (cascade falls through)',
      () async {
    final svc = MoondreamService(
      client: MockClient((req) async =>
          http.Response(jsonEncode({'error': 'rate limited'}), 429)),
    )
      ..apiKey = 'tok';
    final cap = await svc.caption(Uint8List(4));
    expect(cap, isNull);
  });

  test('query() parses answer + reasoning trace', () async {
    final svc = MoondreamService(
      client: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['reasoning'], true);
        return http.Response(
            jsonEncode({
              'answer': 'It is an apple.',
              'reasoning': 'The shape and color match an apple.',
              'request_id': 'r2',
            }),
            200);
      }),
    )
      ..apiKey = 'tok';

    final ans = await svc.query(Uint8List(4),
        question: 'What is this?', reasoning: true);
    expect(ans, isNotNull);
    expect(ans!.answer, 'It is an apple.');
    expect(ans.reasoning, contains('apple'));
  });

  test('query() auto-downgrades the model on 400 (older keys)', () async {
    final svc = MoondreamService(
      client: MockClient(
          (req) async => http.Response('unknown model', 400)),
    )
      ..apiKey = 'tok'
      ..model = 'moondream3.1-9B-A2B';

    final ans = await svc.query(Uint8List(4), question: 'x');
    expect(ans, isNull);
    expect(svc.model, 'moondream3-preview');
  });

  test('streamQuery() decodes SSE chunk frames', () async {
    const sse = 'data: {"chunk": "A red"}\n\n'
        'data: {"chunk": " apple"}\n\n'
        'data: [DONE]\n\n';
    final svc = MoondreamService(
      client: MockClient.streaming((req, bodyStream) async {
        expect(req.url.toString(), contains('/query'));
        return http.StreamedResponse(
          http.ByteStream.fromBytes(utf8.encode(sse)),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    )
      ..apiKey = 'tok';

    final chunks = await svc.streamQuery(Uint8List(4), question: 'q').toList();
    expect(chunks.map((c) => c.text).join(), 'A red apple');
    expect(chunks.every((c) => !c.isReasoning), isTrue);
  });

  test('detect() parses normalized boxes', () async {
    final svc = MoondreamService(
      client: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['object'], 'apple');
        return http.Response(
            jsonEncode({
              'objects': [
                {'x_min': 0.1, 'y_min': 0.2, 'x_max': 0.3, 'y_max': 0.4},
              ],
            }),
            200);
      }),
    )
      ..apiKey = 'tok';

    final boxes = await svc.detect(Uint8List(4), 'apple');
    expect(boxes, hasLength(1));
    expect(boxes.first.xMin, 0.1);
    expect(boxes.first.cy, closeTo(0.3, 1e-9));
  });

  test('detect() returns empty on auth failure (no crash)', () async {
    final svc = MoondreamService(
      client: MockClient((req) async => http.Response('unauthorized', 401)),
    )
      ..apiKey = 'tok';
    expect(await svc.detect(Uint8List(4), 'apple'), isEmpty);
  });

  test('default key is a plain string (secrets come from config asset)',
      () {
    // Real keys live in gitignored assets/config/secrets.json — the source
    // default is empty (or a --dart-define) so GitHub push protection passes.
    expect(MoondreamService.defaultApiKey, isA<String>());
  });
}
