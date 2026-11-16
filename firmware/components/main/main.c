#include <stdio.h>
#include <string.h>
#include <inttypes.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_mac.h"
#include "esp_event.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"
#include "nvs_flash.h"
#include "nvs.h"

#include "config.h"
#include "camera.h"
#include "sensors.h"
#include "flashlight.h"
#include "ble.h"
#include "wifi.h"
#include "udp_stream.h"

static const char *TAG = "MAIN";

typedef struct {
    bool streaming;
    unsigned pending_frames;
    bool standby;
    bool wifi_started;
    bool wifi_was_connected;
    bool ble_started;
    bool ble_notify_enabled;
    uint32_t ble_session;
    uint32_t frames_sent;
    uint32_t frame_errors;
    int64_t next_frame;
    firmware_wifi_credentials_t credentials;
} app_state_t;

/* Only the application task owns this state, GPIO, camera, and UDP socket. */
static app_state_t s_app;

static void send_error(uint32_t session, const char *code)
{
    ESP_LOGE(TAG, "operation=command.error code=%s", code);
    char text[TELEMETRY_TEXT_CAPACITY];
    int n = snprintf(text, sizeof(text), "$ERROR:%s\n", code);
    if (n > 0 && (size_t)n < sizeof(text)) {
        ble_send_bytes_for_session(session, (const uint8_t *)text, (size_t)n);
    }
}

static void send_wifi_config_get_response(uint32_t session)
{
    char buf[STATUS_TEXT_CAPACITY];
    int n = snprintf(buf, sizeof(buf), "$WIFI_CFG:ssid=%s\n", s_app.credentials.ssid);
    if (n > 0 && (size_t)n < sizeof(buf)) {
        ble_send_bytes_for_session(session, (const uint8_t *)buf, (size_t)n);
    }
}

static void send_connection_status_response(uint32_t session)
{
    char ip_str[IPV4_TEXT_CAPACITY];
    wifi_local_ip_str(ip_str, sizeof(ip_str));

    char buf[STATUS_TEXT_CAPACITY];
    int n = snprintf(buf, sizeof(buf),
        "$STATUS:bt=%d,wifi=%s,ip=%s,flash=%d,stream=%d,camera=%d,sensor=%d,"
        "psram=%zu,frames=%" PRIu32 ",errors=%" PRIu32 ",notify_errors=%" PRIu32
        ",heap=%zu,min_heap=%zu,standby=%d\n",
        ble_is_connected(), wifi_status_string(), ip_str, flashlight_is_on(),
        s_app.streaming, camera_is_ready(), sensors_available(), camera_psram_bytes(),
        s_app.frames_sent, s_app.frame_errors, ble_notification_errors(),
        heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT),
        heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT),
        s_app.standby);
    if (n > 0 && (size_t)n < sizeof(buf)) {
        ble_send_bytes_for_session(session, (const uint8_t *)buf, (size_t)n);
        ESP_LOGI(TAG, "operation=status.snapshot %.*s", n - 1, buf);
    }
}

static void reconcile_ble_session(uint32_t session)
{
    if (!s_app.ble_started || session == s_app.ble_session) {
        return;
    }
    s_app.ble_session = session;
    s_app.streaming = false;
    s_app.pending_frames = 0;
    s_app.ble_notify_enabled = false;
    udp_stream_stop();
    if (flashlight_is_on()) {
        flashlight_set(false);
    }
}

