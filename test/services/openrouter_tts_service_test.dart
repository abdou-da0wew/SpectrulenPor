import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_glass_app/services/openrouter_tts_service.dart';
import 'package:smart_glass_app/services/tts_sink.dart';

/// Captures requests + returns canned MP3 bytes, recording what the
/// service asked for and what the sink received.
class FakeTtsAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> bodies = [];
  int statusCode;

  FakeTtsAdapter({this.statusCode = 200});

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final raw = await utf8.decoder.bind(requestStream!).join();
    bodies.add(Map<String, dynamic>.from(jsonDecode(raw) as Map));
    if (statusCode != 200) {
      return ResponseBody.fromString('denied', statusCode);
    }
    // Minimal plausible "MP3": ID3 header + junk
    final bytes = <int>[0x49, 0x44, 0x33, 0x04, 0x00, 0x00, ...List.filled(64, 0)];
    return ResponseBody(
      Stream.value(Uint8List.fromList(bytes)),
      200,
      headers: {
        Headers.contentTypeHeader: ['audio/mpeg'],
        Headers.contentLengthHeader: ['${bytes.length}'],
      },
    );
  }
}

/// Records calls instead of touching real audio engines.
class RecordingSink implements TtsSink {
  final streamed = <List<int>>[];
  final byteBuffers = <Uint8List>[];
  bool stopCalled = false;

  @override
  bool streamingAvailable = true;

  @override
  Future<void> playStreamed(Stream<List<int>> byteStream) async {
    final all = <int>[];
    await for (final c in byteStream) {
      all.addAll(c);
    }
    streamed.add(all);
  }

  @override
  Future<void> playBytes(Uint8List bytes) async => byteBuffers.add(bytes);

  @override
  Future<void> stop() async => stopCalled = true;

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('stripMarkdownForTest removes markdown noise', () {
    final out = OpenRouterTtsService.stripMarkdownForTest(
        '## Explore\n- **water** is `H2O`\n- _clean_ and clear');
    expect(out.contains('#'), isFalse);
    expect(out.contains('*'), isFalse);
    expect(out.contains('`'), isFalse);
    expect(out, contains('water'));
  });

  test('speakMarkdown requests fish-audio model with cleaned input',
      () async {
    final svc = OpenRouterTtsService.instance;
    await svc.init();
    svc.configure(apiKey: 'tts-key');
    final adapter = FakeTtsAdapter();
    svc.debugDio.httpClientAdapter = adapter;
    final sink = RecordingSink();
    svc.sink = sink;

    await svc.speakMarkdown('Hello **world**');

    expect(adapter.bodies, hasLength(1));
    expect(adapter.bodies.first['model'],
        'fish-audio/s2.1-pro-free:free');
    expect(adapter.bodies.first['input'], 'Hello world');
    expect(adapter.bodies.first['response_format'], 'mp3');
    // Streamed path received the MP3 bytes.
    expect(sink.streamed, hasLength(1));
    expect(sink.streamed.first.first, 0x49); // 'I' of ID3
  });

  test('unconfigured service is a no-op', () async {
    final svc = OpenRouterTtsService.instance;
    await svc.init();
    svc.configure(apiKey: '');
    final adapter = FakeTtsAdapter();
    svc.debugDio.httpClientAdapter = adapter;
    final sink = RecordingSink();
    svc.sink = sink;

    await svc.speakMarkdown('silence');
    expect(adapter.bodies, isEmpty);
    expect(sink.streamed, isEmpty);
  });

  test('HTTP error is swallowed (native TTS stays the fallback)', () async {
    final svc = OpenRouterTtsService.instance;
    await svc.init();
    svc.configure(apiKey: 'k');
    svc.debugDio.httpClientAdapter = FakeTtsAdapter(statusCode: 402);
    final sink = RecordingSink();
    svc.sink = sink;

    await svc.speakMarkdown('paid tier needed');
    expect(sink.streamed, isEmpty);
  });

  test('TTS model constant + key default shape', () {
    expect(OpenRouterTtsService.defaultApiKey, isA<String>());
    expect(OpenRouterTtsService.ttsModel, contains('fish-audio'));
  });
}
