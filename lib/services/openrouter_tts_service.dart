import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

/// Streamed TTS from OpenRouter — model `fish-audio/s2.1-pro-free:free`.
///
/// The user-specified integration (HTTP equivalent of the OpenRouter SDK
/// `openrouter.tts.createSpeech({speechRequest: {model, input}})`):
///
///   POST https://openrouter.ai/api/v1/audio/speech
///   Authorization: Bearer $OPENROUTER_API_KEY
///   Content-Type: application/json
///   { "model": "fish-audio/s2.1-pro-free:free", "input": "…" }
///   → response body streams MP3 bytes (chunked).
///
/// "Make the audio get streamed": the dio response stream is piped straight
/// into a [StreamAudioSource] (just_audio) so playback begins on the FIRST
/// chunks — we never wait for the whole file. A file-based audioplayers
/// fallback exists for devices where just_audio is unavailable.
class OpenRouterTtsService {
  OpenRouterTtsService._();
  static final OpenRouterTtsService instance = OpenRouterTtsService._();

  static const String ttsModel = 'fish-audio/s2.1-pro-free:free';
  static const String _baseUrl = 'https://openrouter.ai/api/v1';

  late Dio _dio;
  String? _apiKey;

  // Players — just_audio for true streaming, audioplayers as file fallback.
  AudioPlayer? _streamPlayer;
  AudioPlayer? _filePlayer;
  bool _streamingAvailable = true; // flips false if just_audio init fails

  bool get isConfigured => _apiKey != null && _apiKey!.isNotEmpty;

  Future<void> init() async {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 60), // long narrations stream
      sendTimeout: const Duration(seconds: 15),
      responseType: ResponseType.stream,
    ));
  }

  void configure({required String apiKey}) {
    _apiKey = apiKey;
  }

  /// Send markdown to TTS and STREAM the audio while it downloads.
  /// Strips markdown formatting for cleaner speech. Cancels any
  /// in-flight narration first (only one voice at a time).
  Future<void> speakMarkdown(String markdown) async {
    if (!isConfigured) return;
    final cleaned = _stripMarkdown(markdown);
    if (cleaned.isEmpty) return;

    await stop();

    try {
      final response = await _dio.post<ResponseBody>(
        '$_baseUrl/audio/speech',
        options: Options(
          headers: {
            'Authorization': 'Bearer $_apiKey',
            'Content-Type': 'application/json',
            'HTTP-Referer': 'https://github.com/abdou-da0wew/SpectrulenPor',
            'X-Title': 'SpectruLenPor',
          },
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

      if (_streamingAvailable) {
        await _playStreamed(body.stream);
      } else {
        await _playViaFile(body.stream);
      }
    } catch (e) {
      debugPrint('[OpenRouterTts] error: $e — native TTS remains the '
          'offline fallback.');
    }
  }

  /// Pipe the HTTP byte stream into just_audio via StreamAudioSource.
  /// `sourceLength: null` → progressive/live streaming, starts immediately.
  Future<void> _playStreamed(Stream<Uint8List> byteStream) async {
    try {
      _streamPlayer ??= AudioPlayer();

      // Buffer bytes through a controller so the audio sink pulls at its
      // own pace while dio keeps downloading.
      final controller = StreamController<List<int>>();
      final sub = byteStream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
        cancelOnError: true,
      );

      final source = _TtsStreamSource(controller.stream);
      await _streamPlayer!.setAudioSource(source);
      await _streamPlayer!.play();

      // Cleanup after playback completes (or next speak() stops us).
      _streamPlayer!.playerStateStream.listen((state) {
        if (state.processingState == ProcessingState.completed) {
          sub.cancel();
        }
      });
    } catch (e) {
      debugPrint('[OpenRouterTts] streamed playback unavailable: $e');
      _streamingAvailable = false;
    }
  }

  /// Fallback: buffer whole MP3 to a temp file, play via audioplayers.
  Future<void> _playViaFile(Stream<Uint8List> byteStream) async {
    final chunks = <int>[];
    await for (final c in byteStream) {
      chunks.addAll(c);
    }
    if (chunks.isEmpty) return;
    await _playMp3Bytes(Uint8List.fromList(chunks));
  }

  Future<void> _playMp3Bytes(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/tts_${DateTime.now().microsecondsSinceEpoch}.mp3';
    final f = io.File(path);
    await f.writeAsBytes(bytes, flush: true);

    _filePlayer ??= AudioPlayer();
    await _filePlayer!.play(DeviceFileSource(path));
  }

  /// Stop any narration immediately (called on mute / new speak / dispose).
  Future<void> stop() async {
    try {
      await _streamPlayer?.stop();
    } catch (_) {}
    try {
      await _filePlayer?.stop();
    } catch (_) {}
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

  Future<void> dispose() async {
    await _streamPlayer?.dispose();
    await _filePlayer?.dispose();
  }
}

/// just_audio source that consumes a live HTTP byte stream.
class _TtsStreamSource extends StreamAudioSource {
  _TtsStreamSource(this._bytes);

  final Stream<List<int>> _bytes;

  @override
  Future<StreamAudioResponse> request([bool? requestHeaders]) async {
    return StreamAudioResponse(
      sourceLength: null, // unknown → progressive streaming
      contentType: 'audio/mpeg',
      stream: _bytes,
    );
  }
}
