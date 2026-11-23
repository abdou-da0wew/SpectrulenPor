import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/app_benchmark_service.dart';
import '../services/openrouter_service.dart';
import '../services/supertonic_tts_service.dart';
import '../services/yolo_detector.dart';
import '../utils/app_icons.dart';

class BenchmarkLabScreen extends StatefulWidget {
  const BenchmarkLabScreen({super.key});

  @override
  State<BenchmarkLabScreen> createState() => _BenchmarkLabScreenState();
}

class _BenchmarkLabScreenState extends State<BenchmarkLabScreen> {
  static const _metricsChannel =
      MethodChannel('spectrulenpor/benchmark/metrics');

  bool _runningLocal = false;
  bool _runningLlm = false;
  bool _runningTts = false;
  Map<String, dynamic>? _report;
  String? _reportPath;
  String? _status;
  String? _error;

  Future<void> _runLocalSuite() async {
    setState(() {
      _runningLocal = true;
      _status =
          'Collecting device metrics and running the bilingual golden corpus…';
      _error = null;
    });
    try {
      final device =
          await _metricsChannel.invokeMapMethod<String, dynamic>('snapshot');
      final speech = await AppBenchmarkService.runSpeechCorrectionBenchmark();
      final yolo = YoloDetector.instance;
      final report = <String, dynamic>{
        'schemaVersion': 1,
        'suite': 'SpectruLenPor in-app benchmark',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'device': device ?? const <String, dynamic>{},
        'speechCorrection': speech,
        'visionRuntimeSnapshot': {
          'modelReady': yolo.isReady,
          'lastInferenceMs': yolo.lastInferenceMs,
          'executionProvider': yolo.status.executionProvider,
          'providerWarmupMs': yolo.status.epWarmupMs,
          'inputShape': yolo.status.inputShape,
          'outputShape': yolo.status.outputShape,
          'resourceGovernor': yolo.status.resourceGovernor,
          'accuracyMeasured': false,
          'accuracyNote':
              'Vision accuracy needs a labelled image corpus. Runtime status is not an accuracy score.',
        },
        'externalMacrobenchmark': {
          'status': 'not-run-in-app',
          'note':
              'Run AndroidX Macrobenchmark on a connected Android device for cold/warm startup, frame timing and memory metrics.',
        },
      };
      final path = await AppBenchmarkService.saveReport(report);
      if (!mounted) return;
      setState(() {
        _report = report;
        _reportPath = path;
        _status = 'Local benchmark completed and report saved.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _status = 'Local benchmark failed.';
      });
    } finally {
      if (mounted) setState(() => _runningLocal = false);
    }
  }

  Future<void> _runOpenRouterSuite() async {
    final service = context.read<OpenRouterService>();
    if (!service.isConfigured) {
      setState(() {
        _error =
            'Configure an OpenRouter API key in Settings → AI & Models first.';
      });
      return;
    }
    setState(() {
      _runningLlm = true;
      _error = null;
      _status =
          'Sending three bounded benchmark prompts to the active model chain…';
    });
    try {
      final result = await AppBenchmarkService.runOpenRouterBenchmark(service);
      final report = <String, dynamic>{
        ...?_report,
        'schemaVersion': 1,
        'suite': 'SpectruLenPor in-app benchmark',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'openRouter': result,
      };
      final path = await AppBenchmarkService.saveReport(report);
      if (!mounted) return;
      setState(() {
        _report = report;
        _reportPath = path;
        _status = 'OpenRouter benchmark completed.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _status = 'OpenRouter benchmark failed.';
      });
    } finally {
      if (mounted) setState(() => _runningLlm = false);
    }
  }

