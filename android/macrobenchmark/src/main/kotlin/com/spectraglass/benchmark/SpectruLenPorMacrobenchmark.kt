package com.spectraglass.benchmark

import androidx.benchmark.macro.FrameTimingMetric
import androidx.benchmark.macro.MacrobenchmarkRule
import androidx.benchmark.macro.MemoryUsageMetric
import androidx.benchmark.macro.StartupMode
import androidx.benchmark.macro.StartupTimingMetric
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Device-level performance suite for the real, non-debuggable benchmark app.
 * AndroidX writes iteration metrics and Perfetto traces to the connected-test
 * results. Use a physical device for useful camera/GPU/thermal measurements.
 */
@RunWith(AndroidJUnit4::class)
class SpectruLenPorMacrobenchmark {
    @get:Rule
    val benchmarkRule = MacrobenchmarkRule()

    private val targetPackage = "com.spectraglass.app.benchmark"

    @Test
    fun coldStartupTimingAndMemory() {
        benchmarkRule.measureRepeated(
            packageName = targetPackage,
            metrics = listOf(StartupTimingMetric(), MemoryUsageMetric()),
            iterations = 8,
            startupMode = StartupMode.COLD,
            setupBlock = {
                pressHome()
            },
            measureBlock = {
                startActivityAndWait()
            }
        )
    }

    @Test
    fun warmStartupTimingAndMemory() {
        benchmarkRule.measureRepeated(
            packageName = targetPackage,
            metrics = listOf(StartupTimingMetric(), MemoryUsageMetric()),
            iterations = 10,
            startupMode = StartupMode.WARM,
            setupBlock = {
                pressHome()
            },
            measureBlock = {
                startActivityAndWait()
            }
        )
    }

    @Test
    fun homeGestureFrameTimingAndMemory() {
        benchmarkRule.measureRepeated(
            packageName = targetPackage,
            metrics = listOf(FrameTimingMetric(), MemoryUsageMetric()),
            iterations = 8,
            startupMode = StartupMode.WARM,
            setupBlock = {
                pressHome()
            },
            measureBlock = {
                startActivityAndWait()
                device.waitForIdle()

                // Repeat a deterministic gesture sequence. The frame metric
                // captures frame duration, missed frames and frame overrun.
                repeat(4) {
                    val centerX = device.displayWidth / 2
                    val startY = (device.displayHeight * 0.78f).toInt()
                    val endY = (device.displayHeight * 0.30f).toInt()
                    device.swipe(centerX, startY, centerX, endY, 18)
                    device.waitForIdle()
                }
            }
        )
    }
}
