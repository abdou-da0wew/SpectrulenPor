import 'package:flutter_test/flutter_test.dart';

import 'package:smart_glass_app/services/app_benchmark_service.dart';

void main() {
  group('AppBenchmarkService', () {
    test('bilingual correction golden corpus reports accuracy metrics',
        () async {
      final report = await AppBenchmarkService.runSpeechCorrectionBenchmark(
        iterations: 3,
        warmupIterations: 1,
      );

      expect(report['corpusVersion'], AppBenchmarkService.corpusVersion);
      expect(report['caseCount'], 12);
      expect(report['sampleCount'], 36);
      expect(report['exactMatchRate'], 1.0);
      expect(report['wordErrorRate'], 0.0);
      expect(report['characterErrorRate'], 0.0);

      final latency = report['latencyMs'] as Map<String, dynamic>;
      expect(latency['p50'], isA<double>());
      expect(latency['p95'], isA<double>());
      expect((latency['p95'] as double), greaterThanOrEqualTo(0));
      expect(report['throughputSamplesPerSecond'], greaterThan(0));
    });

    test('corpus records both Arabic and English cases', () {
      final languages = AppBenchmarkService.speechCorrectionCorpus
          .map((sample) => sample.languageCode.substring(0, 2))
          .toSet();

      expect(languages, containsAll(<String>['ar', 'en']));
    });
  });
}
