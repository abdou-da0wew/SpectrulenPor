// Real-API smoke test for SpectruLenPor (run: dart run tool/real_api_smoke_test.dart)
//
// Exercises the ACTUAL service classes against the LIVE cloud APIs:
//   1. MoondreamService.caption / query(reasoning) / detect / streamQuery
//   2. OpenRouterService full fallback chain (gemma → inkling → nemotron)
//   3. OpenRouterTtsService byte download (fish-audio/s2.1-pro-free:free)
// Results are written to build/real_api_report.json + an MP3 artifact.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:smart_glass_app/config/app_secrets.dart';
import 'package:smart_glass_app/services/moondream_service.dart';
import 'package:smart_glass_app/services/openrouter_service.dart';
import 'package:smart_glass_app/services/openrouter_tts_service.dart';
import 'package:smart_glass_app/services/tts_sink.dart';

Future<void> main() async {
  final report = <String, dynamic>{};
  final img = File('scripts/test_image.jpg').existsSync()
      ? File('scripts/test_image.jpg')
      : File('../../scripts/test_image.jpg');
  final jpeg = Uint8List.fromList(img.readAsBytesSync());

  // ------------------------------------------------------------------ 1
  final secrets = await AppSecrets.load();
  final md = MoondreamService()
    ..apiKey = secrets['moondream'] ?? MoondreamService.defaultApiKey;
  stdout.writeln('── Moondream cloud ────────────────────────────────');
  final sw = Stopwatch()..start();
  final cap = await md.caption(jpeg, length: 'short');
  report['moondream_caption'] = {
    'ok': cap != null,
    'text': cap?.caption,
    'ttft_ms': md.lastTtftMs,
  };
  stdout.writeln(
      'caption: ${cap?.caption}  (ttft ${md.lastTtftMs?.toStringAsFixed(0)} ms)');

  final ans = await md.query(
    jpeg,
    question:
        'What object is in the center, what color is it, and is there any text?',
    reasoning: true,
  );
  report['moondream_query'] = {
    'ok': ans != null,
    'answer': ans?.answer,
    'reasoning_present': ans?.reasoning != null,
  };
  stdout.writeln('query: ${ans?.answer}');
  final rTrace = ans?.reasoning ?? '';
  if (rTrace.isNotEmpty) {
    stdout.writeln('  reasoning trace: '
        '${rTrace.substring(0, rTrace.length.clamp(0, 120))}…');
  }

  final boxes = await md.detect(jpeg, 'circle');
  report['moondream_detect'] = {'ok': boxes.isNotEmpty, 'boxes': boxes.length};
  stdout.writeln('detect(circle): ${boxes.length} box(es) '
      '${boxes.isNotEmpty ? boxes.first.xMin : ''}');

  final streamed = <String>[];
  await for (final c in md.streamQuery(jpeg, question: 'Describe in 5 words')) {
    streamed.add(c.text);
  }
  report['moondream_stream'] = {'ok': streamed.isNotEmpty, 'text': streamed.join()};
  stdout.writeln('streamQuery: ${streamed.join()}');
  stdout.writeln('(cloud tier took ${sw.elapsedMilliseconds} ms total)');

  // ------------------------------------------------------------------ 2
  stdout.writeln('── OpenRouter chain ───────────────────────────────');
  final or = OpenRouterService(
      apiKey: secrets['openrouter_llm'] ?? OpenRouterService.defaultApiKey);
  final chainOut = <String>[];
  await for (final chunk in or.streamAnalysis(
    labelSentence: 'Moondream sees: a red circle on a white background',
    moondreamAnalysis: cap?.caption,
    telemetry: 'Sensor telemetry: UV at 5% and IR at 3% of full scale.',
    lang: 'en',
  )) {
    chainOut.add(chunk);
  }
  final chainText = chainOut.join();
  report['openrouter_chain'] = {
    'ok': chainText.isNotEmpty && !chainText.contains('Could not reach'),
    'model_used': or.lastModelUsed,
    'chain_index': or.lastChainIndex,
    'reasoning_tokens': or.lastReasoningTokens,
    'reply': chainText.length > 400
        ? '${chainText.substring(0, 400)}…'
        : chainText,
  };
  stdout.writeln('model used: ${or.lastModelUsed} '
      '(chain index ${or.lastChainIndex}, reasoning tokens ${or.lastReasoningTokens})');
  stdout.writeln('reply: ${chainText.substring(0, chainText.length.clamp(0, 220))}…');

  // ------------------------------------------------------------------ 3
  stdout.writeln('── fish-audio TTS ─────────────────────────────────');
  final tts = OpenRouterTtsService.instance;
  await tts.init();
  tts.configure(apiKey: secrets['openrouter_tts'] ?? '');
  tts.sink = _FileSink('build/tts_smoke.mp3');
  await tts.speakMarkdown('## Warning!\nThis is **SpectruLenPor** speaking '
      'through the streamed fish-audio pipeline.');
  final mp3 = File('build/tts_smoke.mp3');
  report['tts'] = {
    'ok': mp3.existsSync() && mp3.lengthSync() > 1000,
    'bytes': mp3.existsSync() ? mp3.lengthSync() : 0,
    'model': OpenRouterTtsService.ttsModel,
  };
  stdout.writeln('mp3 bytes: ${mp3.existsSync() ? mp3.lengthSync() : 0}');

  // ------------------------------------------------------------------
  Directory('build').createSync(recursive: true);
  File('build/real_api_report.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln('report → build/real_api_report.json');
}

/// A TtsSink stand-in that captures the delivered bytes to disk — proves the
/// download pipeline produced real audio without touching platform players.
class _FileSink implements TtsSink {
  _FileSink(this.path);
  final String path;

  @override
  bool streamingAvailable = true;

  @override
  Future<void> playStreamed(Stream<List<int>> byteStream) async {
    final out = File(path).openSync(mode: FileMode.write);
    await for (final chunk in byteStream) {
      out.writeFromSync(chunk);
    }
    await out.close();
  }

  @override
  Future<void> playBytes(Uint8List bytes) async =>
      File(path).writeAsBytes(bytes, flush: true);

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}
