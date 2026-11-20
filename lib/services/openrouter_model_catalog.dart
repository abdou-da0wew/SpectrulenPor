import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// A chat-capable OpenRouter model. The catalog is read live from OpenRouter;
/// only explicit :free variants are offered by this selector.
class OpenRouterModel {
  const OpenRouterModel({
    required this.id,
    required this.name,
    required this.description,
    required this.inputModalities,
    required this.outputModalities,
    required this.contextLength,
  });

  final String id;
  final String name;
  final String description;
  final List<String> inputModalities;
  final List<String> outputModalities;
  final int contextLength;

  bool get supportsTextInput => inputModalities.contains('text');
  bool get supportsVision => inputModalities.contains('image');
  bool get supportsTextOutput => outputModalities.contains('text');
  bool get isFreeVariant => id.endsWith(':free');

  String get category {
    if (supportsVision) return 'Vision';
    final normalized = '${id.toLowerCase()} ${name.toLowerCase()}';
    if (normalized.contains('coder') ||
        normalized.contains('code') ||
        normalized.contains('devstral')) {
      return 'Coding';
    }
    if (normalized.contains('reason') ||
        normalized.contains('thinking') ||
        normalized.contains('r1')) {
      return 'Reasoning';
    }
    return 'General';
  }

  factory OpenRouterModel.fromJson(Map<String, dynamic> json) {
    final architecture = json['architecture'] is Map
        ? Map<String, dynamic>.from(json['architecture'] as Map)
        : const <String, dynamic>{};
    return OpenRouterModel(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? json['id'] ?? 'Unknown model').toString(),
      description: (json['description'] ?? '').toString(),
      inputModalities: _stringList(architecture['input_modalities']),
      outputModalities: _stringList(architecture['output_modalities']),
      contextLength: (json['context_length'] as num?)?.toInt() ?? 0,
    );
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) return const [];
    return value.map((item) => item.toString()).toList(growable: false);
  }
}

class ModelTestResult {
  const ModelTestResult({
    required this.modelId,
    required this.latency,
    required this.output,
  });

  final String modelId;
  final Duration latency;
  final String output;
}

/// Fetches OpenRouter's live model catalogue and performs a real chat request
/// to verify a selected model. The in-memory cache expires after six hours;
/// the Settings UI also exposes an explicit refresh action.
class OpenRouterModelCatalog {
  OpenRouterModelCatalog({
    http.Client Function()? clientFactory,
    DateTime Function()? clock,
  })  : _clientFactory = clientFactory ?? http.Client.new,
        _clock = clock ?? DateTime.now;

  static final OpenRouterModelCatalog instance = OpenRouterModelCatalog();
  static final Uri modelsUri = Uri.parse('https://openrouter.ai/api/v1/models');
  static final Uri chatCompletionsUri =
      Uri.parse('https://openrouter.ai/api/v1/chat/completions');
  static const Duration cacheTtl = Duration(hours: 6);

  final http.Client Function() _clientFactory;
  final DateTime Function() _clock;
  List<OpenRouterModel>? _cached;
  DateTime? _cachedAt;

