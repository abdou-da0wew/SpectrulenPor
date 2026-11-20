import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smart_glass_app/services/openrouter_model_catalog.dart';

Map<String, dynamic> model(
  String id, {
  List<String> input = const ['text'],
  List<String> output = const ['text'],
}) {
  return {
    'id': id,
    'name': id,
    'description': 'Test model',
    'context_length': 8192,
    'architecture': {
      'input_modalities': input,
      'output_modalities': output,
    },
  };
}

void main() {
  group('OpenRouterModelCatalog', () {
    test('catalog only exposes explicit free text chat models', () async {
      final catalog = OpenRouterModelCatalog(
        clientFactory: () => MockClient((request) async {
          expect(request.url, OpenRouterModelCatalog.modelsUri);
          return http.Response(
            jsonEncode({
              'data': [
                model('provider/alpha:free'),
                model('provider/paid'),
                model(
                  'provider/audio:free',
                  input: ['audio'],
                  output: ['audio'],
                ),
                model('provider/vision:free', input: ['text', 'image']),
              ],
            }),
            200,
          );
        }),
      );

      final models = await catalog.fetchFreeModels(forceRefresh: true);
      expect(
        models.map((item) => item.id),
        containsAll([
          'provider/alpha:free',
          'provider/vision:free',
        ]),
      );
      expect(models, hasLength(2));
      expect(models.every((item) => item.isFreeVariant), isTrue);
      expect(models.every((item) => item.supportsTextOutput), isTrue);
    });

    test('custom model must be in the live free catalogue', () async {
      final catalog = OpenRouterModelCatalog(
        clientFactory: () => MockClient((request) async {
          return http.Response(
            jsonEncode({
              'data': [model('provider/alpha:free')],
            }),
            200,
          );
        }),
      );

      final result = await catalog.validateCustomFreeModel(
        modelId: 'provider/alpha:free',
      );
      expect(result.id, 'provider/alpha:free');

      await expectLater(
        catalog.validateCustomFreeModel(modelId: 'provider/paid'),
        throwsA(isA<OpenRouterCatalogException>()),
      );
      await expectLater(
        catalog.validateCustomFreeModel(modelId: 'malformed'),
        throwsA(isA<OpenRouterCatalogException>()),
      );
    });

    test('model test sends a real chat completion request', () async {
      late Map<String, dynamic> requestBody;
      final catalog = OpenRouterModelCatalog(
        clientFactory: () => MockClient((request) async {
          expect(request.url, OpenRouterModelCatalog.chatCompletionsUri);
          expect(request.headers['authorization'], 'Bearer test-key');
          requestBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'MODEL_OK'}
                }
              ],
            }),
            200,
          );
        }),
      );

      final result = await catalog.testModel(
        modelId: 'provider/alpha:free',
        apiKey: 'test-key',
      );
      expect(requestBody['model'], 'provider/alpha:free');
      expect(result.output, 'MODEL_OK');
      expect(result.modelId, 'provider/alpha:free');
      expect(result.latency, isA<Duration>());
    });

    test('model test rejects missing API keys and paid models', () async {
      final catalog = OpenRouterModelCatalog(
        clientFactory: () => MockClient((request) async {
          fail('A request must not be made for invalid credentials/models.');
        }),
      );

      await expectLater(
        catalog.testModel(
          modelId: 'provider/alpha:free',
          apiKey: '',
        ),
        throwsA(isA<OpenRouterCatalogException>()),
      );
      await expectLater(
        catalog.testModel(
          modelId: 'provider/paid',
          apiKey: 'test-key',
        ),
        throwsA(isA<OpenRouterCatalogException>()),
      );
    });

    test('model test surfaces provider HTTP errors', () async {
      final catalog = OpenRouterModelCatalog(
        clientFactory: () => MockClient((request) async {
          return http.Response(
            jsonEncode({
              'error': {'message': 'Provider capacity reached'}
            }),
            429,
          );
        }),
      );

      await expectLater(
        catalog.testModel(
          modelId: 'provider/alpha:free',
          apiKey: 'test-key',
        ),
        throwsA(
          isA<OpenRouterCatalogException>().having(
            (error) => error.message,
            'message',
            contains('429'),
          ),
        ),
      );
    });
  });
}
