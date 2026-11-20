package com.spectraglass.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Glanceable SpectruLenPor status widget.
 *
 * The two actions open the app through HomeWidget's launch intent so Flutter
 * can receive the requested action through HomeWidget.widgetClicked.
 */
class SpectruLenPorWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: android.content.SharedPreferences
    ) {
        appWidgetIds.forEach { widgetId ->
            val views = RemoteViews(
                context.packageName,
                R.layout.spectrulenpor_widget
            ).apply {
                val status = widgetData.getString("widget_status", "Ready") ?: "Ready"
                val model = widgetData.getString("widget_model", "OpenRouter free models")
                    ?: "OpenRouter free models"
                setTextViewText(R.id.widget_status, status.take(100))
                setTextViewText(R.id.widget_model, model.take(72))

                val openIntent = widgetIntent(
                    context,
                    "spectrulenpor://widget/open?homeWidget"
                )
                val captureIntent = widgetIntent(
                    context,
                    "spectrulenpor://widget/capture?homeWidget"
                )
                setOnClickPendingIntent(
                    R.id.widget_open,
                    PendingIntent.getActivity(
                        context,
                        widgetId * 2,
                        openIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    )
                )
                setOnClickPendingIntent(
                    R.id.widget_capture,
                    PendingIntent.getActivity(
                        context,
                        widgetId * 2 + 1,
                        captureIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    )
                )
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    private fun widgetIntent(context: Context, uri: String): Intent {
        return Intent(context, MainActivity::class.java).apply {
            action = "es.antonborri.home_widget.action.LAUNCH"
            data = Uri.parse(uri)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
    }
}
