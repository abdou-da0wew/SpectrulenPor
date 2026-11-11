#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_sleep.h"

#include "config.h"
#include "camera.h"
#include "sensors.h"
#include "flashlight.h"
#include "ble.h"
#include "wifi.h"
#include "udp_stream.h"

static const char *TAG = "MAIN";

/* -----------------------------------------------------------------------
 *  WiFi config response: send current SSID over BLE TX
 * --------------------------------------------------------------------- */
static void send_wifi_config_get_response(void)
{
    char buf[96];
    int n = snprintf(buf, sizeof(buf), "$WIFI_CFG:ssid=%.31s\n", g_wifi_ssid);
    if (n > 0) ble_send_text(buf);
}

/* -----------------------------------------------------------------------
 *  Connection status response over BLE TX
 * --------------------------------------------------------------------- */
static void send_connection_status_response(void)
{
    char ip_str[32];
    wifi_local_ip_str(ip_str, sizeof(ip_str));

    char buf[128];
    int n = snprintf(buf, sizeof(buf),
        "$STATUS:bt=%d,wifi=%s,ip=%s,flash=%d,stream=%d\n",
        g_client_connected ? 1 : 0,
        wifi_status_string(),
        ip_str,
        g_flash_on ? 1 : 0,
        g_streaming ? 1 : 0);
    if (n > 0) ble_send_text(buf);
}

/* -----------------------------------------------------------------------
 *  Telemetry task: UV/IR @2Hz, WiFi status @2s, over BLE
 * --------------------------------------------------------------------- */
static void telemetry_task(void *pv)
{
    TickType_t xLastWake = xTaskGetTickCount();
    uint32_t last_status_ms = 0;

    while (1) {
        vTaskDelayUntil(&xLastWake, pdMS_TO_TICKS(TELEMETRY_INTERVAL_MS));

        /* UV/IR telemetry @ 2 Hz over BLE. */
        if (g_client_connected) {
            as7265x_reading_t r;
            if (sensors_read_uv_ir(&r) == ESP_OK) {
                char pkt[64];
                int n = snprintf(pkt, sizeof(pkt),
                                 "$UV:%u;IR:%u\n", r.uv_raw, r.ir_raw);
                if (n > 0) ble_send_bytes((const uint8_t *)pkt, (size_t)n);
            }
        }

        /* WiFi status @ 2s over BLE. */
        uint32_t now = xTaskGetTickCount() * portTICK_PERIOD_MS;
        if (g_client_connected && now - last_status_ms >= STATUS_INTERVAL_MS) {
            last_status_ms = now;
            if (g_wifi_config_get) {
                g_wifi_config_get = false;
                send_wifi_config_get_response();
            }
            if (g_connection_status_get) {
                g_connection_status_get = false;
                send_connection_status_response();
            }
        }
    }
}

/* -----------------------------------------------------------------------
 *  Main task: camera capture + UDP video streaming
 * --------------------------------------------------------------------- */
static void main_task(void *pv)
{
    TickType_t xLastWake = xTaskGetTickCount();
    bool wifi_configured = false;
    bool wifi_connected_once = false;
    bool udp_started = false;

    ESP_LOGI(TAG, "Main task started");

    while (1) {
        /* --- Handle pending restart --- */
        if (g_restart_requested) {
            ESP_LOGI(TAG, "Restart requested — rebooting");
            vTaskDelay(pdMS_TO_TICKS(100));
            esp_restart();
        }

        /* --- Handle pending shutdown --- */
        if (g_shutdown_requested) {
            ESP_LOGI(TAG, "Shutdown requested — stopping everything");
            g_shutdown_requested = false;
            g_streaming = false;
            flashlight_set(false);
            wifi_stop_station();
            udp_stream_stop();
            ble_send_text("$CMD:shutdown_complete\n");
            continue;
        }

        /* --- Handle pending WiFi config --- */
        if (g_wifi_config_pending && !wifi_configured) {
            g_wifi_config_pending = false;
            wifi_configured = true;
            ESP_LOGI(TAG, "WiFi config pending — connecting to %.31s",
                     g_wifi_ssid);
            ble_send_text("$CMD:wifi_connecting\n");
            wifi_start_station();
            wifi_connected_once = false;
            udp_started = false;
        }

        /* --- Maintain WiFi connection --- */
        if (wifi_configured) {
            wifi_maintain();

            if (wifi_is_connected() && !wifi_connected_once) {
                wifi_connected_once = true;
                ESP_LOGI(TAG, "WiFi connected — starting UDP video");
                udp_stream_start();
                udp_started = true;
                ble_send_text("$WIFI:connected\n");
            } else if (!wifi_is_connected() && wifi_connected_once) {
                wifi_connected_once = false;
                udp_stream_stop();
                udp_started = false;
                ble_send_text("$WIFI:disconnected\n");
            }
        }

        /* --- UDP video streaming --- */
        if (g_streaming && wifi_is_connected() && udp_started) {
            camera_fb_t *fb = camera_capture();
            if (fb != NULL) {
                udp_stream_send_frame(fb->buf, fb->len);
                camera_release(fb);
            }
        }

        /* Poll UDP rx for app control datagrams. */
        udp_stream_poll();

        /* Frame rate throttle: STREAM_INTERVAL_MS (~10 fps SVGA). */
        vTaskDelayUntil(&xLastWake, pdMS_TO_TICKS(STREAM_INTERVAL_MS));
    }
}

/* -----------------------------------------------------------------------
 *  app_main
 * --------------------------------------------------------------------- */
void app_main(void)
{
    ESP_LOGI(TAG, "SpectruLenPor firmware v3.0 (ESP-IDF)");
    ESP_LOGI(TAG, "Camera: OV2640 SVGA(800x600) quality %d", CAM_JPEG_QUALITY);
    ESP_LOGI(TAG, "Sensors: AS7265x UV+IR on I2C1 (GPIO13/14)");
    ESP_LOGI(TAG, "Flash: GPIO4");
    ESP_LOGI(TAG, "BLE: %s (telemetry + commands + WiFi config)", BLE_DEV_NAME);
    ESP_LOGI(TAG, "WiFi/UDP video: port %d", UDP_VIDEO_PORT);

    /* Initialize hardware. */
    flashlight_init();
    sensors_init();
    camera_init();

    /* Initialize BLE (advertises immediately). */
    ble_init();

    /* Start tasks. */
    xTaskCreate(telemetry_task, "telemetry", 3072, NULL, 6, NULL);
    xTaskCreate(main_task, "main", 4096, NULL, 5, NULL);

    ESP_LOGI(TAG, "Tasks started — waiting for BLE client...");
}
