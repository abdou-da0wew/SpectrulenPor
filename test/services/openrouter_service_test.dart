import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smart_glass_app/services/openrouter_service.dart';

/// Builds an SSE body the way OpenRouter streams chat completions.
String sseBody({
  required String model,
  required List<String> deltas,
  int? reasoningTokens,
}) {
  final buf = StringBuffer();
  for (final d in deltas) {
    buf.writeln('data: ${jsonEncode({
      'id': 'c1',
      'model': model,
      'choices': [
        {'delta': {'content': d}, 'index': 0}
      ],
    })}');
  }
  final usage = <String, dynamic>{
    'prompt_tokens': 10,
    'completion_tokens': 20,
  };
  if (reasoningTokens != null) {
    usage['completion_tokens_details'] = {'reasoning_tokens': reasoningTokens};
  }
  buf.writeln('data: ${jsonEncode({
    'id': 'c1',
    'model': model,
    'choices': <dynamic>[],
    'usage': usage,
  })}');
  buf.writeln('data: [DONE]');
  return buf.toString();
}

void main() {
  test('not-configured service yields a hint instead of a network call',
      () async {
    final svc = OpenRouterService(apiKey: '');
    final out = await svc.streamAnalysis(labelSentence: 'a beaker').toList();
    expect(out.join(), contains('OpenRouter API key not set'));
  });

  test('primary model streams and reports chain index 0', () async {
    String? seenModel;
    final svc = OpenRouterService(
      apiKey: 'k',
      clientFactory: () => MockClient.streaming((req, _) async {
        final body = jsonDecode((req as http.Request).body) as Map<String, dynamic>;
        seenModel = body['model'] as String;
        return http.StreamedResponse(
          http.ByteStream.fromBytes(utf8.encode(sseBody(model: seenModel!, deltas: ['Hello ', 'lab']))),
          200,
        );
      }),
    );

    final out = await svc
        .streamAnalysis(labelSentence: 'a beaker', moondreamAnalysis: 'glass')
        .toList();
    expect(out.join(), 'Hello lab');
    expect(seenModel, OpenRouterService.modelChain.first);
    expect(svc.lastChainIndex, 0);
    expect(svc.lastModelUsed, OpenRouterService.modelChain.first);
  });

  test('HTTP failure on primary falls through to fallback #1', () async {
    final requested = <String>[];
    final svc = OpenRouterService(
      apiKey: 'k',
      clientFactory: () => MockClient.streaming((req, _) async {
        final body = jsonDecode((req as http.Request).body) as Map<String, dynamic>;
        final model = body['model'] as String;
        requested.add(model);
        if (model == OpenRouterService.modelChain[0]) {
          return http.StreamedResponse(
              http.ByteStream.fromBytes(utf8.encode('upstream error')), 500);
        }
        return http.StreamedResponse(
          http.ByteStream.fromBytes(utf8.encode(
              sseBody(model: model, deltas: ['Fallback works']))),
          200,
        );
      }),
    );

    final out =
        await svc.streamAnalysis(labelSentence: 'a beaker').toList();
    expect(out.join(), 'Fallback works');
    expect(requested.first, OpenRouterService.modelChain[0]);
    expect(svc.lastChainIndex, 1);
  });

  test('whole chain failing yields a readable error line', () async {
    final svc = OpenRouterService(
      apiKey: 'k',
      clientFactory: () => MockClient.streaming(
          (req, _) async => http.StreamedResponse(
              http.ByteStream.fromBytes(utf8.encode('nope')), 503)),
    );

    final out =
        await svc.streamAnalysis(labelSentence: 'a beaker').toList();
    expect(out.join(), contains('Could not reach any presentation model'));
  });

  test('reasoning tokens captured from the final usage chunk', () async {
    final svc = OpenRouterService(
      apiKey: 'k',
      clientFactory: () => MockClient.streaming((req, _) async {
        final body = jsonDecode((req as http.Request).body) as Map<String, dynamic>;
        return http.StreamedResponse(
          http.ByteStream.fromBytes(utf8.encode(sseBody(
              model: body['model'] as String,
              deltas: ['Answer'],
              reasoningTokens: 42))),
          200,
        );
      }),
    );

    await svc.streamAnalysis(labelSentence: 'x').toList();
    expect(svc.lastReasoningTokens, 42);
  });

  test('startModel pins the chain entry point', () async {
    String? seenModel;
    final svc = OpenRouterService(
      apiKey: 'k',
      clientFactory: () => MockClient.streaming((req, _) async {
        final body = jsonDecode((req as http.Request).body) as Map<String, dynamic>;
        seenModel = body['model'] as String;
        return http.StreamedResponse(
          http.ByteStream.fromBytes(
              utf8.encode(sseBody(model: seenModel!, deltas: ['ok']))),
          200,
        );
      }),
    );

    await svc.streamAnalysis(labelSentence: 'x', startModel: 2).toList();
    expect(seenModel, OpenRouterService.modelChain[2]);
    expect(svc.lastChainIndex, 2);
  });

  test('system prompt requires a hazard line and the user prompt embeds '
      'the analyst output', () async {
    String? sys, user;
    final svc = OpenRouterService(
      apiKey: 'k',
      clientFactory: () => MockClient.streaming((req, _) async {
        final body = jsonDecode((req as http.Request).body) as Map<String, dynamic>;
        sys = body['messages'][0]['content'] as String;
        user = body['messages'][1]['content'] as String;
        return http.StreamedResponse(
          http.ByteStream.fromBytes(
              utf8.encode(sseBody(model: 'm', deltas: ['ok']))),
          200,
        );
      }),
    );

    await svc
        .streamAnalysis(
      labelSentence: 'a beaker',
      moondreamAnalysis: 'clear glass beaker',
      telemetry: r'$UV:10;IR:20',
    )
        .toList();

    expect(sys, contains('SpectruLenPor'));
    expect(sys, contains('Warning:'));
    expect(user, contains('a beaker'));
    expect(user, contains('clear glass beaker'));
  });

  test('default LLM key is a plain string (secrets come from config asset)',
      () {
    expect(OpenRouterService.defaultApiKey, isA<String>());
  });
}
