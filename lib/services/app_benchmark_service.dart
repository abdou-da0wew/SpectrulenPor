import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart';

import 'openrouter_service.dart';
import 'speech_text_corrector.dart';

class SpeechCorrectionCase {
  const SpeechCorrectionCase({
    required this.id,
    required this.input,
    required this.expected,
    required this.languageCode,
  });

  final String id;
  final String input;
  final String expected;
  final String languageCode;
}

/// Deterministic quality/performance checks that run without a network or
/// connected glasses. The golden corpus is versioned so results stay comparable.
class AppBenchmarkService {
  static const int corpusVersion = 1;

  static const List<SpeechCorrectionCase> speechCorrectionCorpus = [
    SpeechCorrectionCase(
        id: 'en-openrouter',
        input: 'open router',
        expected: 'OpenRouter.',
        languageCode: 'en-US'),
    SpeechCorrectionCase(
        id: 'en-fish-audio',
        input: 'fish audio',
        expected: 'Fish Audio.',
        languageCode: 'en-US'),
    SpeechCorrectionCase(
        id: 'en-supertonic',
        input: 'super tonic 3',
        expected: 'Supertonic-3.',
        languageCode: 'en-US'),
    SpeechCorrectionCase(
        id: 'en-vosk',
        input: 'vos k',
        expected: 'Vosk.',
        languageCode: 'en-US'),
    SpeechCorrectionCase(
        id: 'en-esp32cam',
        input: 'esp 32 cam',
        expected: 'ESP32-CAM.',
        languageCode: 'en-US'),
    SpeechCorrectionCase(
        id: 'en-moondream-onnx',
        input: 'moon dream and on n x',
        expected: 'Moondream and ONNX.',
        languageCode: 'en-US'),
    SpeechCorrectionCase(
        id: 'en-uv',
        input: 'turn on the uv light',
        expected: 'Turn on the UV light.',
        languageCode: 'en-US'),
    SpeechCorrectionCase(
        id: 'en-ir',
        input: 'where is the ir sensor',
        expected: 'Where is the IR sensor.',
        languageCode: 'en-US'),
    SpeechCorrectionCase(
        id: 'ar-diacritics',
        input: 'مَرْحَبًا',
        expected: 'مرحبا.',
        languageCode: 'ar-EG'),
    SpeechCorrectionCase(
        id: 'ar-moondream',
        input: 'مون دريم',
        expected: 'Moondream.',
        languageCode: 'ar-EG'),
    SpeechCorrectionCase(
        id: 'ar-yolo',
        input: 'يو لو ٢٦ نانو',
        expected: 'YOLO26-Nano.',
        languageCode: 'ar-EG'),
    SpeechCorrectionCase(
        id: 'ar-esp32',
        input: 'إي إس بي ٣٢',
        expected: 'ESP32.',
        languageCode: 'ar-EG'),
  ];

  static Future<Map<String, dynamic>> runSpeechCorrectionBenchmark({
    int iterations = 40,
    int warmupIterations = 5,
  }) async {
    if (iterations < 1 || iterations > 1000) {
      throw ArgumentError.value(iterations, 'iterations', 'Must be 1..1000');
    }

    for (var warmup = 0; warmup < warmupIterations; warmup++) {
      for (final sample in speechCorrectionCorpus) {
        SpeechTextCorrector.correct(
          sample.input,
          languageCode: sample.languageCode,
          isFinal: true,
        );
      }
    }

    final latenciesMicros = <int>[];
    final caseResults = <Map<String, dynamic>>[];
    var exactMatches = 0;
    var totalWordErrors = 0;
    var totalReferenceWords = 0;
    var totalCharacterErrors = 0;
    var totalReferenceCharacters = 0;

    for (final sample in speechCorrectionCorpus) {
      var corrected = '';
      for (var iteration = 0; iteration < iterations; iteration++) {
        final stopwatch = Stopwatch()..start();
        corrected = SpeechTextCorrector.correct(
          sample.input,
          languageCode: sample.languageCode,
          isFinal: true,
        );
        stopwatch.stop();
        latenciesMicros.add(stopwatch.elapsedMicroseconds);
      }

      final normalizedExpected = _normalizeForScoring(sample.expected);
      final normalizedActual = _normalizeForScoring(corrected);
      final wordReference = _tokens(normalizedExpected);
      final wordHypothesis = _tokens(normalizedActual);
      final characterReference = normalizedExpected.runes.toList();
      final characterHypothesis = normalizedActual.runes.toList();
      final wordErrors = _editDistance(wordReference, wordHypothesis);
      final characterErrors =
          _editDistance(characterReference, characterHypothesis);
      final exact = normalizedExpected == normalizedActual;

      if (exact) exactMatches++;
      totalWordErrors += wordErrors;
      totalReferenceWords += math.max(1, wordReference.length).toInt();
      totalCharacterErrors += characterErrors;
      totalReferenceCharacters +=
          math.max(1, characterReference.length).toInt();

      caseResults.add({
        'id': sample.id,
        'language': sample.languageCode,
        'input': sample.input,
        'expected': sample.expected,
        'actual': corrected,
        'exactMatch': exact,
        'wordErrors': wordErrors,
        'characterErrors': characterErrors,
      });
    }

    final sorted = List<int>.from(latenciesMicros)..sort();
    final totalMicros = sorted.fold<int>(0, (sum, value) => sum + value);
    final meanMicros = totalMicros / math.max(1, sorted.length);

    return {
      'corpusVersion': corpusVersion,
      'caseCount': speechCorrectionCorpus.length,
      'iterationsPerCase': iterations,
      'sampleCount': sorted.length,
      'exactMatchRate': exactMatches / speechCorrectionCorpus.length,
      'wordErrorRate': totalWordErrors / math.max(1, totalReferenceWords),
      'characterErrorRate':
          totalCharacterErrors / math.max(1, totalReferenceCharacters),
      'latencyMs': {
        'p50': _percentile(sorted, 0.50) / 1000.0,
        'p95': _percentile(sorted, 0.95) / 1000.0,
        'mean': meanMicros / 1000.0,
      },
      'throughputSamplesPerSecond':
          meanMicros <= 0 ? 0.0 : 1000000.0 / meanMicros,
      'cases': caseResults,
    };
  }

