import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_glass_app/models/bounding_box.dart';
import 'package:smart_glass_app/models/captured_frames.dart';
import 'package:smart_glass_app/models/chat_message.dart';
import 'package:smart_glass_app/models/citation.dart';
import 'package:smart_glass_app/models/conversation_context.dart';
import 'package:smart_glass_app/models/spectrum_reading.dart';
import 'package:smart_glass_app/services/internal_db_service.dart';
import 'package:smart_glass_app/services/moondream_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('InternalDatabaseService (all 9 tables)', () {
    test('saves, lists, hydrates, appends messages & deletes chat sessions',
        () async {
      final db = InternalDatabaseService.forTest();
      await db.init();

      final frames = CapturedFrames(
        cleanJpeg: Uint8List.fromList([1, 2, 3, 4]),
        withBoxesJpeg: Uint8List.fromList([5, 6, 7, 8]),
        selectedBox: const BoundingBox(
          x: 0.2,
          y: 0.2,
          w: 0.4,
          h: 0.4,
          label: 'Ethanol',
          confidence: 0.94,
        ),
        capturedAt: DateTime.utc(2026, 10, 28, 12, 0),
      );
      final md = MoondreamStructuredAnalysis(
        caption: 'Clear volatile liquid in flask',
        whatItIs: 'Ethanol (C2H5OH)',
        howItsUsed: 'Lab solvent and disinfectant',
        whatsAround: 'Fume hood',
        visibleText: 'EtOH 99%',
        hazards: 'Flammable liquid',
        stateOfMatter: 'liquid',
      );
      const ctx = ConversationContext(
        objectIdentified: 'Ethanol',
        chemicalFormula: 'C2H5OH',
        stateOfMatter: 'liquid',
      );

      await db.saveChatSession(
        sessionId: 'sess_1',
        frames: frames,
        moondream: md,
        firstLlmContext: 'Ethanol is a volatile alcohol [1].',
        runningContext: ctx,
        messages: [
          ChatMessage(
            role: 'assistant',
            content: 'Ethanol is a volatile alcohol [1].',
            at: DateTime.utc(2026, 10, 28, 12, 0),
            citations: const [
              Citation(
                index: 1,
                title: 'Ethanol (C2H5OH)',
                url: 'https://pubchem.ncbi.nlm.nih.gov/compound/702',
                snippet: 'Boiling point 78.37 °C',
                type: CitationType.pubchem,
              ),
            ],
            verifiedCount: 1,
          ),
        ],
      );

      await db.appendChatMessage(
        sessionId: 'sess_1',
        seq: 1,
        message: ChatMessage(
          role: 'user',
          content: 'What is its flash point?',
          at: DateTime.utc(2026, 10, 28, 12, 1),
        ),
        runningContext: ctx.merge(
          const ConversationContext(openQuestions: ['flash point']),
        ),
      );

      final list = await db.listChatSessions();
      expect(list, hasLength(1));
      expect(list.first.title, 'Ethanol');
      expect(list.first.messageCount, 2);

      final hydrated = await db.loadChatSession('sess_1');
      expect(hydrated, isNotNull);
      expect(hydrated!.messages, hasLength(2));
      expect(hydrated.messages.first.citations, hasLength(1));
      expect(hydrated.summary.runningContext.openQuestions, ['flash point']);

      await db.deleteChatSession('sess_1');
      expect(await db.listChatSessions(), isEmpty);
    });

    test('TTL response caching increments hit_count and prunes expired rows',
        () async {
      final db = InternalDatabaseService.forTest();
      await db.init();

      await db.putCached(
        'pubchem',
        'Gold',
        const {'cid': 23985, 'formula': 'Au'},
        ttl: const Duration(hours: 1),
      );
      await db.putCached(
        'pubchem',
        'ExpiredSample',
        const {'cid': 1},
        ttl: const Duration(milliseconds: -10),
      );

      final hit = await db.getCached('pubchem', ' gold ');
      expect(hit, isA<Map>());
      expect((hit as Map)['formula'], 'Au');

      final expired = await db.getCached('pubchem', 'ExpiredSample');
      expect(expired, isNull);

      await db.pruneCache(clearAll: true);
      expect(await db.getCached('pubchem', 'Gold'), isNull);
    });

    test('logs, crash/hang reports, telemetry, traces, user_data & export work',
        () async {
      final db = InternalDatabaseService.forTest();
      await db.init();

      await db.logInfo('YOLO', 'Model staged');
      await db.logError('Network', 'Timeout on query', error: 'SocketTimeout');

      await db.recordCrashOrHang(
        kind: 'hang',
        summary: 'UI frame stall > 2800 ms',
        context: {'stallMs': 3100},
      );

      await db.recordTelemetry(
        channel: 'ble_spectrum',
        reading: SpectrumReading(
          uvRaw: 1200,
          irRaw: 800,
          at: DateTime.utc(2026, 10, 28),
        ),
        hazard: false,
      );

      final res = await db.traceAsync('yolo.detect', () async => 42);
      expect(res, 42);

      await db.putUserData('preferred_lab_unit', 'SI', category: 'prefs');
      expect(await db.getUserData('preferred_lab_unit'), 'SI');

      await db.recordActivity('test_action', target: 'Beaker');

      final errorLogs = await db.getLogs(level: 'ERROR');
      expect(errorLogs, hasLength(1));
      expect(await db.getCrashHangReports(), hasLength(1));
      expect(await db.getRecentTelemetry(), hasLength(1));
      expect(await db.getRecentTraces(), hasLength(1));
      expect(await db.getRecentActivities(), hasLength(1));

      final stats = await db.getStats();
      expect(stats['app_logs'], 2);
      expect(stats['crash_hang_reports'], 1);
      expect(stats['pipeline_traces'], 1);

      final dump = await db.exportDiagnosticsDump();
      expect(dump['stats'], isA<Map>());
      expect(dump['recentLogs'], isA<List>());
    });
  });
}
