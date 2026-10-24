import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Moondream3 Cloud API — THE primary vision source for SpectruLenPor.
///
/// Docs: https://docs.moondream.ai (API, Streaming, Reasoning, Rate limits)
///   * Base URL ........ https://api.moondream.ai/v1
///   * Auth ............ `X-Moondream-Auth: <key>` (skill endpoints)
///   * Model ........... `moondream3.1-9B-A2B` (9B MoE, 2B active, 32k ctx)
///                       fallback id: `moondream3-preview`
///   * Images .......... base64 data-URLs ONLY (data:image/jpeg;base64,…)
///   * Streaming ....... SSE `data: {"chunk": "text"}` frames
///   * Reasoning ....... `reasoning: true` → answer arrives after an explicit
///                       reasoning trace (higher accuracy, higher latency)
///   * Rate limits ..... 2 req/s base tier (10 req/s funded)
///
/// Pipeline role (per project design):
///   Moondream3 cloud = the SPECIALIZED ANALYST. It looks at the frame and
///   produces the factual analysis (what the substance is, visible text,
///   colors, state). The OpenRouter LLM (gemma → inkling → nemotron chain)
///   only PRESENTS that analysis in nicer spoken words. TTS then narrates.
///
/// Local fallback: when the cloud call fails (no key / offline / 429 /
/// timeout) we transparently fall back to the on-device Moondream engine
/// through the native platform channel `com.spectraglass/llama`
/// (llama.cpp + mmproj GGUF). See `local_vision_service.dart` for the full
/// cascade: cloud → local Moondream → ONNX → ML Kit.
class MoondreamService {
  /// Injectable http client for tests.
  MoondreamService({http.Client? client}) : _clientOverride = client;

  static final MoondreamService instance = MoondreamService();

  /// Demo key resolution: SharedPreferences (Settings) →
  /// `assets/config/secrets.json` (AppSecrets) → `--dart-define` → ''.
  /// Empty by default in source so pushes pass GitHub secret-scanning.
  static const String defaultApiKey = String.fromEnvironment('MOONDREAM_API_KEY');

  final http.Client? _clientOverride;

  /// Real host on mobile/desktop; relative CORS-proxy path when compiled
  /// for web preview (scripts/preview_server.py mounts /moondream/v1/*).
  static String get baseUrl =>
      kIsWeb ? '/moondream/v1' : 'https://api.moondream.ai/v1';

  /// Hot-swappable from Settings (no restart needed).
  String apiKey = '';

  /// Primary model id. Docs list `moondream3.1-9B-A2B` and
  /// `moondream3-preview`. We auto-fallback to preview on 400/404 model
  /// errors so older keys keep working.
  String model = 'moondream3.1-9B-A2B';

  /// Set after each call — surfaced in the UI latency HUD.
  double? lastTtftMs;
  double? lastDecodeMs;
  String? lastRequestId;

  bool get isCloudConfigured => apiKey.trim().isNotEmpty;

  http.Client? _client;
  http.Client get _http => _clientOverride ?? (_client ??= http.Client());

  // ---------------------------------------------------------------------------
  // IMAGE ENCODING
  // ---------------------------------------------------------------------------

  /// Moondream accepts base64 data-URLs only (remote http URLs are rejected
  /// with 400). JPEG bytes straight from ESP32-CAM / phone camera encode 1:1.
  String toDataUrl(Uint8List jpegBytes) =>
      'data:image/jpeg;base64,${base64Encode(jpegBytes)}';

  // ---------------------------------------------------------------------------
  // CAPTION  (POST /v1/caption) — fast whole-scene description
  // ---------------------------------------------------------------------------

