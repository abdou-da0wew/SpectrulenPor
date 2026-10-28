package com.spectraglass.app

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Native Android SQLite WAL database channel (`com.spectraglass/db`).
 *
 * Uses Android's built-in `android.database.sqlite.SQLiteOpenHelper` (zero external
 * Gradle/pub plugins required) to persist:
 *   1. `chat_sessions`      — anchored object analyses & running ConversationContext
 *   2. `chat_messages`      — full chat turn history with inline citations & verdicts
 *   3. `response_cache`     — TTL cache for Wikipedia, PubChem, WebSearch, Docs & AI responses
 *   4. `app_logs`           — structured DEBUG/INFO/WARN/ERROR logs + stack traces
 *   5. `crash_hang_reports` — uncaught Flutter/platform errors + UI hang watchdog events
 *   6. `telemetry_events`   — BLE UV/IR spectrum telemetry, VisionGate & FPS metrics
 *   7. `pipeline_traces`    — millisecond execution spans across YOLO/Moondream/LLM/TTS
 *   8. `user_data`          — persistent user notes, preferences & profile key-values
 *   9. `user_activity`      — chronological user activity & audit history
 */
object AppDatabaseChannel {
    private const val TAG = "AppDbChannel"
    private const val CHANNEL = "com.spectraglass/db"
    private const val DB_NAME = "spectrulenpor_internal.db"
    private const val DB_VERSION = 1

    private val ALLOWED_TABLES = setOf(
        "chat_sessions",
        "chat_messages",
        "response_cache",
        "app_logs",
        "crash_hang_reports",
        "telemetry_events",
        "pipeline_traces",
        "user_data",
        "user_activity"
    )

