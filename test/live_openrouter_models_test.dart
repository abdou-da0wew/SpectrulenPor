import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_glass_app/services/openrouter_service.dart';

void main() {
  final apiKey = Platform.environment['OPENROUTER_TEST_API_KEY']?.trim() ?? '';
  const labels = <String>[
    'Nemotron 3.5 Super VL (primary)',
    'Gemma 4 26B A4B (fallback 1)',
    'Inkling 2 Small (fallback 2)',
  ];

  for (var index = 0; index < OpenRouterService.modelChain.length; index++) {
    test(
      'live OpenRouter streaming: ${labels[index]}',
      () async {
        final service = OpenRouterService(apiKey: apiKey);
        final chunks = await service
            .streamAnalysis(
              labelSentence: 'Water (H2O, CAS 7732-18-5)',
              moondreamAnalysis:
                  'A clear, colorless liquid in a transparent laboratory beaker.',
              lang: 'en',
              startModel: index,
            )
            .toList()
            .timeout(const Duration(seconds: 150));

        final answer = chunks.join().trim();
        final servedIndex = service.lastChainIndex;
        expect(answer, isNotEmpty, reason: 'No text was streamed.');
        expect(
          answer,
          isNot(contains('Could not reach any presentation model')),
          reason: 'OpenRouter exhausted the chain: $answer',
        );
        expect(
          servedIndex,
          index,
          reason:
              'Expected ${OpenRouterService.modelChain[index]}, but the chain served ${service.lastModelUsed}.',
        );
        // Deliberately log only model IDs and response length. Never log credentials.
        // ignore: avoid_print
        print(
          'LIVE PASS: requested=${OpenRouterService.modelChain[index]}, '
          'served=${service.lastModelUsed}, chars=${answer.length}',
        );
      },
      skip: apiKey.isEmpty
          ? 'Set OPENROUTER_TEST_API_KEY to run authenticated model smoke tests.'
          : false,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