  Future<void> _runSupertonicSuite() async {
    final service = SupertonicTtsService.instance;
    setState(() {
      _runningTts = true;
      _error = null;
      _status = 'Checking local Supertonic model files…';
    });
    try {
      if (!await service.hasInstalledModels()) {
        throw StateError(
            'Supertonic-3 is not installed. Install it from Settings → Voice before benchmarking.');
      }
      final samples = <Map<String, dynamic>>[];
      final english = await service.benchmarkSynthesis(
        'A quick local speech synthesis benchmark.',
        languageCode: 'en-US',
      );
      if (english != null) samples.add({'id': 'english', ...english});
      final arabic = await service.benchmarkSynthesis(
        'هذا اختبار لسرعة وجودة توليد الكلام باللغة العربية.',
        languageCode: 'ar-EG',
      );
      if (arabic != null) samples.add({'id': 'arabic', ...arabic});
      if (samples.isEmpty) {
        throw StateError('Supertonic did not return any synthesis samples.');
      }
      final report = <String, dynamic>{
        ...?_report,
        'schemaVersion': 1,
        'suite': 'SpectruLenPor in-app benchmark',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'supertonicTts': {
          'engine': 'Supertonic-3 / ONNX Runtime',
          'samples': samples,
          'scoringNote':
              'Latency and real-time factor are measured. Audio naturalness and pronunciation accuracy require reference clips or human/listening evaluation.',
        },
      };
      final path = await AppBenchmarkService.saveReport(report);
      if (!mounted) return;
      setState(() {
        _report = report;
        _reportPath = path;
        _status = 'Supertonic synthesis benchmark completed.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _status = 'Supertonic benchmark could not run.';
      });
    } finally {
      if (mounted) setState(() => _runningTts = false);
    }
  }

  Future<void> _copyReport() async {
    final report = _report;
    if (report == null) return;
    await Clipboard.setData(
      ClipboardData(text: const JsonEncoder.withIndent('  ').convert(report)),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Benchmark report copied as JSON.')),
    );
  }

  String _percent(dynamic value) =>
      value is num ? (value * 100).toStringAsFixed(1) + '%' : '—';

