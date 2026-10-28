import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'tts_sink.dart';

/// Streamed TTS from OpenRouter — model `fish-audio/s2.1-pro-free:free`.
class OpenRouterTtsService {
  OpenRouterTtsService._();
  static final OpenRouterTtsService instance = OpenRouterTtsService._();

  static const String ttsModel = 'fish-audio/s2.1-pro-free:free';

  /// Key resolution: Settings (SharedPreferences) →
  /// `assets/config/secrets.json` → `--dart-define` → ''.
  static const String defaultApiKey =
      String.fromEnvironment('OPENROUTER_TTS_KEY');

  /// Real host on mobile/desktop; relative CORS-proxy path in web preview.
  static String get baseUrl =>
      kIsWeb ? '/openrouter/v1' : 'https://openrouter.ai/api/v1';

  late Dio _dio;
  String? _apiKey;

  String get apiKey => _apiKey ?? '';

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
      receiveTimeout: const Duration(seconds: 60),
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
  Future<void> speakMarkdown(String markdown) async {
    if (!isConfigured) return;
    final cleaned = stripMarkdownForTest(markdown);
    if (cleaned.isEmpty) return;

    await stop();

    try {
      if (kIsWeb || !sink.streamingAvailable) {
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
    // Strip <context_update> blocks and fact-check / citation tags.
    s = s.replaceAll(
      RegExp(
        r'(?:```(?:\w+)?\s*)?<context_update>[\s\S]*?</context_update>(?:\s*```)?',
      ),
      ' ',
    );
    s = s.replaceAll(RegExp(r'\[VERIFIED\s+\d+\]'), '');
    s = s.replaceAll('[UNVERIFIED]', '');
    s = s.replaceAll(RegExp(r'\[\d+\]'), '');
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
