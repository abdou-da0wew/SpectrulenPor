package com.spectraglass.app

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.Debug
import android.os.PowerManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Small, low-overhead runtime snapshot used by the in-app benchmark report.
 * Perfetto/AndroidX Macrobenchmark remain the source of frame/startup metrics.
 */
object BenchmarkMetricsChannel {
    private const val CHANNEL = "spectrulenpor/benchmark/metrics"

    fun register(engine: FlutterEngine, context: Context) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "snapshot" -> {
                        try {
                            result.success(snapshot(context.applicationContext))
                        } catch (error: Throwable) {
                            result.error(
                                "BENCHMARK_SNAPSHOT_FAILED",
                                error.message ?: "Unable to collect runtime metrics.",
                                null
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun snapshot(context: Context): Map<String, Any?> {
        val activityManager =
            context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val memory = ActivityManager.MemoryInfo()
        activityManager.getMemoryInfo(memory)

        val processMemory = Debug.MemoryInfo()
        Debug.getMemoryInfo(processMemory)

        val runtime = Runtime.getRuntime()
        val usedHeap = runtime.totalMemory() - runtime.freeMemory()

        val powerManager =
            context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val thermalStatus = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            powerManager.currentThermalStatus
        } else {
            -1
        }

        val batteryIntent = context.registerReceiver(
            null,
            IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        )
        val batteryLevel = batteryIntent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val batteryScale = batteryIntent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val batteryPercent = if (batteryLevel >= 0 && batteryScale > 0) {
            batteryLevel * 100.0 / batteryScale
        } else {
            null
        }

        return mapOf(
            "manufacturer" to Build.MANUFACTURER,
            "deviceModel" to Build.MODEL,
            "device" to Build.DEVICE,
            "sdkInt" to Build.VERSION.SDK_INT,
            "release" to Build.VERSION.RELEASE,
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "cpuCores" to Runtime.getRuntime().availableProcessors(),
            "totalRamBytes" to memory.totalMem,
            "availableRamBytes" to memory.availMem,
            "lowMemory" to memory.lowMemory,
            "appPssKb" to processMemory.totalPss,
            "appPrivateDirtyKb" to processMemory.totalPrivateDirty,
            "javaHeapUsedBytes" to usedHeap,
            "javaHeapMaxBytes" to runtime.maxMemory(),
            "thermalStatus" to thermalStatus,
            "batteryPercent" to batteryPercent
        )
    }
}