  String _number(dynamic value, {int decimals = 2, String suffix = ''}) =>
      value is num ? value.toStringAsFixed(decimals) + suffix : '—';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final speech = _report?['speechCorrection'] as Map<String, dynamic>?;
    final llm = _report?['openRouter'] as Map<String, dynamic>?;
    final tts = _report?['supertonicTts'] as Map<String, dynamic>?;
    final device = _report?['device'] as Map<String, dynamic>?;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Benchmark Lab'),
        actions: [
          if (_report != null)
            IconButton(
              tooltip: 'Copy JSON report',
              onPressed: _copyReport,
              icon: const Icon(AppIcons.contentCopy),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          Text(
            'Measure real performance and test correctness against fixed references.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _runningLocal ? null : _runLocalSuite,
            icon: _runningLocal
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(AppIcons.speed),
            label: Text(_runningLocal
                ? 'Running local suite…'
                : 'Run local accuracy & device suite'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _runningLlm ? null : _runOpenRouterSuite,
            icon: _runningLlm
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(AppIcons.cloudQueueRounded),
            label: Text(_runningLlm
                ? 'Testing OpenRouter…'
                : 'Benchmark active OpenRouter models'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _runningTts ? null : _runSupertonicSuite,
            icon: _runningTts
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(AppIcons.recordVoiceOver),
            label: Text(_runningTts
                ? 'Synthesizing…'
                : 'Benchmark on-device Supertonic TTS'),
          ),
          if (_status != null) ...[
            const SizedBox(height: 12),
            Text(_status!, style: theme.textTheme.bodySmall),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!,
                    style:
                        TextStyle(color: theme.colorScheme.onErrorContainer)),
              ),
            ),
          ],
          const SizedBox(height: 18),
          if (speech != null) ...[
            _sectionTitle(context, 'Speech correction · Arabic + English'),
            _metricGrid(context, [
              _metric('Exact match', _percent(speech['exactMatchRate'])),
              _metric('Word error rate', _percent(speech['wordErrorRate'])),
              _metric('Character error rate',
                  _percent(speech['characterErrorRate'])),
              _metric(
                  'P95 latency',
                  _number((speech['latencyMs'] as Map?)?['p95'],
                      suffix: ' ms')),
              _metric(
                  'P50 latency',
                  _number((speech['latencyMs'] as Map?)?['p50'],
                      suffix: ' ms')),
              _metric(
                  'Throughput',
                  _number(speech['throughputSamplesPerSecond'],
                      decimals: 0, suffix: '/s')),
            ]),
            Text(
              speech['caseCount'].toString() +
                  ' golden cases · ' +
                  speech['iterationsPerCase'].toString() +
                  ' iterations each · corpus v' +
                  speech['corpusVersion'].toString(),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
          ],
          if (llm != null) ...[
            _sectionTitle(context, 'OpenRouter · fixed-answer task benchmark'),
            _metricGrid(context, [
              _metric('Task pass rate', _percent(llm['passRate'])),
              _metric('Passed tasks',
                  llm['passed'].toString() + '/' + llm['taskCount'].toString()),
              _metric('Model', (llm['model'] ?? 'unknown').toString()),
            ]),
            Text(
              'This is a three-question smoke/consistency score, not general factual accuracy.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
          ],
          if (tts != null) ...[
            _sectionTitle(context, 'Supertonic-3 · ONNX synthesis'),
            for (final sample in (tts['samples'] as List<dynamic>? ?? const []))
              Card(
                child: ListTile(
                  leading: const Icon(AppIcons.recordVoiceOver),
                  title: Text(
                    sample['id'].toString() +
                        ' · ' +
                        _number(sample['latencyMs'],
                            decimals: 0, suffix: ' ms'),
                  ),
                  subtitle: Text(
                    'Audio ' +
                        _number(sample['audioDurationMs'],
                            decimals: 0, suffix: ' ms') +
                        ' · RTF ' +
                        _number(sample['realTimeFactor'], decimals: 2) +
                        ' · ' +
                        sample['outputBytes'].toString() +
                        ' bytes',
                  ),
                ),
              ),
            const SizedBox(height: 12),
          ],
          if (device != null) ...[
            _sectionTitle(context, 'Device snapshot'),
            _metricGrid(context, [
              _metric(
                  'Device',
                  ((device['manufacturer'] ?? '').toString() +
                          ' ' +
                          (device['deviceModel'] ?? '').toString())
                      .trim()),
              _metric('CPU cores', (device['cpuCores'] ?? '—').toString()),
              _metric(
                  'App PSS', (device['appPssKb'] ?? '—').toString() + ' KB'),
              _metric(
                  'Available RAM',
                  _number(
                        (device['availableRamBytes'] as num?) == null
                            ? null
                            : (device['availableRamBytes'] as num) /
                                (1024 * 1024),
                        decimals: 0,
                      ) +
                      ' MB'),
              _metric('Thermal status',
                  (device['thermalStatus'] ?? '—').toString()),
              _metric(
                  'Battery',
                  device['batteryPercent'] == null
                      ? '—'
                      : _number(device['batteryPercent'], decimals: 0) + '%'),
            ]),
            const SizedBox(height: 12),
          ],
          _sectionTitle(context, 'Measurements that need real datasets'),
          _coverageCard(
            context,
            title: 'Vosk STT accuracy',
            detail:
                'Needs paired Arabic and English WAV recordings with human-verified transcripts. Report WER/CER per language; do not score empty audio or live mic guesses.',
          ),
          _coverageCard(
            context,
            title: 'YOLO / vision accuracy',
            detail:
                'Needs labelled images and reference bounding boxes/classes. Report mAP50, precision, recall and per-class results alongside inference latency.',
          ),
          _coverageCard(
            context,
            title: 'TTS pronunciation / naturalness',
            detail:
                'Latency and real-time factor are measurable now. MOS, intelligibility and pronunciation accuracy need reference clips or blinded human ratings.',
          ),
          const SizedBox(height: 8),
          if (_reportPath != null)
            SelectableText('Saved report: ' + _reportPath!,
                style: theme.textTheme.bodySmall),
          Text(
            'For startup, frame pacing, jank and memory under repeatable device conditions, run the separate AndroidX Macrobenchmark instrumentation suite. It emits iteration metrics and Perfetto traces.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  _Metric _metric(String label, String value) => _Metric(label, value);

  Widget _sectionTitle(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _metricGrid(BuildContext context, List<_Metric> metrics) {
    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 760 ? 3 : 2;
    return GridView.count(
      crossAxisCount: columns,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: columns == 2 ? 2.5 : 2.8,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: [
        for (final metric in metrics)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(metric.label,
                      style: Theme.of(context).textTheme.labelSmall),
                  const SizedBox(height: 4),
                  Text(
                    metric.value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _coverageCard(BuildContext context,
          {required String title, required String detail}) =>
      Card(
        child: ListTile(
          dense: true,
          leading: const Icon(AppIcons.infoOutline),
          title: Text(title),
          subtitle: Text(detail),
        ),
      );
}

class _Metric {
  const _Metric(this.label, this.value);
  final String label;
  final String value;
}