    @Volatile private var helper: DbHelper? = null
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(flutterEngine: FlutterEngine, context: Context) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handle(call, result, context) }
    }

    private fun getDb(context: Context): SQLiteDatabase {
        val h = helper ?: synchronized(this) {
            helper ?: DbHelper(context.applicationContext).also { helper = it }
        }
        return h.writableDatabase
    }

    private fun postSuccess(result: MethodChannel.Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    private fun postError(result: MethodChannel.Result, code: String, message: String?) {
        mainHandler.post { result.error(code, message, null) }
    }

    private fun validateTable(table: String?): String {
        if (table == null || table !in ALLOWED_TABLES) {
            throw IllegalArgumentException("Disallowed table: $table")
        }
        return table
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result, context: Context) {
        executor.execute {
            try {
                val db = getDb(context)
                when (call.method) {
                    "init" -> {
                        postSuccess(
                            result,
                            mapOf(
                                "backend" to "android_sqlite_wal",
                                "path" to db.path,
                                "version" to db.version
                            )
                        )
                    }
                    "upsert" -> {
                        val table = validateTable(call.argument<String>("table"))
                        val valuesMap = call.argument<Map<String, Any?>>("values")
                            ?: throw IllegalArgumentException("values required")
                        val cv = mapToContentValues(valuesMap)
                        val rowId = db.insertWithOnConflict(
                            table,
                            null,
                            cv,
                            SQLiteDatabase.CONFLICT_REPLACE
                        )
                        postSuccess(result, rowId)
                    }
                    "query" -> {
                        val table = validateTable(call.argument<String>("table"))
                        val where = call.argument<String>("where")
                        val whereArgs = call.argument<List<String>>("whereArgs")?.toTypedArray()
                        val orderBy = call.argument<String>("orderBy")
                        val limit = call.argument<Int>("limit")?.toString()
                        val rows = ArrayList<Map<String, Any?>>()
                        db.query(
                            table,
                            null,
                            where,
                            whereArgs,
                            null,
                            null,
                            orderBy,
                            limit
                        ).use { cursor ->
                            while (cursor.moveToNext()) {
                                rows.add(cursorRowToMap(cursor))
                            }
                        }
                        postSuccess(result, rows)
                    }
                    "delete" -> {
                        val table = validateTable(call.argument<String>("table"))
                        val where = call.argument<String>("where")
                        val whereArgs = call.argument<List<String>>("whereArgs")?.toTypedArray()
                        val deleted = db.delete(table, where, whereArgs)
                        postSuccess(result, deleted)
                    }
                    "pruneTable" -> {
                        val table = validateTable(call.argument<String>("table"))
                        val maxRows = call.argument<Int>("maxRows") ?: 1000
                        val orderCol = call.argument<String>("orderCol") ?: "ts"
                        if (!orderCol.matches(Regex("^[a-zA-Z0-9_]+$"))) {
                            throw IllegalArgumentException("Invalid column: $orderCol")
                        }
                        db.execSQL(
                            """
                            DELETE FROM $table
                            WHERE rowid NOT IN (
                                SELECT rowid FROM $table ORDER BY $orderCol DESC LIMIT ?
                            )
                            """.trimIndent(),
                            arrayOf(maxRows)
                        )
                        postSuccess(result, true)
                    }
                    "stats" -> {
                        val counts = HashMap<String, Int>()
                        for (t in ALLOWED_TABLES) {
                            db.rawQuery("SELECT COUNT(*) FROM $t", null).use { c ->
                                counts[t] = if (c.moveToFirst()) c.getInt(0) else 0
                            }
                        }
                        val dbFile = context.getDatabasePath(DB_NAME)
                        postSuccess(
                            result,
                            mapOf(
                                "backend" to "android_sqlite_wal",
                                "path" to dbFile.absolutePath,
                                "sizeBytes" to (if (dbFile.exists()) dbFile.length() else 0L),
                                "counts" to counts
                            )
                        )
                    }
                    else -> mainHandler.post { result.notImplemented() }
                }
            } catch (t: Throwable) {
                Log.e(TAG, "DB operation '${call.method}' failed", t)
                postError(result, "DB_ERROR", t.message)
            }
        }
    }

    private fun mapToContentValues(map: Map<String, Any?>): ContentValues {
        val cv = ContentValues()
        for ((k, v) in map) {
            when (v) {
                null -> cv.putNull(k)
                is String -> cv.put(k, v)
                is Int -> cv.put(k, v)
                is Long -> cv.put(k, v)
                is Double -> cv.put(k, v)
                is Float -> cv.put(k, v)
                is Boolean -> cv.put(k, if (v) 1 else 0)
                is ByteArray -> cv.put(k, v)
                else -> cv.put(k, v.toString())
            }
        }
        return cv
    }

    private fun cursorRowToMap(cursor: Cursor): Map<String, Any?> {
        val row = HashMap<String, Any?>(cursor.columnCount)
        for (i in 0 until cursor.columnCount) {
            val name = cursor.getColumnName(i)
            val value: Any? = when (cursor.getType(i)) {
                Cursor.FIELD_TYPE_NULL -> null
                Cursor.FIELD_TYPE_INTEGER -> cursor.getLong(i)
                Cursor.FIELD_TYPE_FLOAT -> cursor.getDouble(i)
                Cursor.FIELD_TYPE_STRING -> cursor.getString(i)
                Cursor.FIELD_TYPE_BLOB -> cursor.getBlob(i)
                else -> cursor.getString(i)
            }
            row[name] = value
        }
        return row
    }

    private class DbHelper(context: Context) :
        SQLiteOpenHelper(context, DB_NAME, null, DB_VERSION) {

        override fun onConfigure(db: SQLiteDatabase) {
            super.onConfigure(db)
            db.enableWriteAheadLogging()
            db.setForeignKeyConstraintsEnabled(true)
        }

        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS chat_sessions (
                    id TEXT PRIMARY KEY,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    selected_label TEXT NOT NULL,
                    selected_confidence REAL NOT NULL DEFAULT 1.0,
                    selected_box_json TEXT NOT NULL,
                    clean_jpeg_path TEXT,
                    boxed_jpeg_path TEXT,
                    moondream_json TEXT NOT NULL,
                    first_llm_context TEXT NOT NULL,
                    running_context_json TEXT NOT NULL,
                    locale TEXT NOT NULL DEFAULT 'en',
                    message_count INTEGER NOT NULL DEFAULT 0
                )
                """.trimIndent()
            )
            db.execSQL("CREATE INDEX IF NOT EXISTS idx_sessions_updated ON chat_sessions(updated_at DESC)")

            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS chat_messages (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    seq INTEGER NOT NULL,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    citations_json TEXT NOT NULL DEFAULT '[]',
                    verified_count INTEGER NOT NULL DEFAULT 0,
                    unverified_count INTEGER NOT NULL DEFAULT 0,
                    model_used TEXT,
                    latency_ms INTEGER,
                    created_at INTEGER NOT NULL,
                    FOREIGN KEY(session_id) REFERENCES chat_sessions(id) ON DELETE CASCADE
                )
                """.trimIndent()
            )
            db.execSQL("CREATE INDEX IF NOT EXISTS idx_messages_session ON chat_messages(session_id, seq ASC)")

            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS response_cache (
                    cache_key TEXT PRIMARY KEY,
                    namespace TEXT NOT NULL,
                    query TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    expires_at INTEGER NOT NULL,
                    hit_count INTEGER NOT NULL DEFAULT 0
                )
                """.trimIndent()
            )
            db.execSQL("CREATE INDEX IF NOT EXISTS idx_cache_expires ON response_cache(expires_at ASC)")
            db.execSQL("CREATE INDEX IF NOT EXISTS idx_cache_ns ON response_cache(namespace)")

            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS app_logs (
                    id TEXT PRIMARY KEY,
                    ts INTEGER NOT NULL,
                    level TEXT NOT NULL,
                    tag TEXT NOT NULL,
                    message TEXT NOT NULL,
                    error TEXT,
                    stack_trace TEXT,
                    metadata_json TEXT
                )
                """.trimIndent()
            )
            db.execSQL("CREATE INDEX IF NOT EXISTS idx_logs_ts ON app_logs(ts DESC)")
            db.execSQL("CREATE INDEX IF NOT EXISTS idx_logs_level ON app_logs(level, ts DESC)")

            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS crash_hang_reports (
                    id TEXT PRIMARY KEY,
                    ts INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    stack_trace TEXT,
                    breadcrumbs_json TEXT,
                    app_state_json TEXT,
                    fatal INTEGER NOT NULL DEFAULT 0
                )
                """.trimIndent()
            )
            db.execSQL("CREATE INDEX IF NOT EXISTS idx_crashes_ts ON crash_hang_reports(ts DESC)")

            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS telemetry_events (
                    id TEXT PRIMARY KEY,
                    ts INTEGER NOT NULL,
                    channel TEXT NOT NULL,
                    uv_raw INTEGER,
                    ir_raw INTEGER,
                    uv_pct REAL,
                    ir_pct REAL,
                    hazard INTEGER NOT NULL DEFAULT 0,
                    metrics_json TEXT
                )
                """.trimIndent()
            )
            db.execSQL("CREATE INDEX IF NOT EXISTS idx_telemetry_ts ON telemetry_events(ts DESC)")

            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS pipeline_traces (
                    id TEXT PRIMARY KEY,
                    trace_id TEXT NOT NULL,
                    span_name TEXT NOT NULL,
                    started_at INTEGER NOT NULL,
                    duration_ms INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    attributes_json TEXT
                )
                """.trimIndent()
            )
            db.execSQL("CREATE INDEX IF NOT EXISTS idx_traces_ts ON pipeline_traces(started_at DESC)")
            db.execSQL("CREATE INDEX IF NOT EXISTS idx_traces_id ON pipeline_traces(trace_id)")

            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS user_data (
                    key TEXT PRIMARY KEY,
                    category TEXT NOT NULL,
                    value_json TEXT NOT NULL,
                    updated_at INTEGER NOT NULL
                )
                """.trimIndent()
            )
            db.execSQL("CREATE INDEX IF NOT EXISTS idx_userdata_cat ON user_data(category)")

            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS user_activity (
                    id TEXT PRIMARY KEY,
                    ts INTEGER NOT NULL,
                    action TEXT NOT NULL,
                    target TEXT,
                    details_json TEXT
                )
                """.trimIndent()
            )
            db.execSQL("CREATE INDEX IF NOT EXISTS idx_activity_ts ON user_activity(ts DESC)")
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            onCreate(db)
        }
    }
}
