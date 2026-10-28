import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/bounding_box.dart';
import '../models/captured_frames.dart';
import '../models/chat_message.dart';
import '../models/citation.dart';
import '../models/conversation_context.dart';
import '../models/spectrum_reading.dart';
import 'db_file_store.dart';
import 'moondream_service.dart';

/// Summary metadata for a persisted chat session.
class SavedChatSummary {
  final String id;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String title;
  final String selectedLabel;
  final double selectedConfidence;
  final BoundingBox selectedBox;
  final String? cleanJpegPath;
  final String? boxedJpegPath;
  final MoondreamStructuredAnalysis moondreamAnalysis;
  final String firstLlmContext;
  final ConversationContext runningContext;
  final String locale;
  final int messageCount;

  const SavedChatSummary({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    required this.title,
    required this.selectedLabel,
    required this.selectedConfidence,
    required this.selectedBox,
    this.cleanJpegPath,
    this.boxedJpegPath,
    required this.moondreamAnalysis,
    required this.firstLlmContext,
    required this.runningContext,
    required this.locale,
    required this.messageCount,
  });
}

/// Full hydrated chat session loaded from [InternalDatabaseService].
class HydratedChatRecord {
  final SavedChatSummary summary;
  final CapturedFrames frames;
  final List<ChatMessage> messages;

  const HydratedChatRecord({
    required this.summary,
    required this.frames,
    required this.messages,
  });
}

/// Internal database service for SpectruLenPor.
///
/// Dual-engine persistence:
///   * **Android**: Native SQLite WAL database (`spectrulenpor_internal.db`)
///     via `AppDatabaseChannel` (`com.spectraglass/db`).
///   * **Desktop / Web / Tests**: File-backed atomic JSON store (`DbFileStore`)
///     with identical 9-table schema, TTL cache eviction, and retention pruning.
///
/// Covers all 9 operational domains:
///   1. `chat_sessions`      — saved object analyses & anchored sessions
///   2. `chat_messages`      — full chat history + citations + fact-check counts
///   3. `response_cache`     — TTL cache for Wikipedia, PubChem, Web, Docs & AI
///   4. `app_logs`           — structured DEBUG/INFO/WARN/ERROR logs
///   5. `crash_hang_reports` — uncaught exceptions, UI hangs & pipeline timeouts
///   6. `telemetry_events`   — UV/IR sensor packets, VisionGate & FPS telemetry
///   7. `pipeline_traces`    — execution spans (`duration_ms`) per AI stage
///   8. `user_data`          — user notes, pinned preferences & profile state
///   9. `user_activity`      — chronological user history & activity audit trail
class InternalDatabaseService {
  InternalDatabaseService._();
  static final InternalDatabaseService instance = InternalDatabaseService._();

  @visibleForTesting
  InternalDatabaseService.forTest({String? directoryPath})
      : _testDirOverride = directoryPath,
        _forceLocalFallback = true;

  static const MethodChannel _channel = MethodChannel('com.spectraglass/db');
  static const String _fallbackFile = 'internal_db_v1.json';

  static const List<String> allTables = [
    'chat_sessions',
    'chat_messages',
    'response_cache',
    'app_logs',
    'crash_hang_reports',
    'telemetry_events',
    'pipeline_traces',
    'user_data',
    'user_activity',
  ];

  final DbFileStore _fileStore = DbFileStore();
  String? _testDirOverride;
  bool _forceLocalFallback = false;

  bool _initialized = false;
  bool _useNativeSqlite = false;
  String _dbPath = '';
  int _seqCounter = 0;

  /// Recent breadcrumbs attached automatically to crash/hang reports.
  final ListQueue<String> _breadcrumbs = ListQueue<String>(40);

  /// Local fallback table storage (keyed by table name -> primaryKey -> row).
  final Map<String, Map<String, Map<String, dynamic>>> _memTables = {
    for (final t in allTables) t: <String, Map<String, dynamic>>{},
  };
  Timer? _flushTimer;

  bool get isInitialized => _initialized;
  bool get usesNativeSqlite => _useNativeSqlite;
  String get databasePath => _dbPath;

  String _nextId(String prefix) {
    _seqCounter = (_seqCounter + 1) & 0x7FFFFFFF;
    final micros = DateTime.now().microsecondsSinceEpoch;
    return '${prefix}_${micros}_$_seqCounter';
  }

