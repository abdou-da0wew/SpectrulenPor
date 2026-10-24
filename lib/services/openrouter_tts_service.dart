import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'tts_sink.dart';

/// Streamed TTS from OpenRouter — model `fish-audio/s2.1-pro-free:free`.
///
/// The user-specified integration (HTTP equivalent of the OpenRouter SDK
/// `openrouter.tts.createSpeech({speechRequest: {model, input}})`):
///
///   POST https://openrouter.ai/api/v1/audio/speech
///   Authorization: Bearer $OPENROUTER_API_KEY
///   Content-Type: application/json
///   { "model": "fish-audio/s2.1-pro-free:free", "input": "…" }
///   -> response body streams MP3 bytes (chunked).
///
/// "Make the audio get streamed": on mobile/desktop the dio response stream
/// is piped straight into a [StreamAudioSource] (just_audio) so playback
/// begins on the FIRST chunks. On the web preview the chunks are buffered
/// and played through a blob URL (browsers can't progressively decode a
/// raw stream into <audio>).
class OpenRouterTtsService {
  OpenRouterTtsService._();
  static final OpenRouterTtsService instance = OpenRouterTtsService._();

  static const String ttsModel = 'fish-audio/s2.1-pro-free:free';

  /// Key resolution: Settings (SharedPreferences) →
  /// `assets/config/secrets.json` → `--dart-define` → ''. Empty in source so
  /// pushes pass GitHub push protection.
  static const String defaultApiKey =
      String.fromEnvironment('OPENROUTER_TTS_KEY');

  /// Real host on mobile/desktop; relative CORS-proxy path in web preview.
  static String get baseUrl =>
      kIsWeb ? '/openrouter/v1' : 'https://openrouter.ai/api/v1';

  late Dio _dio;
  String? _apiKey;

  /// Swappable for tests.
  @visibleForTesting
  TtsSink sink = TtsSink();

  /// Test access to the underlying dio (adapter injection).
  @visibleForTesting
  Dio get debugDio => _dio;

  bool get isConfigured => _apiKey != null && _apiKey!.isNotEmpty;

  Future<void> init() async {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 60), // long narrations stream
      sendTimeout: const Duration(seconds: 15),
    ));
  }

  void configure({required String apiKey}) {
    _apiKey = apiKey;
  }

  Map<String, String> _headers() => {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
        'HTTP-Referer': 'https://github.com/abdou-da0wew/SpectrulenPor',
        'X-Title': 'SpectruLenPor',
      };

  /// Send markdown to TTS and STREAM the audio while it downloads.
  /// Strips markdown formatting for cleaner speech. Cancels any
  /// in-flight narration first (only one voice at a time).
  Future<void> speakMarkdown(String markdown) async {
    if (!isConfigured) return;
    final cleaned = stripMarkdownForTest(markdown);
    if (cleaned.isEmpty) return;

    await stop();

    try {
      if (kIsWeb) {
        // Browser adapter can't hand us a live byte stream — buffer bytes.
        final res = await _dio.post<List<int>>(
          '$baseUrl/audio/speech',
          options: Options(
            headers: _headers(),
            responseType: ResponseType.bytes,
          ),
          data: jsonEncode({
            'model': ttsModel,
            'input': cleaned,
            'response_format': 'mp3',
          }),
        );
        final bytes = res.data;
        if (bytes == null || bytes.isEmpty) return;
        await sink.playBytes(Uint8List.fromList(bytes));
      } else {
        final response = await _dio.post<ResponseBody>(
          '$baseUrl/audio/speech',
          options: Options(
            headers: _headers(),
            responseType: ResponseType.stream,
          ),
          data: jsonEncode({
            'model': ttsModel,
            'input': cleaned,
            'response_format': 'mp3',
          }),
        );
        final body = response.data;
        if (body == null) return;
        await sink.playStreamed(body.stream.cast<List<int>>());
      }
    } catch (e) {
      debugPrint('[OpenRouterTts] error: $e — native TTS remains the '
          'offline fallback.');
    }
  }

  /// Stop any narration immediately (called on mute / new speak / dispose).
  Future<void> stop() => sink.stop();

  @visibleForTesting
  static String stripMarkdownForTest(String md) {
    var s = md;
    s = s.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
    s = s.replaceAll(RegExp(r'\*{1,3}'), '');
    s = s.replaceAll(RegExp(r'_{1,3}'), '');
    s = s.replaceAll('`', '');
    s = s.replaceAll(RegExp(r'^[\-\*]\s+', multiLine: true), '. ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  Future<void> dispose() => sink.dispose();
}