  /// Three fixed-answer checks. Pass rate is a small task score, not a claim
  /// of general LLM factual accuracy or a substitute for human evaluation.
  static Future<Map<String, dynamic>> runOpenRouterBenchmark(
    OpenRouterService service, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    if (!service.isConfigured) {
      throw StateError(
          'Configure an OpenRouter API key before running this test.');
    }

    const tasks = <({String id, String prompt, String expected})>[
      (
        id: 'arithmetic-42',
        prompt: 'What is 17 + 25? Return only the result.',
        expected: '42'
      ),
      (
        id: 'water-formula',
        prompt:
            'What is the chemical formula for water? Return only the formula.',
        expected: 'H2O'
      ),
      (
        id: 'egypt-capital',
        prompt: 'What is the capital of Egypt? Return only the city name.',
        expected: 'Cairo'
      ),
    ];

    final results = <Map<String, dynamic>>[];
    var passed = 0;

    for (final task in tasks) {
      final stopwatch = Stopwatch()..start();
      int? firstTokenMs;
      final response = StringBuffer();

      try {
        await for (final chunk in service.streamRawMessages(
          [
            {
              'role': 'system',
              'content':
                  'You are running a deterministic benchmark. Answer with the shortest correct answer. Do not add an explanation.',
            },
            {'role': 'user', 'content': task.prompt},
          ],
        ).timeout(timeout)) {
          firstTokenMs ??= stopwatch.elapsedMilliseconds;
          response.write(chunk);
        }
        stopwatch.stop();

        final actual = response.toString().trim();
        final normalized = _normalizeForScoring(actual).replaceAll(' ', '');
        final expected =
            _normalizeForScoring(task.expected).replaceAll(' ', '');
        // Strict whole-answer match: substring scoring would incorrectly give
        // points to answers such as 'not 42'.
        final correct = normalized == expected;
        if (correct) passed++;

        results.add({
          'id': task.id,
          'expected': task.expected,
          'actual': actual,
          'passed': correct,
          'timeToFirstTokenMs': firstTokenMs,
          'totalLatencyMs': stopwatch.elapsedMilliseconds,
          'model': service.lastModelUsed,
        });
      } catch (error) {
        stopwatch.stop();
        results.add({
          'id': task.id,
          'expected': task.expected,
          'passed': false,
          'error': error.toString(),
          'timeToFirstTokenMs': firstTokenMs,
          'totalLatencyMs': stopwatch.elapsedMilliseconds,
          'model': service.lastModelUsed,
        });
      }
    }

    return {
      'taskCount': tasks.length,
      'passed': passed,
      'passRate': passed / tasks.length,
      'model': service.lastModelUsed,
      'tasks': results,
      'scoringNote':
          'Pass rate checks three fixed expected answers. It is not a general semantic accuracy score.',
    };
  }

  static Future<String> saveReport(Map<String, dynamic> report) async {
    final directory = await getApplicationDocumentsDirectory();
    final reports = Directory(directory.path + '/benchmark-reports');
    await reports.create(recursive: true);
    final timestamp =
        DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final encoder = const JsonEncoder.withIndent('  ');
    final file = File(reports.path + '/spectrulenpor-' + timestamp + '.json');
    await file.writeAsString(encoder.convert(report), flush: true);
    await File(reports.path + '/latest.json')
        .writeAsString(encoder.convert(report), flush: true);
    return file.path;
  }

  static String _normalizeForScoring(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[\u064B-\u065F\u0670\u0640]'), '')
      .replaceAll(RegExp(r'[.,!?;:،؛؟]'), '')
      .replaceAll('"', '')
      .replaceAll("'", '')
      .replaceAll('(', '')
      .replaceAll(')', '')
      .replaceAll('[', '')
      .replaceAll(']', '')
      .replaceAll('{', '')
      .replaceAll('}', '')
      .replaceAll('<', '')
      .replaceAll('>', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static List<String> _tokens(String value) =>
      value.isEmpty ? const [] : value.split(' ');

  static int _percentile(List<int> sorted, double percentile) {
    if (sorted.isEmpty) return 0;
    return sorted[((sorted.length - 1) * percentile).round()];
  }

  static int _editDistance<T>(List<T> left, List<T> right) {
    if (left.isEmpty) return right.length;
    if (right.isEmpty) return left.length;

    var previous = List<int>.generate(right.length + 1, (index) => index);
    for (var i = 1; i <= left.length; i++) {
      final current = List<int>.filled(right.length + 1, 0);
      current[0] = i;
      for (var j = 1; j <= right.length; j++) {
        final substitution =
            previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1);
        current[j] = math
            .min(
              math.min(previous[j] + 1, current[j - 1] + 1),
              substitution,
            )
            .toInt();
      }
      previous = current;
    }
    return previous.last;
  }
}