  void addBreadcrumb(String crumb) {
    final stamp = DateTime.now().toIso8601String();
    if (_breadcrumbs.length >= 40) _breadcrumbs.removeFirst();
    _breadcrumbs.add('[$stamp] $crumb');
  }

  Future<void> init() async {
    if (_initialized) return;
    await _fileStore.init(overrideDir: _testDirOverride);

    if (!_forceLocalFallback && !kIsWeb) {
      try {
        final info =
            await _channel.invokeMapMethod<String, dynamic>('init');
        if (info != null && info['backend'] == 'android_sqlite_wal') {
          _useNativeSqlite = true;
          _dbPath = (info['path'] as String?) ?? 'spectrulenpor_internal.db';
          _initialized = true;
          addBreadcrumb('InternalDB initialized (native SQLite WAL)');
          unawaited(evictExpiredCache());
          return;
        }
      } on MissingPluginException {
        _useNativeSqlite = false;
      } catch (e) {
        debugPrint('[InternalDB] Native SQLite unavailable, using file store: $e');
        _useNativeSqlite = false;
      }
    }

    // Load local JSON store from disk if available.
    _dbPath = '${_fileStore.basePath}/$_fallbackFile';
    final raw = await _fileStore.readText(_fallbackFile);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        for (final table in allTables) {
          final list = decoded[table];
          if (list is List) {
            final pkCol = _primaryKeyFor(table);
            for (final item in list.whereType<Map<String, dynamic>>()) {
              final pk = item[pkCol]?.toString();
              if (pk != null && pk.isNotEmpty) {
                _memTables[table]![pk] = Map<String, dynamic>.from(item);
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[InternalDB] Corrupt fallback snapshot ignored: $e');
      }
    }
    _initialized = true;
    addBreadcrumb('InternalDB initialized (file JSON engine)');
    await evictExpiredCache();
  }

  String _primaryKeyFor(String table) => switch (table) {
        'response_cache' => 'cache_key',
        'user_data' => 'key',
        _ => 'id',
      };

  Future<void> flushNow() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_useNativeSqlite || !_initialized) return;
    final payload = <String, dynamic>{
      for (final t in allTables) t: _memTables[t]!.values.toList(growable: false),
    };
    await _fileStore.writeText(_fallbackFile, jsonEncode(payload));
  }