  Future<List<OpenRouterModel>> fetchFreeModels({
    String apiKey = '',
    bool forceRefresh = false,
  }) async {
    final cached = _cached;
    final cachedAt = _cachedAt;
    if (!forceRefresh &&
        cached != null &&
        cachedAt != null &&
        _clock().difference(cachedAt) < cacheTtl) {
      return List<OpenRouterModel>.unmodifiable(cached);
    }

    final client = _clientFactory();
    try {
      final headers = <String, String>{'Accept': 'application/json'};
      if (apiKey.trim().isNotEmpty) {
        headers['Authorization'] = 'Bearer ${apiKey.trim()}';
      }
      final response = await client
          .get(modelsUri, headers: headers)
          .timeout(const Duration(seconds: 18));
      if (response.statusCode != 200) {
        throw OpenRouterCatalogException(
          'OpenRouter model catalogue returned HTTP ${response.statusCode}.',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['data'] is! List) {
        throw const OpenRouterCatalogException(
          'OpenRouter returned an invalid model catalogue.',
        );
      }

      final models = (decoded['data'] as List)
          .whereType<Map>()
          .map((item) => OpenRouterModel.fromJson(
                Map<String, dynamic>.from(item),
              ))
          .where((model) =>
              model.isFreeVariant &&
              model.supportsTextInput &&
              model.supportsTextOutput)
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

      _cached = List<OpenRouterModel>.unmodifiable(models);
      _cachedAt = _clock();
      return List<OpenRouterModel>.unmodifiable(models);
    } on TimeoutException {
      throw const OpenRouterCatalogException(
        'Timed out while refreshing OpenRouter models.',
      );
    } finally {
      client.close();
    }
  }

  Future<OpenRouterModel> validateCustomFreeModel({
    required String modelId,
    String apiKey = '',
  }) async {
    final normalized = modelId.trim();
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._:-]*:free$')
        .hasMatch(normalized)) {
      throw const OpenRouterCatalogException(
        'Use a valid OpenRouter model ID ending in :free.',
      );
    }
    final models = await fetchFreeModels(
      apiKey: apiKey,
      forceRefresh: true,
    );
    for (final model in models) {
      if (model.id == normalized) return model;
    }
    throw OpenRouterCatalogException(
      '$normalized was not found in OpenRouter\'s current free chat catalogue.',
    );
  }

  Future<ModelTestResult> testModel({
    required String modelId,
    required String apiKey,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw const OpenRouterCatalogException(
        'Add an OpenRouter API key before testing a model.',
      );
    }
    if (!modelId.endsWith(':free')) {
      throw const OpenRouterCatalogException(
        'Only explicitly free OpenRouter model variants can be tested here.',
      );
    }

    final client = _clientFactory();
    final watch = Stopwatch()..start();
    try {
      final response = await client
          .post(
            chatCompletionsUri,
            headers: {
              'Authorization': 'Bearer ${apiKey.trim()}',
              'Content-Type': 'application/json',
              'HTTP-Referer': 'https://github.com/abdou-da0wew/SpectrulenPor',
              'X-Title': 'SpectruLenPor model diagnostics',
            },
            body: jsonEncode({
              'model': modelId,
              'messages': [
                {
                  'role': 'user',
                  'content': 'Reply with exactly MODEL_OK and nothing else.',
                }
              ],
              'max_tokens': 24,
              'temperature': 0,
              'stream': false,
            }),
          )
          .timeout(const Duration(seconds: 35));
      watch.stop();

      if (response.statusCode != 200) {
        var detail = response.body;
        try {
          final json = jsonDecode(response.body);
          if (json is Map && json['error'] is Map) {
            detail = (json['error']['message'] ?? detail).toString();
          }
        } catch (_) {}
        throw OpenRouterCatalogException(
          'Model test failed (HTTP ${response.statusCode}): $detail',
        );
      }

      final json = jsonDecode(response.body);
      final choices = json is Map ? json['choices'] : null;
      final first =
          choices is List && choices.isNotEmpty ? choices.first : null;
      final message = first is Map ? first['message'] : null;
      final output =
          message is Map ? (message['content'] ?? '').toString().trim() : '';
      if (output.isEmpty) {
        throw const OpenRouterCatalogException(
          'The model responded without any text output.',
        );
      }
      return ModelTestResult(
        modelId: modelId,
        latency: watch.elapsed,
        output: output,
      );
    } on TimeoutException {
      throw const OpenRouterCatalogException(
        'The model test timed out before a response arrived.',
      );
    } finally {
      client.close();
    }
  }
}

class OpenRouterCatalogException implements Exception {
  const OpenRouterCatalogException(this.message);

  final String message;

  @override
  String toString() => message;
}