static void handle_command(const firmware_command_t *command, bool from_ble,
                           uint32_t session)
{
    if (from_ble) {
        if (ble_session_is_current(session)) {
            reconcile_ble_session(session);
        }
        /* Reconciliation can call GPIO/socket code. Validate again immediately
         * before execution, without holding any lock through side effects. */
        if (!ble_session_is_current(session)) {
            ESP_LOGW(TAG, "operation=command.reject session=%" PRIu32
                     " command=0x%02x code=BLE_SESSION_CLOSED", session, command->code);
            return;
        }
    }
    int64_t started = esp_timer_get_time();
    esp_err_t err = ESP_OK;
    switch (command->code) {
    case CMD_STREAM_ON:
        if (!camera_is_ready()) {
            send_error(session, "CAMERA_UNAVAILABLE");
            err = ESP_ERR_INVALID_STATE;
            break;
        }
        if (s_app.standby && !s_app.ble_started &&
            protocol_wifi_credentials_valid(&s_app.credentials)) {
            err = wifi_start_station(&s_app.credentials);
        }
        s_app.standby = false;
        s_app.streaming = true;
        s_app.next_frame = 0;
        ble_send_text_for_session(session, "$CMD:stream_on\n");
        break;
    case CMD_STREAM_OFF:
        s_app.streaming = false;
        s_app.pending_frames = 0;
        ble_send_text_for_session(session, "$CMD:stream_off\n");
        break;
    case CMD_SINGLE_FRAME:
        if (camera_is_ready() && s_app.pending_frames < BLE_COMMAND_QUEUE_LENGTH) {
            ++s_app.pending_frames;
            ble_send_text_for_session(session, "$CMD:single_frame\n");
        } else {
            send_error(session, camera_is_ready() ? "FRAME_QUEUE_FULL" : "CAMERA_UNAVAILABLE");
            err = ESP_ERR_INVALID_STATE;
        }
        break;
    case CMD_FLASH_ON:
    case CMD_FLASH_OFF:
        err = flashlight_set(command->code == CMD_FLASH_ON);
        if (err == ESP_OK) {
            ble_send_text_for_session(session, command->code == CMD_FLASH_ON
                ? "$CMD:flash_on\n" : "$CMD:flash_off\n");
        } else {
            send_error(session, "FLASH_GPIO_FAILED");
        }
        break;
    case CMD_RESTART:
        ble_send_text_for_session(session, "$CMD:restart\n");
        flashlight_set(false);
        vTaskDelay(pdMS_TO_TICKS(RESTART_ACK_DELAY_MS));
        esp_restart();
        break;
    case CMD_SHUTDOWN:
        s_app.streaming = false;
        s_app.pending_frames = 0;
        s_app.standby = true;
        flashlight_set(false);
        udp_stream_stop();
        s_app.wifi_started = false;
        s_app.wifi_was_connected = false;
        err = wifi_stop_station();
        ble_send_text_for_session(session, "$CMD:shutdown_complete\n");
        break;
    case CMD_WIFI_CONFIG_PUT: {
        /* Empty SSID means erase WiFi credentials */
        if (command->wifi.ssid[0] == '\0') {
            err = wifi_erase_credentials();
            if (err == ESP_OK) {
                memset(&s_app.credentials, 0, sizeof(s_app.credentials));
                ble_send_text_for_session(session, "$CMD:wifi_config_received\n");
            } else {
                send_error(session, "WIFI_CONFIG_ERASE_FAILED");
            }
            break;
        }
        err = wifi_save_credentials(&command->wifi);
        if (err != ESP_OK) {
            send_error(session, "WIFI_CONFIG_SAVE_FAILED");
            break;
        }
        s_app.credentials = command->wifi;
        s_app.standby = false;
        udp_stream_stop();
        s_app.wifi_started = false;
        s_app.wifi_was_connected = false;
        ble_send_text_for_session(session, "$CMD:wifi_config_received\n");

        /* Send back ESP MAC address and hostname */
        char mac_str[TELEMETRY_TEXT_CAPACITY];
        uint8_t mac[6];
        err = esp_read_mac(mac, ESP_MAC_WIFI_STA);
        if (err != ESP_OK) {
            send_error(session, "DEVICE_IDENTITY_FAILED");
            break;
        }
        snprintf(mac_str, sizeof(mac_str), "$ESP_MAC:%02X:%02X:%02X:%02X:%02X:%02X\n",
                 mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
        ble_send_text_for_session(session, mac_str);
        char name_buf[TELEMETRY_TEXT_CAPACITY];
        snprintf(name_buf, sizeof(name_buf), "$ESP_NAME:%s\n", WIFI_HOSTNAME);
        ble_send_text_for_session(session, name_buf);
        send_wifi_config_get_response(session);
        break;
    }
    case CMD_WIFI_CONFIG_GET:
        send_wifi_config_get_response(session);
        break;
    case CMD_CONNECTION_STATUS:
        send_connection_status_response(session);
        break;
    case CMD_BLE_PAIR:
        /* The GATT handler authorizes only this connection after validation. */
        ble_send_text_for_session(session, "$CMD:paired\n");
        break;
    case CMD_REBOOT:
        if (!protocol_wifi_credentials_valid(&s_app.credentials)) {
            send_error(session, "WIFI_CONFIG_REQUIRED");
            err = ESP_ERR_INVALID_STATE;
            break;
        }
        ble_send_text_for_session(session, "$CMD:reboot\n");
        flashlight_set(false);
        vTaskDelay(pdMS_TO_TICKS(RESTART_ACK_DELAY_MS));
        esp_restart();
        break;
    default:
        send_error(session, "COMMAND_UNKNOWN");
        err = ESP_ERR_INVALID_ARG;
        break;
    }
    ESP_LOGI(TAG, "operation=command.execute transport=%s session=%" PRIu32
             " command=0x%02x duration_ms=%" PRId64 " outcome=%s",
             from_ble ? "ble" : "udp", session, command->code,
             (esp_timer_get_time() - started) / 1000,
             err == ESP_OK ? "success" : "failure");
}

static void capture_and_send(bool single)
{
    bool udp = s_app.wifi_started && wifi_is_connected() && udp_stream_has_peer();
    if (!udp && !ble_can_notify()) {
        return;
    }
    if (camera_set_udp_mode(udp) != ESP_OK) {
        ++s_app.frame_errors;
        send_error(s_app.ble_session, "CAMERA_SETTINGS_FAILED");
        return;
    }
    camera_fb_t *fb = camera_capture();
    if (fb == NULL) {
        ++s_app.frame_errors;
        send_error(s_app.ble_session, "CAMERA_CAPTURE_FAILED");
        return;
    }
    bool sent = udp ? udp_stream_send_frame(fb->buf, fb->len)
                    : ble_send_bytes_for_session(s_app.ble_session, fb->buf, fb->len) == ESP_OK;
    if (sent) {
        ++s_app.frames_sent;
        if (single || s_app.frames_sent == 1) {
            ESP_LOGI(TAG, "operation=frame.send transport=%s bytes=%zu width=%zu height=%zu",
                     udp ? "udp" : "ble", fb->len, fb->width, fb->height);
        }
    } else if (udp || ble_can_notify()) {
        ++s_app.frame_errors;
        send_error(s_app.ble_session, "FRAME_SEND_FAILED");
    }
    camera_release(fb);
}

static void run_application(void)
{
    int64_t next_telemetry = 0;
    int64_t next_status = 0;
    while (true) {
        reconcile_ble_session(ble_session_id());
        ble_command_t queued;
        for (unsigned i = 0; i < BLE_COMMAND_QUEUE_LENGTH && ble_next_command(&queued); ++i) {
            handle_command(&queued.command, true, queued.session);
        }
        /* A disconnect during the last reply must clear old streaming/GPIO
         * state before this iteration can capture for a replacement link. */
        reconcile_ble_session(ble_session_id());
        firmware_command_t command;
        if (!s_app.standby) {
            wifi_maintain();
        }
        bool wifi_connected = wifi_is_connected();
        if (wifi_connected && !s_app.standby && !s_app.wifi_started) {
            s_app.wifi_started = udp_stream_start() == ESP_OK;
        }
        if (!wifi_connected && s_app.wifi_started) {
            udp_stream_stop();
            s_app.wifi_started = false;
        }
        if (wifi_connected != s_app.wifi_was_connected) {
            s_app.wifi_was_connected = wifi_connected;
            ble_send_text(wifi_connected ? "$WIFI:connected\n" : "$WIFI:disconnected\n");
            send_connection_status_response(ble_session_id());
        }
        if (s_app.wifi_started) {
            for (unsigned i = 0; i < UDP_POLL_MAX_PACKETS &&
                 udp_stream_receive_command(&command); ++i) {
                handle_command(&command, false, ble_session_id());
            }
        }
        bool notify = ble_can_notify();
        if (notify && !s_app.ble_notify_enabled) {
            if (!sensors_available()) {
                ble_send_text("$WARN:SENSOR_NOT_FOUND\n");
            }
            send_connection_status_response(ble_session_id());
        }
        if (!notify && s_app.ble_notify_enabled) {
            s_app.streaming = false;
            s_app.pending_frames = 0;
        }
        s_app.ble_notify_enabled = notify;
        int64_t now = esp_timer_get_time();
        if (notify && !s_app.standby && sensors_available() && now >= next_telemetry) {
            as7265x_reading_t reading;
            esp_err_t err = sensors_read_uv_ir(&reading);
            if (err == ESP_OK && reading.available) {
                char packet[TELEMETRY_TEXT_CAPACITY];
                int n = snprintf(packet, sizeof(packet), "$UV:%u;IR:%u\n",
                                 reading.uv_raw, reading.ir_raw);
                if (n > 0 && (size_t)n < sizeof(packet)) {
                    ble_send_bytes((const uint8_t *)packet, (size_t)n);
                }
            } else if (err != ESP_ERR_INVALID_STATE) {
                send_error(ble_session_id(), "SENSOR_READ_FAILED");
            }
            next_telemetry = esp_timer_get_time() + TELEMETRY_INTERVAL_MS * 1000LL;
        }
        if ((notify || !s_app.ble_started) && now >= next_status) {
            send_connection_status_response(ble_session_id());
            next_status = esp_timer_get_time() + STATUS_INTERVAL_MS * 1000LL;
        }
        if (s_app.pending_frames > 0 || (s_app.streaming && now >= s_app.next_frame)) {
            bool single = s_app.pending_frames > 0;
            if (single) {
                --s_app.pending_frames;
            }
            capture_and_send(single);
            bool udp = s_app.wifi_started && udp_stream_has_peer();
            s_app.next_frame = (udp ? now : esp_timer_get_time()) +
                (udp ? STREAM_INTERVAL_MS : BLE_STREAM_INTERVAL_MS) * 1000LL;
        }
        vTaskDelay(pdMS_TO_TICKS(MAIN_POLL_INTERVAL_MS));
    }
}

void app_main(void)
{
    ESP_LOGI(TAG, "SpectruLenPor firmware %s", FIRMWARE_VERSION);
    esp_err_t err = nvs_flash_init();
    /* Failed NVS initialization must preserve saved commissioning data.
     * Any NVS-only reset requires an explicit operator action. */
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "operation=boot.init code=NVS_INIT_FAILED detail=%s", esp_err_to_name(err));
        return;
    }
    if (flashlight_init() != ESP_OK || esp_netif_init() != ESP_OK) {
        ESP_LOGE(TAG, "operation=boot.init code=HARDWARE_INIT_FAILED");
        return;
    }
    err = esp_event_loop_create_default();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "operation=boot.init code=EVENT_LOOP_INIT_FAILED");
        return;
    }
    err = sensors_init();
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "operation=boot.sensor code=SENSOR_UNAVAILABLE");
    }
    err = camera_init();
    if (err == ESP_OK) {
        camera_fb_t *fb = camera_capture();
        if (fb != NULL) {
            ESP_LOGI(TAG, "operation=camera.boot_capture bytes=%zu width=%zu height=%zu jpeg=valid",
                     fb->len, fb->width, fb->height);
            camera_release(fb);
        } else {
            ESP_LOGW(TAG, "operation=camera.boot_capture code=CAMERA_NO_FRAME");
        }
    }

    /* Load WiFi credentials from NVS */
    err = wifi_load_credentials(&s_app.credentials);
    bool have_wifi_config = (err == ESP_OK &&
        protocol_wifi_credentials_valid(&s_app.credentials));

    if (have_wifi_config) {
        ESP_LOGI(TAG, "operation=boot.mode mode=wifi_only ble=0");
        err = wifi_start_station(&s_app.credentials);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "operation=boot.init code=WIFI_INIT_FAILED detail=%s", esp_err_to_name(err));
            return;
        }
    } else {
        if (err != ESP_OK && err != ESP_ERR_NVS_NOT_FOUND) {
            ESP_LOGW(TAG, "operation=wifi.load code=%s", esp_err_to_name(err));
        }
        ESP_LOGI(TAG, "operation=boot.mode mode=ble_setup ble=1");
        err = ble_init();
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "operation=boot.init code=BLE_INIT_FAILED detail=%s", esp_err_to_name(err));
            return;
        }
        s_app.ble_started = true;
    }

    ESP_LOGI(TAG, "operation=boot.ready camera=%d sensor=%d psram=%zu version=%s wifi=%d",
             camera_is_ready(), sensors_available(), camera_psram_bytes(),
             FIRMWARE_VERSION, have_wifi_config);

    run_application();
}