  void _scheduleFlush() {
    if (_useNativeSqlite) return;
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 120), () {
      unawaited(flushNow());
    });
  }

  Future<void> _upsert(String table, Map<String, dynamic> values) async {
    if (!_initialized) await init();
    if (_useNativeSqlite) {
      await _channel.invokeMethod<dynamic>('upsert', {
        'table': table,
        'values': values,
      });
      return;
    }
    final pk = values[_primaryKeyFor(table)]?.toString();
    if (pk == null || pk.isEmpty) return;
    _memTables[table]![pk] = Map<String, dynamic>.from(values);
    _scheduleFlush();
  }

  Future<List<Map<String, dynamic>>> _query(
    String table, {
    String? where,
    List<String>? whereArgs,
    String? orderBy,
    int? limit,
    bool Function(Map<String, dynamic>)? memFilter,
    int Function(Map<String, dynamic>, Map<String, dynamic>)? memSort,
  }) async {
    if (!_initialized) await init();
    if (_useNativeSqlite) {
      final rows = await _channel.invokeListMethod<dynamic>('query', {
        'table': table,
        if (where != null) 'where': where,
        if (whereArgs != null) 'whereArgs': whereArgs,
        if (orderBy != null) 'orderBy': orderBy,
        if (limit != null) 'limit': limit,
      });
      if (rows == null) return const [];
      return rows
          .whereType<Map>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
          .toList(growable: false);
    }

    var list = _memTables[table]!.values.toList();
    if (memFilter != null) {
      list = list.where(memFilter).toList();
    }
    if (memSort != null) {
      list.sort(memSort);
    }
    if (limit != null && list.length > limit) {
      list = list.sublist(0, limit);
    }
    return list
        .map((m) => Map<String, dynamic>.from(m))
        .toList(growable: false);
  }

  Future<int> _delete(
    String table, {
    String? where,
    List<String>? whereArgs,
    bool Function(Map<String, dynamic>)? memPredicate,
  }) async {
    if (!_initialized) await init();
    if (_useNativeSqlite) {
      final count = await _channel.invokeMethod<int>('delete', {
        'table': table,
        if (where != null) 'where': where,
        if (whereArgs != null) 'whereArgs': whereArgs,
      });
      return count ?? 0;
    }
    final map = _memTables[table]!;
    if (memPredicate == null) {
      final n = map.length;
      map.clear();
      _scheduleFlush();
      return n;
    }
    final toRemove = <String>[];
    map.forEach((k, row) {
      if (memPredicate(row)) toRemove.add(k);
    });
    for (final k in toRemove) {
      map.remove(k);
    }
    if (toRemove.isNotEmpty) _scheduleFlush();
    return toRemove.length;
  }

  Future<void> _prune(String table, int maxRows, String orderCol) async {
    if (!_initialized) return;
    if (_useNativeSqlite) {
      try {
        await _channel.invokeMethod<dynamic>('pruneTable', {
          'table': table,
          'maxRows': maxRows,
          'orderCol': orderCol,
        });
      } catch (_) {}
      return;
    }
    final map = _memTables[table]!;
    if (map.length <= maxRows) return;
    final entries = map.entries.toList()
      ..sort((a, b) => ((b.value[orderCol] as num?) ?? 0)
          .compareTo((a.value[orderCol] as num?) ?? 0));
    for (final e in entries.skip(maxRows)) {
      map.remove(e.key);
    }
    _scheduleFlush();
  }

  // ===========================================================================
  // 1 & 2. CHAT SESSIONS & CHAT HISTORY
  // ===========================================================================

  Future<void> saveChatSession({
    required String sessionId,
    required CapturedFrames frames,
    required MoondreamStructuredAnalysis moondream,
    required String firstLlmContext,
    required ConversationContext runningContext,
    required List<ChatMessage> messages,
    String locale = 'en',
  }) async {
    if (!_initialized) await init();
    final now = DateTime.now().millisecondsSinceEpoch;

    String? cleanPath;
    String? boxedPath;
    try {
      cleanPath = await _fileStore.writeBinary(
        'frames/${sessionId}_clean.jpg',
        frames.cleanJpeg,
      );
      boxedPath = await _fileStore.writeBinary(
        'frames/${sessionId}_boxed.jpg',
        frames.withBoxesJpeg,
      );
    } catch (_) {}

    // Preserve original created_at if session already exists.
    final existing = await _query(
      'chat_sessions',
      where: 'id = ?',
      whereArgs: [sessionId],
      limit: 1,
      memFilter: (r) => r['id'] == sessionId,
    );
    final createdAt = existing.isNotEmpty
        ? ((existing.first['created_at'] as num?)?.toInt() ?? now)
        : frames.capturedAt.millisecondsSinceEpoch;

    final title = runningContext.objectIdentified.isNotEmpty
        ? runningContext.objectIdentified
        : frames.selectedBox.label;

    await _upsert('chat_sessions', {
      'id': sessionId,
      'created_at': createdAt,
      'updated_at': now,
      'title': title,
      'selected_label': frames.selectedBox.label,
      'selected_confidence': frames.selectedBox.confidence,
      'selected_box_json': jsonEncode(frames.selectedBox.toJson()),
      'clean_jpeg_path': cleanPath,
      'boxed_jpeg_path': boxedPath,
      'moondream_json': jsonEncode(_moondreamToJson(moondream)),
      'first_llm_context': firstLlmContext,
      'running_context_json': jsonEncode(runningContext.toJson()),
      'locale': locale,
      'message_count': messages.length,
    });

    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      await _upsert('chat_messages', {
        'id': '${sessionId}_msg_$i',
        'session_id': sessionId,
        'seq': i,
        'role': m.role,
        'content': m.content,
        'citations_json':
            jsonEncode(m.citations.map(_citationToJson).toList()),
        'verified_count': m.verifiedCount,
        'unverified_count': m.unverifiedCount,
        'model_used': null,
        'latency_ms': null,
        'created_at': m.at.millisecondsSinceEpoch,
      });
    }
    addBreadcrumb('Saved chat session $sessionId (${messages.length} msgs)');
  }

  Future<void> appendChatMessage({
    required String sessionId,
    required int seq,
    required ChatMessage message,
    required ConversationContext runningContext,
    String? modelUsed,
    int? latencyMs,
  }) async {
    if (!_initialized) await init();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _upsert('chat_messages', {
      'id': '${sessionId}_msg_$seq',
      'session_id': sessionId,
      'seq': seq,
      'role': message.role,
      'content': message.content,
      'citations_json':
          jsonEncode(message.citations.map(_citationToJson).toList()),
      'verified_count': message.verifiedCount,
      'unverified_count': message.unverifiedCount,
      'model_used': modelUsed,
      'latency_ms': latencyMs,
      'created_at': message.at.millisecondsSinceEpoch,
    });

    final rows = await _query(
      'chat_sessions',
      where: 'id = ?',
      whereArgs: [sessionId],
      limit: 1,
      memFilter: (r) => r['id'] == sessionId,
    );
    if (rows.isNotEmpty) {
      final updated = Map<String, dynamic>.from(rows.first);
      updated['updated_at'] = now;
      updated['running_context_json'] = jsonEncode(runningContext.toJson());
      updated['message_count'] = seq + 1;
      if (runningContext.objectIdentified.isNotEmpty) {
        updated['title'] = runningContext.objectIdentified;
      }
      await _upsert('chat_sessions', updated);
    }
  }

  Future<List<SavedChatSummary>> listChatSessions({int limit = 50}) async {
    final rows = await _query(
      'chat_sessions',
      orderBy: 'updated_at DESC',
      limit: limit,
      memSort: (a, b) => ((b['updated_at'] as num?) ?? 0)
          .compareTo((a['updated_at'] as num?) ?? 0),
    );
    return rows.map(_rowToSessionSummary).toList(growable: false);
  }

  Future<HydratedChatRecord?> loadChatSession(String sessionId) async {
    final sRows = await _query(
      'chat_sessions',
      where: 'id = ?',
      whereArgs: [sessionId],
      limit: 1,
      memFilter: (r) => r['id'] == sessionId,
    );
    if (sRows.isEmpty) return null;
    final summary = _rowToSessionSummary(sRows.first);

    final mRows = await _query(
      'chat_messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'seq ASC',
      memFilter: (r) => r['session_id'] == sessionId,
      memSort: (a, b) =>
          ((a['seq'] as num?) ?? 0).compareTo((b['seq'] as num?) ?? 0),
    );

    final cleanBytes = (summary.cleanJpegPath != null
            ? await _fileStore.readBinaryByPath(summary.cleanJpegPath!)
            : null) ??
        Uint8List(0);
    final boxedBytes = (summary.boxedJpegPath != null
            ? await _fileStore.readBinaryByPath(summary.boxedJpegPath!)
            : null) ??
        cleanBytes;

    final frames = CapturedFrames(
      cleanJpeg: cleanBytes,
      withBoxesJpeg: boxedBytes,
      selectedBox: summary.selectedBox,
      capturedAt: summary.createdAt,
    );

    final messages = mRows.map(_rowToChatMessage).toList(growable: false);
    return HydratedChatRecord(
      summary: summary,
      frames: frames,
      messages: messages,
    );
  }

  Future<Uint8List?> readImageFile(String? path) async {
    if (path == null || path.isEmpty) return null;
    return _fileStore.readBinaryByPath(path);
  }

  Future<void> deleteChatSession(String sessionId) async {
    final existing = await _query(
      'chat_sessions',
      where: 'id = ?',
      whereArgs: [sessionId],
      limit: 1,
      memFilter: (r) => r['id'] == sessionId,
    );
    if (existing.isNotEmpty) {
      final clean = existing.first['clean_jpeg_path'] as String?;
      final boxed = existing.first['boxed_jpeg_path'] as String?;
      if (clean != null) await _fileStore.deleteByPath(clean);
      if (boxed != null) await _fileStore.deleteByPath(boxed);
    }
    await _delete(
      'chat_messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      memPredicate: (r) => r['session_id'] == sessionId,
    );
    await _delete(
      'chat_sessions',
      where: 'id = ?',
      whereArgs: [sessionId],
      memPredicate: (r) => r['id'] == sessionId,
    );
  }

  // ===========================================================================
  // 3. RESPONSE CACHING (TTL + HIT COUNT)
  // ===========================================================================

  Future<dynamic> getCached(String namespace, String query) async {
    final key = '$namespace:${query.trim().toLowerCase()}';
    final rows = await _query(
      'response_cache',
      where: 'cache_key = ?',
      whereArgs: [key],
      limit: 1,
      memFilter: (r) => r['cache_key'] == key,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final now = DateTime.now().millisecondsSinceEpoch;
    final expiresAt = (row['expires_at'] as num?)?.toInt() ?? 0;
    if (expiresAt <= now) {
      await _delete(
        'response_cache',
        where: 'cache_key = ?',
        whereArgs: [key],
        memPredicate: (r) => r['cache_key'] == key,
      );
      return null;
    }

    final hits = ((row['hit_count'] as num?)?.toInt() ?? 0) + 1;
    final updated = Map<String, dynamic>.from(row)..['hit_count'] = hits;
    unawaited(_upsert('response_cache', updated));

    final payloadStr = row['payload_json'] as String?;
    if (payloadStr == null) return null;
    try {
      return jsonDecode(payloadStr);
    } catch (_) {
      return payloadStr;
    }
  }

  Future<void> putCache(
    String namespace,
    String query,
    Object? payload, {
    Duration ttl = const Duration(hours: 24),
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final key = '$namespace:${trimmed.toLowerCase()}';
    final now = DateTime.now().millisecondsSinceEpoch;
    await _upsert('response_cache', {
      'cache_key': key,
      'namespace': namespace,
      'query': trimmed,
      'payload_json': jsonEncode(payload),
      'created_at': now,
      'expires_at': now + ttl.inMilliseconds,
      'hit_count': 0,
    });
    unawaited(_prune('response_cache', 600, 'created_at'));
  }

  Future<int> evictExpiredCache() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _delete(
      'response_cache',
      where: 'expires_at <= ?',
      whereArgs: [now.toString()],
      memPredicate: (r) => ((r['expires_at'] as num?)?.toInt() ?? 0) <= now,
    );
  }

  Future<int> clearAllCache({String? namespace}) async {
    if (namespace != null) {
      return _delete(
        'response_cache',
        where: 'namespace = ?',
        whereArgs: [namespace],
        memPredicate: (r) => r['namespace'] == namespace,
      );
    }
    return _delete('response_cache');
  }

  Future<List<Map<String, dynamic>>> listCacheEntries({int limit = 100}) async {
    return _query(
      'response_cache',
      orderBy: 'created_at DESC',
      limit: limit,
      memSort: (a, b) => ((b['created_at'] as num?) ?? 0)
          .compareTo((a['created_at'] as num?) ?? 0),
    );
  }

  // ===========================================================================
  // 4. LOGS & ERROR LOGS
  // ===========================================================================

  Future<void> logDebug(String tag, String message,
          [Map<String, dynamic>? metadata]) =>
      _writeLog('DEBUG', tag, message, metadata: metadata);

  Future<void> logInfo(String tag, String message,
          [Map<String, dynamic>? metadata]) =>
      _writeLog('INFO', tag, message, metadata: metadata);

  Future<void> logWarn(String tag, String message,
          {Object? error, StackTrace? stackTrace, Map<String, dynamic>? metadata}) =>
      _writeLog('WARN', tag, message,
          error: error, stackTrace: stackTrace, metadata: metadata);

  Future<void> logError(String tag, String message,
          {Object? error, StackTrace? stackTrace, Map<String, dynamic>? metadata}) =>
      _writeLog('ERROR', tag, message,
          error: error, stackTrace: stackTrace, metadata: metadata);

  Future<void> _writeLog(
    String level,
    String tag,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? metadata,
  }) async {
    addBreadcrumb('$level/$tag: $message');
    final now = DateTime.now().millisecondsSinceEpoch;
    await _upsert('app_logs', {
      'id': _nextId('log'),
      'ts': now,
      'level': level,
      'tag': tag,
      'message': message,
      'error': error?.toString(),
      'stack_trace': stackTrace?.toString(),
      'metadata_json': metadata == null ? null : jsonEncode(metadata),
    });
    unawaited(_prune('app_logs', 1000, 'ts'));
  }

  Future<List<Map<String, dynamic>>> listLogs({
    String? level,
    int limit = 150,
  }) async {
    return _query(
      'app_logs',
      where: level != null ? 'level = ?' : null,
      whereArgs: level != null ? [level] : null,
      orderBy: 'ts DESC',
      limit: limit,
      memFilter: level != null ? (r) => r['level'] == level : null,
      memSort: (a, b) =>
          ((b['ts'] as num?) ?? 0).compareTo((a['ts'] as num?) ?? 0),
    );
  }

  // ===========================================================================
  // 5. CRASHES, UNHANDLED EXCEPTIONS & HANG REPORTS
  // ===========================================================================

  Future<void> recordCrashOrHang({
    required String kind,
    required String summary,
    StackTrace? stackTrace,
    Map<String, dynamic>? appState,
    bool fatal = false,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _upsert('crash_hang_reports', {
      'id': _nextId('crash'),
      'ts': now,
      'kind': kind,
      'summary': summary,
      'stack_trace': stackTrace?.toString(),
      'breadcrumbs_json': jsonEncode(_breadcrumbs.toList(growable: false)),
      'app_state_json': appState == null ? null : jsonEncode(appState),
      'fatal': fatal ? 1 : 0,
    });
    unawaited(_prune('crash_hang_reports', 200, 'ts'));
  }

  Future<List<Map<String, dynamic>>> listCrashesAndHangs({int limit = 100}) {
    return _query(
      'crash_hang_reports',
      orderBy: 'ts DESC',
      limit: limit,
      memSort: (a, b) =>
          ((b['ts'] as num?) ?? 0).compareTo((a['ts'] as num?) ?? 0),
    );
  }

  // ===========================================================================
  // 6. TELEMETRY EVENTS (UV/IR SENSORS, VISION GATE, FPS)
  // ===========================================================================

  Future<void> recordTelemetry({
    required String channel,
    SpectrumReading? reading,
    bool hazard = false,
    Map<String, dynamic>? metrics,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _upsert('telemetry_events', {
      'id': _nextId('tel'),
      'ts': now,
      'channel': channel,
      'uv_raw': reading?.uvRaw,
      'ir_raw': reading?.irRaw,
      'uv_pct': reading?.uvPercent,
      'ir_pct': reading?.irPercent,
      'hazard': (hazard || (reading?.anyHazard ?? false)) ? 1 : 0,
      'metrics_json': metrics == null ? null : jsonEncode(metrics),
    });
    unawaited(_prune('telemetry_events', 800, 'ts'));
  }

  Future<List<Map<String, dynamic>>> listTelemetry({int limit = 150}) {
    return _query(
      'telemetry_events',
      orderBy: 'ts DESC',
      limit: limit,
      memSort: (a, b) =>
          ((b['ts'] as num?) ?? 0).compareTo((a['ts'] as num?) ?? 0),
    );
  }

  // ===========================================================================
  // 7. PIPELINE TRACES & SPANS
  // ===========================================================================

  String startTraceId([String prefix = 'tr']) => _nextId(prefix);

  Future<T> traceAsync<T>(
    String spanName,
    Future<T> Function() action, {
    String? traceId,
    Map<String, dynamic>? attributes,
  }) async {
    final tid = traceId ?? startTraceId();
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final sw = Stopwatch()..start();
    try {
      final out = await action();
      sw.stop();
      unawaited(recordSpan(
        traceId: tid,
        spanName: spanName,
        startedAtMs: startedAt,
        durationMs: sw.elapsedMilliseconds,
        status: 'ok',
        attributes: attributes,
      ));
      return out;
    } catch (e, st) {
      sw.stop();
      unawaited(recordSpan(
        traceId: tid,
        spanName: spanName,
        startedAtMs: startedAt,
        durationMs: sw.elapsedMilliseconds,
        status: 'error',
        attributes: {
          if (attributes != null) ...attributes,
          'error': e.toString(),
        },
      ));
      unawaited(logError(spanName, 'Span failed: $e',
          error: e, stackTrace: st, metadata: attributes));
      rethrow;
    }
  }

  Future<void> recordSpan({
    required String traceId,
    required String spanName,
    required int startedAtMs,
    required int durationMs,
    required String status,
    Map<String, dynamic>? attributes,
  }) async {
    await _upsert('pipeline_traces', {
      'id': _nextId('span'),
      'trace_id': traceId,
      'span_name': spanName,
      'started_at': startedAtMs,
      'duration_ms': durationMs,
      'status': status,
      'attributes_json': attributes == null ? null : jsonEncode(attributes),
    });
    unawaited(_prune('pipeline_traces', 800, 'started_at'));
  }

  Future<List<Map<String, dynamic>>> listTraces({int limit = 150}) {
    return _query(
      'pipeline_traces',
      orderBy: 'started_at DESC',
      limit: limit,
      memSort: (a, b) => ((b['started_at'] as num?) ?? 0)
          .compareTo((a['started_at'] as num?) ?? 0),
    );
  }

  // ===========================================================================
  // 8. USER DATA & PREFERENCES / NOTES
  // ===========================================================================

  Future<void> putUserData(
    String key,
    Object? value, {
    String category = 'general',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _upsert('user_data', {
      'key': key,
      'category': category,
      'value_json': jsonEncode(value),
      'updated_at': now,
    });
  }

  Future<dynamic> getUserData(String key) async {
    final rows = await _query(
      'user_data',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
      memFilter: (r) => r['key'] == key,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['value_json'] as String?;
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }

  Future<List<Map<String, dynamic>>> listUserData({String? category}) {
    return _query(
      'user_data',
      where: category != null ? 'category = ?' : null,
      whereArgs: category != null ? [category] : null,
      orderBy: 'updated_at DESC',
      memFilter: category != null ? (r) => r['category'] == category : null,
      memSort: (a, b) => ((b['updated_at'] as num?) ?? 0)
          .compareTo((a['updated_at'] as num?) ?? 0),
    );
  }

  // ===========================================================================
  // 9. USER ACTIVITY & AUDIT TRAIL
  // ===========================================================================

  Future<void> recordActivity(
    String action, {
    String? target,
    Map<String, dynamic>? details,
  }) async {
    addBreadcrumb('activity:$action${target != null ? "($target)" : ""}');
    final now = DateTime.now().millisecondsSinceEpoch;
    await _upsert('user_activity', {
      'id': _nextId('act'),
      'ts': now,
      'action': action,
      'target': target,
      'details_json': details == null ? null : jsonEncode(details),
    });
    unawaited(_prune('user_activity', 600, 'ts'));
  }

  Future<List<Map<String, dynamic>>> listActivities({int limit = 150}) {
    return _query(
      'user_activity',
      orderBy: 'ts DESC',
      limit: limit,
      memSort: (a, b) =>
          ((b['ts'] as num?) ?? 0).compareTo((a['ts'] as num?) ?? 0),
    );
  }

  // ===========================================================================
  // STATS & DIAGNOSTIC EXPORT
  // ===========================================================================

  Future<Map<String, dynamic>> getStats() async {
    if (!_initialized) await init();
    if (_useNativeSqlite) {
      final stats = await _channel.invokeMapMethod<String, dynamic>('stats');
      if (stats != null) return stats;
    }
    final sizeBytes = await _fileStore.sizeBytes(_fallbackFile);
    return {
      'backend': kIsWeb ? 'memory_json' : 'file_json',
      'path': _dbPath,
      'sizeBytes': sizeBytes,
      'counts': {
        for (final t in allTables) t: _memTables[t]!.length,
      },
    };
  }

  Future<String> exportDiagnosticsJson() async {
    final stats = await getStats();
    final logs = await listLogs(limit: 50);
    final crashes = await listCrashesAndHangs(limit: 30);
    final traces = await listTraces(limit: 50);
    final telemetry = await listTelemetry(limit: 40);
    final activities = await listActivities(limit: 50);
    return const JsonEncoder.withIndent('  ').convert({
      'exportedAt': DateTime.now().toIso8601String(),
      'stats': stats,
      'recentCrashesAndHangs': crashes,
      'recentLogs': logs,
      'recentTraces': traces,
      'recentTelemetry': telemetry,
      'recentActivity': activities,
    });
  }

  // ===========================================================================
  // SERIALIZATION HELPERS
  // ===========================================================================

  static Map<String, dynamic> _moondreamToJson(MoondreamStructuredAnalysis m) =>
      {
        'caption': m.caption,
        'whatItIs': m.whatItIs,
        'howItsUsed': m.howItsUsed,
        'whatsAround': m.whatsAround,
        'visibleText': m.visibleText,
        'hazards': m.hazards,
        'stateOfMatter': m.stateOfMatter,
        'reasoning': m.reasoning,
        'requestId': m.requestId,
      };

  static MoondreamStructuredAnalysis _moondreamFromJson(
      Map<String, dynamic> j) {
    return MoondreamStructuredAnalysis(
      caption: (j['caption'] as String?) ?? '',
      whatItIs: (j['whatItIs'] as String?) ?? '',
      howItsUsed: (j['howItsUsed'] as String?) ?? '',
      whatsAround: (j['whatsAround'] as String?) ?? '',
      visibleText: (j['visibleText'] as String?) ?? '',
      hazards: (j['hazards'] as String?) ?? '',
      stateOfMatter: (j['stateOfMatter'] as String?) ?? '',
      reasoning: j['reasoning'] as String?,
      requestId: j['requestId'] as String?,
    );
  }

  static Map<String, dynamic> _citationToJson(Citation c) => {
        'index': c.index,
        'title': c.title,
        'url': c.url,
        'snippet': c.snippet,
        'thumbnailUrl': c.thumbnailUrl,
        'type': c.type.name,
      };

  static Citation _citationFromJson(Map<String, dynamic> j) {
    final typeName = (j['type'] as String?) ?? 'bundledDoc';
    final type = CitationType.values.firstWhere(
      (t) => t.name == typeName,
      orElse: () => CitationType.bundledDoc,
    );
    return Citation(
      index: (j['index'] as num?)?.toInt() ?? 1,
      title: (j['title'] as String?) ?? '',
      url: (j['url'] as String?) ?? '',
      snippet: (j['snippet'] as String?) ?? '',
      thumbnailUrl: j['thumbnailUrl'] as String?,
      type: type,
    );
  }

  static SavedChatSummary _rowToSessionSummary(Map<String, dynamic> r) {
    Map<String, dynamic> parseObj(dynamic raw) {
      if (raw is String && raw.isNotEmpty) {
        try {
          return jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {}
      }
      return const {};
    }

    final boxMap = parseObj(r['selected_box_json']);
    final mdMap = parseObj(r['moondream_json']);
    final ctxMap = parseObj(r['running_context_json']);

    return SavedChatSummary(
      id: (r['id'] as String?) ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (r['created_at'] as num?)?.toInt() ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (r['updated_at'] as num?)?.toInt() ?? 0,
      ),
      title: (r['title'] as String?) ?? 'Object Analysis',
      selectedLabel: (r['selected_label'] as String?) ?? 'object',
      selectedConfidence:
          (r['selected_confidence'] as num?)?.toDouble() ?? 1.0,
      selectedBox: boxMap.isNotEmpty
          ? BoundingBox.fromJson(boxMap)
          : BoundingBox(
              x: 0.2,
              y: 0.2,
              w: 0.6,
              h: 0.6,
              label: (r['selected_label'] as String?) ?? 'object',
              confidence:
                  (r['selected_confidence'] as num?)?.toDouble() ?? 1.0,
            ),
      cleanJpegPath: r['clean_jpeg_path'] as String?,
      boxedJpegPath: r['boxed_jpeg_path'] as String?,
      moondreamAnalysis: _moondreamFromJson(mdMap),
      firstLlmContext: (r['first_llm_context'] as String?) ?? '',
      runningContext: ConversationContext.fromJson(ctxMap),
      locale: (r['locale'] as String?) ?? 'en',
      messageCount: (r['message_count'] as num?)?.toInt() ?? 0,
    );
  }

  static ChatMessage _rowToChatMessage(Map<String, dynamic> r) {
    var citations = const <Citation>[];
    final rawCits = r['citations_json'];
    if (rawCits is String && rawCits.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawCits) as List;
        citations = decoded
            .whereType<Map<String, dynamic>>()
            .map(_citationFromJson)
            .toList(growable: false);
      } catch (_) {}
    }
    return ChatMessage(
      role: (r['role'] as String?) ?? 'assistant',
      content: (r['content'] as String?) ?? '',
      at: DateTime.fromMillisecondsSinceEpoch(
        (r['created_at'] as num?)?.toInt() ?? 0,
      ),
      citations: citations,
      verifiedCount: (r['verified_count'] as num?)?.toInt() ?? 0,
      unverifiedCount: (r['unverified_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Lightweight event-loop stall / UI-hang watchdog.
///
/// Periodically schedules a timer tick and measures wall-clock drift; if the
/// main isolate stalls beyond [stallThreshold] (while not merely backgrounded),
/// records a `ui_hang` diagnostic entry into [InternalDatabaseService].
class HangWatchdog {
  HangWatchdog._();
  static final HangWatchdog instance = HangWatchdog._();

  static const Duration _interval = Duration(seconds: 1);
  static const Duration stallThreshold = Duration(milliseconds: 2800);
  static const Duration _sleepIgnoreThreshold = Duration(seconds: 20);

  Timer? _timer;
  DateTime? _lastTick;

  void start() {
    _timer?.cancel();
    _lastTick = DateTime.now();
    _timer = Timer.periodic(_interval, (_) {
      final now = DateTime.now();
      final prev = _lastTick;
      _lastTick = now;
      if (prev == null) return;
      final delta = now.difference(prev);
      // Ignore long OS suspend/sleep intervals (>20s), catch real 2.8s..20s UI stalls.
      if (delta >= stallThreshold && delta < _sleepIgnoreThreshold) {
        unawaited(
          InternalDatabaseService.instance.recordCrashOrHang(
            kind: 'ui_hang',
            summary:
                'Main isolate event-loop stall detected (${delta.inMilliseconds} ms)',
            appState: {'stallMs': delta.inMilliseconds},
            fatal: false,
          ),
        );
      }
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
