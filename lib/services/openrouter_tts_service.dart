import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

/// Generates and plays spoken audio from text using an OpenRouter-compatible
/// TTS endpoint (or any compatible audio TTS endpoint you configure).
///
/// Use cases:
///   - High-quality narration of the deep reasoning markdown for users who
///     prefer premium voices over the Android native engine.
///   - Multi-language narration that the native engine may not support well.
///
/// Note: OpenRouter primarily routes chat completions. To use a TTS model
/// via OpenRouter (or a sibling provider), set the TTS base URL + voice name
/// in Settings. This scaffold supports any OpenAI-compatible `/audio/speech`
/// endpoint, so you can also point it at a self-hosted OpenAI TTS API.
class OpenRouterTtsService {
  OpenRouterTtsService._();
  static final OpenRouterTtsService instance = OpenRouterTtsService._();

  late Dio _dio;
  String? _apiKey;
  String _baseUrl = 'https://openrouter.ai/api/v1';
  String _voice = 'alloy';
  String _model = 'tts-1';

  bool get isConfigured => _apiKey != null && _apiKey!.isNotEmpty;

  Future<void> init() async {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 15),
      responseType: ResponseType.bytes,
    ));
  }

  void configure({
    required String apiKey,
    String? baseUrl,
    String? voice,
    String? model,
  }) {
    _apiKey = apiKey;
    if (baseUrl != null) _baseUrl = baseUrl;
    if (voice != null) _voice = voice;
    if (model != null) _model = model;
  }

  /// Send markdown to TTS. Strips markdown formatting for cleaner speech.
  Future<void> speakMarkdown(String markdown, {String? model}) async {
    if (!isConfigured) return;
    final cleaned = _stripMarkdown(markdown);
    if (cleaned.isEmpty) return;

    try {
      final response = await _dio.post(
        '$_baseUrl/audio/speech',
        options: Options(headers: {
          'Authorization': 'Bearer $_apiKey',
          'Content-Type': 'application/json',
        }),
        data: jsonEncode({
          'model': model ?? _model,
          'input': cleaned,
          'voice': _voice,
          'response_format': 'mp3',
        }),
      );

      if (response.statusCode == 200) {
        final bytes = Uint8List.fromList(response.data as List<int>);
        await _playMp3(bytes);
      }
    } catch (e) {
      // Swallow errors here; the native TTS path still works as a backup.
      print('[OpenRouterTtsService] error: $e');
    }
  }

  /// Plays MP3 bytes via `audioplayers`.
  Future<void> _playMp3(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/tts_${DateTime.now().microsecondsSinceEpoch}.mp3';
    final f = io.File(path);
    await f.writeAsBytes(bytes, flush: true);

    final player = AudioPlayer();
    await player.play(DeviceFileSource(path));
    player.onPlayerComplete.listen((_) {
      player.dispose();
      f.delete().catchError((_) {});
    });
  }

  String _stripMarkdown(String md) {
    var s = md;
    s = s.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
    s = s.replaceAll(RegExp(r'\*{1,3}'), '');
    s = s.replaceAll(RegExp(r'_{1,3}'), '');
    s = s.replaceAll('`', '');
    s = s.replaceAll(RegExp(r'^[\-\*]\s+', multiLine: true), '. ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }
}