  /// One-shot caption. `length` = 'short' (fastest) | 'normal' | 'long'.
  Future<MoondreamCaption?> caption(
    Uint8List jpegBytes, {
    String length = 'short',
  }) async {
    if (!isCloudConfigured) return null;
    try {
      final res = await _http
          .post(
            Uri.parse('$baseUrl/caption'),
            headers: _headers,
            body: jsonEncode({
              'model': model,
              'image_url': toDataUrl(jpegBytes),
              'length': length,
              'stream': false,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        _logResponseError('caption', res);
        return null;
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      lastRequestId = json['request_id'] as String?;
      _absorbMetrics(json['metrics']);
      return MoondreamCaption(
        caption: (json['caption'] as String?) ?? '',
        requestId: lastRequestId,
      );
    } catch (e) {
      log('[Moondream] caption failed: $e');
      return null;
    }
  }

  /// Streamed caption — first words arrive in well under a second on the
  /// cloud tier, so we can start speaking almost immediately.
  ///
  /// SSE frames: `data: {"chunk": "The"}` — we yield the text deltas.
  Stream<String> streamCaption(
    Uint8List jpegBytes, {
    String length = 'short',
  }) async* {
    if (!isCloudConfigured) return;
    final sw = Stopwatch()..start();
    var ttftSent = false;
    await for (final evt in _sse(
      '$baseUrl/caption',
      body: {
        'model': model,
        'image_url': toDataUrl(jpegBytes),
        'length': length,
        'stream': true,
      },
    )) {
      if (!ttftSent) {
        lastTtftMs = sw.elapsedMilliseconds.toDouble();
        ttftSent = true;
      }
      final chunk = evt['chunk'] as String?;
      if (chunk != null && chunk.isNotEmpty) yield chunk;
    }
    sw.stop();
  }

  // ---------------------------------------------------------------------------
  // QUERY  (POST /v1/query) — the deep, chemistry-aware analysis
  // ---------------------------------------------------------------------------

  /// One-shot VQA. With [reasoning]=true Moondream emits an explicit
  /// reasoning trace before the answer (better accuracy on counting /
  /// spatial / multi-step questions, at the cost of latency).
  Future<MoondreamAnswer?> query(
    Uint8List jpegBytes, {
    required String question,
    bool reasoning = false,
  }) async {
    if (!isCloudConfigured) return null;
    try {
      final res = await _http
          .post(
            Uri.parse('$baseUrl/query'),
            headers: _headers,
            body: jsonEncode({
              'model': model,
              'image_url': toDataUrl(jpegBytes),
              'question': question,
              if (reasoning) 'reasoning': true,
              'stream': false,
            }),
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        _logResponseError('query', res);
        return null;
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      lastRequestId = json['request_id'] as String?;
      return MoondreamAnswer(
        answer: (json['answer'] as String?) ?? '',
        // reasoning arrives as a STRING on some tiers and as an OBJECT
        // {text, grounding} on moondream3.x — normalize to text.
        reasoning: _normalizeReasoning(json['reasoning']),
        requestId: lastRequestId,
      );
    } catch (e) {
      log('[Moondream] query failed: $e');
      return null;
    }
  }

  /// Streamed VQA. Yields answer chunks; if [reasoning] is true and the
  /// server emits a reasoning trace, those chunks are yielded too — the
  /// caller distinguishes them via [MoondreamChunk.isReasoning].
  Stream<MoondreamChunk> streamQuery(
    Uint8List jpegBytes, {
    required String question,
    bool reasoning = false,
  }) async* {
    if (!isCloudConfigured) return;
    await for (final evt in _sse(
      '$baseUrl/query',
      body: {
        'model': model,
        'image_url': toDataUrl(jpegBytes),
        'question': question,
        if (reasoning) 'reasoning': true,
        'stream': true,
      },
    )) {
      final chunk = evt['chunk'] as String?;
      if (chunk == null || chunk.isEmpty) continue;
      // When reasoning is enabled the API streams the trace first; the
      // server marks those frames with a `reasoning` boolean field when
      // present. Absence of the field means normal answer tokens.
      yield MoondreamChunk(
        text: chunk,
        isReasoning: evt['reasoning'] == true,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // DETECT  (POST /v1/detect) — grounded boxes (hazard pointing etc.)
  // ---------------------------------------------------------------------------

  /// Returns normalized bounding boxes [0..1] for [object] in the frame.
  Future<List<MoondreamBox>> detect(
    Uint8List jpegBytes,
    String object,
  ) async {
    if (!isCloudConfigured) return const [];
    try {
      final res = await _http
          .post(
            Uri.parse('$baseUrl/detect'),
            headers: _headers,
            body: jsonEncode({
              'model': model,
              'image_url': toDataUrl(jpegBytes),
              'object': object,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        _logResponseError('detect', res);
        return const [];
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final objects = (json['objects'] as List?) ?? const [];
      return objects
          .whereType<Map<String, dynamic>>()
          .map(MoondreamBox.fromJson)
          .toList(growable: false);
    } catch (e) {
      log('[Moondream] detect failed: $e');
      return const [];
    }
  }

  // ---------------------------------------------------------------------------
  // LOCAL MOONDREAM FALLBACK (platform channel → llama.cpp + mmproj GGUF)
  // ---------------------------------------------------------------------------

  static const MethodChannel _localChannel =
      MethodChannel('com.spectraglass/llama');

  /// Caption via the on-device Moondream engine. Returns null when the
  /// native engine is not built (MissingPluginException) or errors — the
  /// vision cascade then continues to ONNX / ML Kit.
  Future<String?> localCaption(
    Uint8List jpegBytes, {
    String? ggufPath,
    String prompt = 'Describe this image in one short sentence.',
  }) async {
    try {
      final result = await _localChannel.invokeMethod<String>(
        'moondream_caption',
        {
          'modelPath': ggufPath,
          'jpgBytes': jpegBytes,
          'prompt': prompt,
          'maxTokens': 48,
        },
      );
      return (result != null && result.trim().isNotEmpty) ? result : null;
    } on MissingPluginException {
      debugPrint('[Moondream] local engine not built — see README '
          '(Moondream native build).');
      return null;
    } catch (e) {
      log('[Moondream] local error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // INTERNALS
  // ---------------------------------------------------------------------------

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-Moondream-Auth': apiKey.trim(),
      };

  /// Minimal SSE reader for Moondream's `data: {json}` protocol.
  /// Yields each JSON frame; terminates on stream close or [DONE].
  Stream<Map<String, dynamic>> _sse(
    String url, {
    required Map<String, dynamic> body,
  }) async* {
    final request = http.Request('POST', Uri.parse(url))
      ..headers.addAll(_headers)
      ..body = jsonEncode(body);

    final client = _http;
    final streamed = await client.send(request).timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw TimeoutException('Moondream SSE connect'),
        );
    if (streamed.statusCode != 200) {
      final err = await streamed.stream.bytesToString();
      _logHttpError('stream', streamed.statusCode, err);
      return;
    }

    final lineStream = streamed.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lineStream) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') break;
      try {
        final json = jsonDecode(payload) as Map<String, dynamic>;
        // Metrics frames arrive with the tail; harvest TTFT if present.
        _absorbMetrics(json['metrics']);
        yield json;
      } catch (e) {
        log('[Moondream] SSE parse: $e');
      }
    }
  }

  void _absorbMetrics(dynamic metrics) {
    if (metrics is Map<String, dynamic>) {
      final ttft = (metrics['ttft_ms'] as num?)?.toDouble();
      final decode = (metrics['decode_time_ms'] as num?)?.toDouble();
      if (ttft != null) lastTtftMs = ttft;
      if (decode != null) lastDecodeMs = decode;
    }
  }

  static String? _normalizeReasoning(dynamic r) {
    if (r is String && r.trim().isNotEmpty) return r;
    if (r is Map<String, dynamic>) {
      final t = r['text'];
      if (t is String && t.trim().isNotEmpty) return t;
    }
    return null;
  }

  void _logResponseError(String op, http.Response res) =>
      _logHttpError(op, res.statusCode, res.body);

  void _logHttpError(String op, int code, String body) {
    final short = body.length > 180 ? '${body.substring(0, 180)}…' : body;
    log('[Moondream] $op HTTP $code: $short');
    // Older keys may not know moondream3.1 — silently degrade to preview.
    if ((code == 400 || code == 404) && model != 'moondream3-preview') {
      model = 'moondream3-preview';
      log('[Moondream] falling back to model=moondream3-preview');
    }
  }

  void dispose() {
    _client?.close();
    _client = null;
  }
}

/// One streamed token from /query (answer or reasoning trace).
class MoondreamChunk {
  const MoondreamChunk({required this.text, this.isReasoning = false});
  final String text;
  final bool isReasoning;
}

/// Result of POST /v1/caption.
class MoondreamCaption {
  const MoondreamCaption({required this.caption, this.requestId});
  final String caption;
  final String? requestId;
}

/// Result of POST /v1/query (with optional reasoning trace).
class MoondreamAnswer {
  const MoondreamAnswer({
    required this.answer,
    this.reasoning,
    this.requestId,
  });
  final String answer;
  final String? reasoning;
  final String? requestId;
}

/// Normalized bounding box from POST /v1/detect.
class MoondreamBox {
  const MoondreamBox({
    required this.xMin,
    required this.yMin,
    required this.xMax,
    required this.yMax,
  });

  factory MoondreamBox.fromJson(Map<String, dynamic> j) => MoondreamBox(
        xMin: (j['x_min'] as num?)?.toDouble() ?? 0,
        yMin: (j['y_min'] as num?)?.toDouble() ?? 0,
        xMax: (j['x_max'] as num?)?.toDouble() ?? 0,
        yMax: (j['y_max'] as num?)?.toDouble() ?? 0,
      );

  final double xMin, yMin, xMax, yMax;
  double get cx => (xMin + xMax) / 2;
  double get cy => (yMin + yMax) / 2;
}
