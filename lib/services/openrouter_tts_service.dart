import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'internal_db_service.dart';
import 'tts_sink.dart';

/// Fish Audio is the preferred speech engine. Android's offline voice is used
/// sentence-by-sentence when the cloud service cannot return usable audio.
class OpenRouterTtsService {
  OpenRouterTtsService._();
  static final OpenRouterTtsService instance = OpenRouterTtsService._();

  static const String ttsModel = 'fish-audio/s2.1-pro-free:free';
  static const String defaultApiKey =
      String.fromEnvironment('OPENROUTER_TTS_KEY');

  static String get baseUrl =>
      kIsWeb ? '/openrouter/v1' : 'https://openrouter.ai/api/v1';

  late Dio _dio;
  String? _apiKey;

  String get apiKey => _apiKey ?? '';
  bool get isConfigured => _apiKey?.trim().isNotEmpty ?? false;

  @visibleForTesting
  TtsSink sink = TtsSink();

  @visibleForTesting
  Dio get debugDio => _dio;

  Future<void> init() async {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 55),
      sendTimeout: const Duration(seconds: 15),
    ));
  }

  void configure({required String apiKey}) {
    _apiKey = apiKey.trim();
  }

  Map<String, String> _headers() => {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
        'HTTP-Referer': 'https://github.com/abdou-da0wew/SpectrulenPor',
        'X-Title': 'SpectruLenPor',
      };

  Future<bool> speakMarkdown(String markdown) async {
    if (!isConfigured) return false;
    final cleaned = stripMarkdownForTts(markdown);
    if (cleaned.isEmpty) return false;
    await stop();
    try {
      await _synthesizeAndPlay(cleaned);
      return true;
    } catch (error) {
      _logFailure(error);
      return false;
    }
  }

  /// Speaks completed LLM sentences while generation is still running.
  ///
  /// Cloud output is serialized by awaiting each audio segment. If Fish Audio
  /// fails, the current and subsequent sentences use the supplied offline
  /// fallback instead of cancelling speech or leaving the user in silence.
  Future<void> speakResponseStream(
    Stream<String> chunks, {
    required Future<void> Function(String sentence) fallback,
  }) async {
    await stop();
    var pending = '';
    var cloudAvailable = isConfigured;

    Future<void> speakSegment(String raw) async {
      final sentence = stripMarkdownForTts(raw);
      if (sentence.isEmpty) return;
      if (cloudAvailable) {
        try {
          await _synthesizeAndPlay(sentence);
          return;
        } catch (error) {
          cloudAvailable = false;
          _logFailure(error);
        }
      }
      await fallback(sentence);
    }

    await for (final chunk in chunks) {
      pending += chunk;
      var boundary = _findSentenceBoundary(pending);
      while (boundary > 0) {
        final sentence = pending.substring(0, boundary).trim();
        pending = pending.substring(boundary).trimLeft();
        if (sentence.isNotEmpty) await speakSegment(sentence);
        boundary = _findSentenceBoundary(pending);
      }

      if (pending.length > 520) {
        final splitAt = pending.lastIndexOf(' ', 500);
        if (splitAt > 100) {
          final segment = pending.substring(0, splitAt).trim();
          pending = pending.substring(splitAt).trimLeft();
          await speakSegment(segment);
        }
      }
    }

    if (pending.trim().isNotEmpty) await speakSegment(pending);
  }

  int _findSentenceBoundary(String value) {
    for (var index = 0; index < value.length; index++) {
      final char = value[index];
      if (char == '\n' ||
          char == '؟' ||
          char == '!' ||
          char == '。' ||
          char == '！' ||
          char == '؛' ||
          char == '；') {
        return index + 1;
      }
      if (char == '.' || char == '?') {
        final previousIsDigit =
            index > 0 && RegExp(r'\d').hasMatch(value[index - 1]);
        final nextIsDigit = index + 1 < value.length &&
            RegExp(r'\d').hasMatch(value[index + 1]);
        final followedByBoundary =
            index + 1 == value.length || value[index + 1].trim().isEmpty;
        if (!previousIsDigit && !nextIsDigit && followedByBoundary) {
          return index + 1;
        }
      }
    }
    return -1;
  }

  Future<void> _synthesizeAndPlay(String text) async {
    if (!isConfigured) throw StateError('OpenRouter TTS is not configured.');

    if (kIsWeb || !sink.streamingAvailable) {
      final response = await _dio.post<List<int>>(
        '$baseUrl/audio/speech',
        options: Options(
          headers: _headers(),
          responseType: ResponseType.bytes,
        ),
        data: jsonEncode({
          'model': ttsModel,
          'input': text,
          'response_format': 'mp3',
        }),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        throw StateError('Fish Audio returned an empty audio response.');
      }
      await sink.playBytes(Uint8List.fromList(bytes));
      return;
    }

    final response = await _dio.post<ResponseBody>(
      '$baseUrl/audio/speech',
      options: Options(
        headers: _headers(),
        responseType: ResponseType.stream,
      ),
      data: jsonEncode({
        'model': ttsModel,
        'input': text,
        'response_format': 'mp3',
      }),
    );
    final body = response.data;
    if (body == null) throw StateError('Fish Audio returned no audio stream.');
    await sink.playStreamed(body.stream.cast<List<int>>());
  }

  void _logFailure(Object error) {
    debugPrint('[FishTts] $error; switching to offline speech.');
    unawaited(InternalDatabaseService.instance.logWarn(
      'OpenRouterTts',
      'Fish Audio segment failed; offline TTS fallback engaged',
      metadata: {'error': error.toString()},
    ));
  }

  Future<void> stop() => sink.stop();

  static String stripMarkdownForTts(String markdown) {
    var text = markdown;
    text = text.replaceAll(
      RegExp(
        r'<context_update>[\s\S]*?</context_update>',
        multiLine: true,
      ),
      ' ',
    );
    text = text.replaceAll(
      RegExp(r'\[(?:SOURCE MATCH|VERIFIED)\s+\d+\]'),
      '',
    );
    text =
        text.replaceAll('[NO SOURCE MATCH]', '').replaceAll('[UNVERIFIED]', '');
    text = text.replaceAll(RegExp(r'\[\d+\]'), '');
    text = text.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
    text = text.replaceAll(RegExp(r'`+'), '');
    text = text.replaceAll(RegExp(r'\*{1,3}'), '');
    text = text.replaceAll(RegExp(r'_{1,3}'), '');
    text = text.replaceAll(RegExp(r'^[\-*]\s+', multiLine: true), '. ');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text;
  }

  Future<void> dispose() => sink.dispose();
}
