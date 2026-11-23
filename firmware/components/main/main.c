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
    uint32_t last_capture_ms;
    uint32_t last_send_ms;
    uint32_t last_frame_ms;
    uint32_t last_packet_pace_ms;
    uint32_t last_stream_interval_ms;
    int64_t next_frame;
    uint32_t next_stream_interval_ms;
    uint8_t udp_profile;
    bool udp_profile_initialized;
    bool udp_profile_manual;
    int64_t udp_profile_hold_until;
    int64_t next_link_log;
    firmware_wifi_credentials_t credentials;
} app_state_t;

/* Only the application task owns this state, GPIO, camera, and UDP socket. */
static app_state_t s_app;

static bool send_transport_bytes(bool from_ble, uint32_t session,
                                 const uint8_t *data, size_t len)
{
    if (from_ble) {
        return ble_send_bytes_for_session(session, data, len) == ESP_OK;
    }
    return udp_stream_send_control(data, len);
}

static void send_transport_text(bool from_ble, uint32_t session,
                                const char *text)
{
    if (text == NULL) return;
    (void)send_transport_bytes(from_ble, session,
                              (const uint8_t *)text, strlen(text));
}

static void send_error(bool from_ble, uint32_t session, const char *code)
{
    ESP_LOGE(TAG, "operation=command.error transport=%s code=%s",
             from_ble ? "ble" : "udp", code);
    char text[TELEMETRY_TEXT_CAPACITY];
    int n = snprintf(text, sizeof(text), "$ERROR:%s\n", code);
    if (n > 0 && (size_t)n < sizeof(text)) {
        (void)send_transport_bytes(from_ble, session,
                                   (const uint8_t *)text, (size_t)n);
    }
}

static void send_wifi_config_get_response(uint32_t session)
{
    char buf[STATUS_TEXT_CAPACITY];
    int n = snprintf(buf, sizeof(buf), "$WIFI_CFG:ssid=%s\n",
                     s_app.credentials.ssid);
    if (n > 0 && (size_t)n < sizeof(buf)) {
        (void)ble_send_bytes_for_session(session, (const uint8_t *)buf,
                                          (size_t)n);
    }
}

static void send_connection_status_response(bool from_ble, uint32_t session)
{
    char ip_str[IPV4_TEXT_CAPACITY];
    wifi_local_ip_str(ip_str, sizeof(ip_str));

    const int rssi = wifi_is_connected() ? wifi_rssi_dbm() : -127;
    const int wifi_channel = wifi_channel_number();
    as7265x_reading_t sensor_reading = {0};
    const bool sensor_valid = sensors_available() &&
        sensors_read_spectrum(&sensor_reading) == ESP_OK && sensor_reading.available;
    static const uint16_t spectral_wavelengths[AS7265X_CHANNEL_COUNT] = {
        410U, 435U, 460U, 485U, 510U, 535U,
        560U, 585U, 610U, 645U, 680U, 705U,
        730U, 760U, 810U, 860U, 900U, 940U,
    };
    char spectrum[256] = {0};
    if (sensor_valid) {
        size_t used = 0;
        for (size_t index = 0; index < AS7265X_CHANNEL_COUNT; ++index) {
            const int written = snprintf(spectrum + used, sizeof(spectrum) - used,
                "%s%u:%u", index == 0 ? "" : ";",
                (unsigned)spectral_wavelengths[index],
                (unsigned)sensor_reading.raw[index]);
            if (written < 0 || (size_t)written >= sizeof(spectrum) - used) {
                spectrum[0] = '\0';
                break;
            }
            used += (size_t)written;
        }
    }

    char buf[STATUS_TEXT_CAPACITY];
    int n = snprintf(buf, sizeof(buf),
        "$STATUS:bt=%d,wifi=%s,ip=%s,rssi=%d,channel=%d,profile=%u,flash=%d,stream=%d,"
        "camera=%d,sensor=%d,sensor_valid=%d,sensor_410=%u,sensor_940=%u,spectrum=%s,"
        "temp_as72653=%d,temp_as72652=%d,temp_as72651=%d,manual_profile=%d,"
        "psram=%zu,frames=%" PRIu32 ",errors=%" PRIu32
        ",capture_ms=%" PRIu32 ",send_ms=%" PRIu32 ",frame_ms=%" PRIu32
        ",pace_ms=%" PRIu32 ",interval_ms=%" PRIu32
        ",notify_errors=%" PRIu32 ",heap=%zu,min_heap=%zu,standby=%d\n",
        ble_is_connected(), wifi_status_string(), ip_str, rssi, wifi_channel,
        (unsigned)s_app.udp_profile, flashlight_is_on(), s_app.streaming,
        camera_is_ready(), sensors_available(), sensor_valid,
        (unsigned)sensor_reading.raw[0],
        (unsigned)sensor_reading.raw[AS7265X_CHANNEL_COUNT - 1U], spectrum,
        (int)sensor_reading.temperature_c[0],
        (int)sensor_reading.temperature_c[1],
        (int)sensor_reading.temperature_c[2], s_app.udp_profile_manual,
        camera_psram_bytes(), s_app.frames_sent, s_app.frame_errors,
        s_app.last_capture_ms, s_app.last_send_ms, s_app.last_frame_ms,
        s_app.last_packet_pace_ms, s_app.last_stream_interval_ms,
        ble_notification_errors(),
        heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT),
        heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT),
        s_app.standby);
    if (n > 0 && (size_t)n < sizeof(buf)) {
        (void)send_transport_bytes(from_ble, session,
                                   (const uint8_t *)buf, (size_t)n);
        ESP_LOGI(TAG, "operation=status.snapshot transport=%s %.*s",
                 from_ble ? "ble" : "udp", n - 1, buf);
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
        if (!ble_session_is_current(session)) {
            ESP_LOGW(TAG, "operation=command.reject transport=ble session=%" PRIu32
                     " command=0x%02x code=BLE_SESSION_CLOSED",
                     session, command->code);
            return;
        }
        /* Reconcile every newly accepted BLE session before deciding whether
         * its command is allowed. Otherwise a forbidden stream command could
         * leave the app's session identity stale indefinitely. */
        reconcile_ble_session(session);
        if (!ble_session_is_current(session)) return;
        if (!protocol_command_allowed_over_ble_setup(command->code)) {
            send_error(true, session, "VIDEO_AND_RUNTIME_COMMANDS_REQUIRE_UDP");
            ESP_LOGW(TAG, "operation=command.reject transport=ble command=0x%02x code=UDP_REQUIRED",
                     command->code);
            return;
        }
    } else if (!udp_stream_has_peer()) {
        ESP_LOGW(TAG, "operation=command.reject transport=udp command=0x%02x code=NO_PEER",
                 command->code);
        return;
    }

    const int64_t started = esp_timer_get_time();
    esp_err_t err = ESP_OK;

    switch (command->code) {
    case CMD_STREAM_ON:
        if (from_ble) {
            send_error(true, session, "VIDEO_REQUIRES_WIFI_UDP");
            err = ESP_ERR_INVALID_ARG;
            break;
        }
        if (!wifi_is_connected() || !camera_is_ready()) {
            send_error(false, session, "WIFI_OR_CAMERA_UNAVAILABLE");
            err = ESP_ERR_INVALID_STATE;
            break;
        }
        s_app.standby = false;
        s_app.streaming = true;
        s_app.next_frame = 0;
        s_app.next_stream_interval_ms = STREAM_INTERVAL_MS;
        send_transport_text(false, session, "$CMD:stream_on\n");
        break;

    case CMD_STREAM_OFF:
        if (from_ble) {
            send_error(true, session, "VIDEO_REQUIRES_WIFI_UDP");
            err = ESP_ERR_INVALID_ARG;
            break;
        }
        s_app.streaming = false;
        s_app.pending_frames = 0;
        send_transport_text(false, session, "$CMD:stream_off\n");
        break;

    case CMD_SINGLE_FRAME:
        if (from_ble) {
            send_error(true, session, "VIDEO_REQUIRES_WIFI_UDP");
            err = ESP_ERR_INVALID_ARG;
            break;
        }
        if (wifi_is_connected() && camera_is_ready() &&
            s_app.pending_frames < BLE_COMMAND_QUEUE_LENGTH) {
            ++s_app.pending_frames;
            send_transport_text(false, session, "$CMD:single_frame\n");
        } else {
            send_error(false, session,
                       camera_is_ready() ? "WIFI_UNAVAILABLE" : "CAMERA_UNAVAILABLE");
            err = ESP_ERR_INVALID_STATE;
        }
        break;

    case CMD_UDP_KEEPALIVE:
        if (from_ble) {
            send_error(true, session, "UDP_KEEPALIVE_REQUIRES_UDP");
            err = ESP_ERR_INVALID_ARG;
        } else {
            send_transport_text(false, session, "$CMD:keepalive\n");
        }
        break;

    case CMD_SET_VIDEO_PROFILE:
        if (from_ble) {
            send_error(true, session, "VIDEO_PROFILE_REQUIRES_UDP");
            err = ESP_ERR_INVALID_ARG;
            break;
        }
        if (!wifi_is_connected() || !camera_is_ready()) {
            send_error(false, session, "WIFI_OR_CAMERA_UNAVAILABLE");
            err = ESP_ERR_INVALID_STATE;
            break;
        }
        if (command->video_profile == UINT8_MAX) {
            s_app.udp_profile_manual = false;
            s_app.udp_profile_initialized = false;
            s_app.udp_profile_hold_until = 0;
            send_transport_text(false, session, "$CMD:video_profile=auto,manual=0\n");
        } else if (command->video_profile <= 4U) {
            s_app.udp_profile = command->video_profile;
            s_app.udp_profile_initialized = true;
            s_app.udp_profile_manual = true;
            s_app.udp_profile_hold_until = INT64_MAX;
            char profile_ack[64];
            const int ack_len = snprintf(profile_ack, sizeof(profile_ack),
                "$CMD:video_profile=%u,manual=1\n", (unsigned)s_app.udp_profile);
            if (ack_len > 0 && (size_t)ack_len < sizeof(profile_ack)) {
                send_transport_text(false, session, profile_ack);
            }
        } else {
            err = ESP_ERR_INVALID_ARG;
            send_error(false, session, "INVALID_VIDEO_PROFILE");
        }
        break;

    case CMD_FLASH_ON:
    case CMD_FLASH_OFF:
        err = flashlight_set(command->code == CMD_FLASH_ON);
        if (err == ESP_OK) {
            send_transport_text(from_ble, session,
                command->code == CMD_FLASH_ON ? "$CMD:flash_on\n" : "$CMD:flash_off\n");
        } else {
            send_error(from_ble, session, "FLASH_GPIO_FAILED");
        }
        break;

    case CMD_RESTART:
        send_transport_text(from_ble, session, "$CMD:restart\n");
        flashlight_set(false);
        vTaskDelay(pdMS_TO_TICKS(RESTART_ACK_DELAY_MS));
        esp_restart();
        break;

    case CMD_SHUTDOWN:
        send_transport_text(from_ble, session, "$CMD:shutdown_complete\n");
        s_app.streaming = false;
        s_app.pending_frames = 0;
        s_app.standby = true;
        flashlight_set(false);
        udp_stream_stop();
        s_app.wifi_started = false;
        s_app.wifi_was_connected = false;
        err = wifi_stop_station();
        break;

    case CMD_WIFI_CONFIG_PUT: {
        if (!from_ble) {
            send_error(false, session, "WIFI_PROVISIONING_REQUIRES_BLE_SETUP");
            err = ESP_ERR_INVALID_ARG;
            break;
        }
        if (command->wifi.ssid[0] == '\0') {
            err = wifi_erase_credentials();
            if (err == ESP_OK) {
                memset(&s_app.credentials, 0, sizeof(s_app.credentials));
                send_transport_text(true, session, "$CMD:wifi_config_received\n");
            } else {
                send_error(true, session, "WIFI_CONFIG_ERASE_FAILED");
            }
            break;
        }
        err = wifi_save_credentials(&command->wifi);
        if (err != ESP_OK) {
            send_error(true, session, "WIFI_CONFIG_SAVE_FAILED");
            break;
        }
        s_app.credentials = command->wifi;
        s_app.standby = false;
        udp_stream_stop();
        s_app.wifi_started = false;
        s_app.wifi_was_connected = false;
        send_transport_text(true, session, "$CMD:wifi_config_received\n");

        uint8_t mac[6];
        err = esp_read_mac(mac, ESP_MAC_WIFI_STA);
        if (err != ESP_OK) {
            send_error(true, session, "DEVICE_IDENTITY_FAILED");
            break;
        }
        char mac_str[TELEMETRY_TEXT_CAPACITY];
        snprintf(mac_str, sizeof(mac_str), "$ESP_MAC:%02X:%02X:%02X:%02X:%02X:%02X\n",
                 mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
        send_transport_text(true, session, mac_str);
        char name_buf[TELEMETRY_TEXT_CAPACITY];
        snprintf(name_buf, sizeof(name_buf), "$ESP_NAME:%s\n", WIFI_HOSTNAME);
        send_transport_text(true, session, name_buf);
        send_wifi_config_get_response(session);
        break;
    }

    case CMD_WIFI_CONFIG_GET:
        if (!from_ble) {
            send_error(false, session, "WIFI_CONFIG_IS_SETUP_ONLY");
            err = ESP_ERR_INVALID_ARG;
        } else {
            send_wifi_config_get_response(session);
        }
        break;

    case CMD_CONNECTION_STATUS:
        send_connection_status_response(from_ble, session);
        break;

    case CMD_BLE_PAIR:
        if (!from_ble) {
            send_error(false, session, "PAIRING_IS_SETUP_ONLY");
            err = ESP_ERR_INVALID_ARG;
        } else {
            /* The GATT handler authorizes only this connection after validation. */
            send_transport_text(true, session, "$CMD:paired\n");
        }
        break;

    case CMD_REBOOT:
        if (!protocol_wifi_credentials_valid(&s_app.credentials)) {
            send_error(from_ble, session, "WIFI_CONFIG_REQUIRED");
            err = ESP_ERR_INVALID_STATE;
            break;
        }
        send_transport_text(from_ble, session, "$CMD:reboot\n");
        flashlight_set(false);
        vTaskDelay(pdMS_TO_TICKS(RESTART_ACK_DELAY_MS));
        esp_restart();
        break;

    default:
        send_error(from_ble, session, "COMMAND_UNKNOWN");
        err = ESP_ERR_INVALID_ARG;
        break;
    }

    ESP_LOGI(TAG, "operation=command.execute transport=%s session=%" PRIu32
             " command=0x%02x duration_ms=%" PRId64 " outcome=%s",
             from_ble ? "ble" : "udp", from_ble ? session : 0U,
             command->code, (esp_timer_get_time() - started) / 1000,
             err == ESP_OK ? "success" : "failure");
}

/* RSSI hysteresis prevents frame-size churn when the AP signal fluctuates
 * around a profile boundary. 0=XGA, 1=SVGA, 2=VGA, 3=QVGA, 4=QQVGA. */
static uint8_t select_udp_profile(int rssi, bool has_psram)
{
    if (!has_psram) {
        return 3;
    }
    if (!s_app.udp_profile_initialized) {
        s_app.udp_profile_initialized = true;
        if (rssi < UDP_RSSI_ULTRA_DBM) return 4;
        if (rssi < UDP_RSSI_LOW_DBM) return 3;
        if (rssi < UDP_RSSI_MEDIUM_DBM) return 2;
        if (rssi < UDP_RSSI_HIGH_DBM) return 1;
        return 0;
    }

    const int64_t now = esp_timer_get_time();
    if (now < s_app.udp_profile_hold_until) {
        uint8_t signal_profile = 0;
        if (rssi < UDP_RSSI_ULTRA_DBM - 3) signal_profile = 4;
        else if (rssi < UDP_RSSI_LOW_DBM - 3) signal_profile = 3;
        else if (rssi < UDP_RSSI_MEDIUM_DBM - 3) signal_profile = 2;
        else if (rssi < UDP_RSSI_HIGH_DBM) signal_profile = 1;
        return s_app.udp_profile > signal_profile
                   ? s_app.udp_profile
                   : signal_profile;
    }

    switch (s_app.udp_profile) {
    case 0:
        if (rssi < UDP_RSSI_HIGH_DBM - 3) return 1;
        return 0;
    case 1:
        if (rssi >= UDP_RSSI_HIGH_DBM + 3) return 0;
        if (rssi < UDP_RSSI_MEDIUM_DBM - 3) return 2;
        return 1;
    case 2:
        if (rssi >= UDP_RSSI_MEDIUM_DBM + 3) return 1;
        if (rssi < UDP_RSSI_LOW_DBM - 3) return 3;
        return 2;
    case 3:
        if (rssi >= UDP_RSSI_LOW_DBM + 3) return 2;
        if (rssi < UDP_RSSI_ULTRA_DBM - 3) return 4;
        return 3;
    default:
        if (rssi >= UDP_RSSI_ULTRA_DBM + 3) return 3;
        return 4;
    }
}

static void reduce_udp_profile(uint8_t failed_profile,
                               const char *reason,
                               uint32_t frame_ms)
{
    if (s_app.udp_profile_manual || failed_profile >= 4U) return;

    const uint8_t reduced_profile = failed_profile + 1U;
    s_app.udp_profile = reduced_profile;
    s_app.udp_profile_initialized = true;
    s_app.udp_profile_hold_until =
        esp_timer_get_time() + (int64_t)UDP_PROFILE_HOLD_MS * 1000LL;
    switch (reduced_profile) {
    case 1: s_app.next_stream_interval_ms = UDP_INTERVAL_MEDIUM_MS; break;
    case 2: s_app.next_stream_interval_ms = UDP_INTERVAL_LOW_MS; break;
    case 3: s_app.next_stream_interval_ms = UDP_INTERVAL_MINIMAL_MS; break;
    default: s_app.next_stream_interval_ms = UDP_INTERVAL_ULTRA_MS; break;
    }
    ESP_LOGW(TAG,
             "operation=video.profile outcome=degraded from=%u to=%u reason=%s frame_ms=%" PRIu32,
             (unsigned)failed_profile, (unsigned)reduced_profile,
             reason, frame_ms);
}

static void capture_and_send(bool single)
{
    if (!s_app.wifi_started || !wifi_is_connected() ||
        !udp_stream_has_peer() || !camera_is_ready()) {
        return;
    }

    if (camera_set_udp_mode(true) != ESP_OK) {
        ++s_app.frame_errors;
        send_error(false, 0, "CAMERA_SETTINGS_FAILED");
        return;
    }

    const int rssi = wifi_rssi_dbm();
    const uint8_t profile = s_app.udp_profile_manual
        ? s_app.udp_profile
        : select_udp_profile(rssi, camera_psram_bytes() > 0);
    framesize_t target_size = FRAMESIZE_XGA;
    int jpeg_quality = UDP_QUALITY_HIGH;
    uint32_t interval_ms = UDP_INTERVAL_HIGH_MS;
    uint32_t packet_pace_ms = UDP_PACKET_PACE_HIGH_MS;
    switch (profile) {
    case 1:
        target_size = FRAMESIZE_SVGA;
        jpeg_quality = UDP_QUALITY_MEDIUM;
        interval_ms = UDP_INTERVAL_MEDIUM_MS;
        packet_pace_ms = UDP_PACKET_PACE_MEDIUM_MS;
        break;
    case 2:
        target_size = FRAMESIZE_VGA;
        jpeg_quality = UDP_QUALITY_LOW;
        interval_ms = UDP_INTERVAL_LOW_MS;
        packet_pace_ms = UDP_PACKET_PACE_LOW_MS;
        break;
    case 3:
        target_size = FRAMESIZE_QVGA;
        jpeg_quality = UDP_QUALITY_MINIMAL;
        interval_ms = UDP_INTERVAL_MINIMAL_MS;
        packet_pace_ms = UDP_PACKET_PACE_MINIMAL_MS;
        break;
    case 4:
        target_size = FRAMESIZE_QQVGA;
        jpeg_quality = UDP_QUALITY_ULTRA;
        interval_ms = UDP_INTERVAL_ULTRA_MS;
        packet_pace_ms = UDP_PACKET_PACE_ULTRA_MS;
        break;
    default:
        break;
    }

    if (camera_set_udp_profile(target_size, jpeg_quality) != ESP_OK) {
        ++s_app.frame_errors;
        send_error(false, 0, "CAMERA_PROFILE_FAILED");
        return;
    }

    s_app.udp_profile = profile;
    s_app.next_stream_interval_ms = interval_ms;
    int64_t now = esp_timer_get_time();
    if (now >= s_app.next_link_log) {
        ESP_LOGI(TAG,
                 "operation=video.link rssi_dbm=%d frame_size=%d quality=%d interval_ms=%" PRIu32,
                 rssi, (int)target_size, jpeg_quality, interval_ms);
        s_app.next_link_log = now + 5000000LL;
    }

    const int64_t frame_started = esp_timer_get_time();
    camera_fb_t *fb = camera_capture();
    const int64_t captured_at = esp_timer_get_time();
    if (fb == NULL) {
        ++s_app.frame_errors;
        send_error(false, 0, "CAMERA_CAPTURE_FAILED");
        return;
    }

    bool sent = udp_stream_send_frame(fb->buf, fb->len, packet_pace_ms);
    const int64_t completed_at = esp_timer_get_time();
    const uint32_t capture_ms =
        (uint32_t)((captured_at - frame_started) / 1000LL);
    const uint32_t send_ms =
        (uint32_t)((completed_at - captured_at) / 1000LL);
    const uint32_t frame_ms =
        (uint32_t)((completed_at - frame_started) / 1000LL);
    s_app.last_capture_ms = capture_ms;
    s_app.last_send_ms = send_ms;
    s_app.last_frame_ms = frame_ms;
    s_app.last_packet_pace_ms = packet_pace_ms;
    s_app.last_stream_interval_ms = interval_ms;
    if (sent) {
        ++s_app.frames_sent;
        if (s_app.frames_sent <= 12U) {
            ESP_LOGI(TAG,
                     "operation=frame.timing frame=%" PRIu32
                     " capture_ms=%" PRIu32 " send_ms=%" PRIu32
                     " total_ms=%" PRIu32 " bytes=%zu profile=%u"
                     " pace_ms=%" PRIu32 " interval_ms=%" PRIu32,
                     s_app.frames_sent, capture_ms, send_ms, frame_ms,
                     fb->len, (unsigned)profile, packet_pace_ms, interval_ms);
        }
        if (frame_ms > UDP_FRAME_BUDGET_MS) {
            reduce_udp_profile(profile, "frame_budget", frame_ms);
        }
        if (single || s_app.frames_sent == 1) {
            ESP_LOGI(TAG,
                     "operation=frame.send transport=udp bytes=%zu width=%zu height=%zu",
                     fb->len, fb->width, fb->height);
        }
    } else {
        ++s_app.frame_errors;
        reduce_udp_profile(profile, "send_failed", frame_ms);
        send_error(false, 0, "FRAME_SEND_FAILED");
    }
    camera_release(fb);
}

static int64_t s_wifi_unavailable_since;
static int64_t s_ble_recovery_last_attempt;

/* Keep commissioning reachable when saved WiFi credentials stop working.
 * BLE remains setup-only: frame and runtime traffic still require UDP. */
static void maintain_ble_recovery(bool wifi_connected)
{
    if (wifi_connected) {
        s_wifi_unavailable_since = 0;
        s_ble_recovery_last_attempt = 0;
        return;
    }
    if (s_app.ble_started) {
        return;
    }

    const int64_t now = esp_timer_get_time();
    if (s_wifi_unavailable_since == 0) {
        s_wifi_unavailable_since = now;
        return;
    }
    if (now - s_wifi_unavailable_since <
        (int64_t)WIFI_BLE_RECOVERY_DELAY_MS * 1000LL) {
        return;
    }

    if (s_ble_recovery_last_attempt != 0 &&
        now - s_ble_recovery_last_attempt <
            (int64_t)WIFI_RETRY_INTERVAL_MS * 1000LL) {
        return;
    }
    s_ble_recovery_last_attempt = now;
    ESP_LOGW(TAG,
             "operation=ble.recovery outcome=starting reason=WIFI_UNAVAILABLE");

    /* Recovery is a commissioning-only state. Stop the old station driver so
     * stale credentials cannot reconnect while the app is provisioning a new
     * profile; the next reboot starts Wi-Fi from the newly saved NVS record. */
    udp_stream_stop();
    s_app.wifi_started = false;
    s_app.wifi_was_connected = false;
    const esp_err_t wifi_stop_err = wifi_stop_station();
    if (wifi_stop_err != ESP_OK) {
        ESP_LOGW(TAG, "operation=wifi.recovery_stop outcome=failure code=%s",
                 esp_err_to_name(wifi_stop_err));
    } else {
        ESP_LOGI(TAG, "operation=wifi.recovery_stop outcome=success");
    }

    const esp_err_t err = ble_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG,
                 "operation=ble.recovery outcome=failure code=BLE_INIT_FAILED");
        return;
    }

    s_app.ble_started = true;
    s_app.ble_notify_enabled = false;
    s_app.ble_session = 0;
    ESP_LOGW(TAG,
             "operation=ble.recovery outcome=advertising mode=commissioning");
}

static void run_application(void)
{
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
        /* While BLE is commissioning, keep the station stopped. Credentials
         * take effect only after the app saves them and reboots the ESP32. */
        if (!s_app.standby && !s_app.ble_started) {
            wifi_maintain();
        }
        bool wifi_connected = wifi_is_connected();
        maintain_ble_recovery(wifi_connected);
        if (wifi_connected && !s_app.standby && !s_app.wifi_started) {
            s_app.wifi_started = udp_stream_start() == ESP_OK;
        }
        if (!wifi_connected && s_app.wifi_started) {
            udp_stream_stop();
            s_app.wifi_started = false;
            s_app.streaming = false;
            s_app.pending_frames = 0;
        }
        if (wifi_connected != s_app.wifi_was_connected) {
            s_app.wifi_was_connected = wifi_connected;
            if (s_app.ble_started && ble_can_notify()) {
                ble_send_text(wifi_connected ? "$WIFI:connected\n" : "$WIFI:disconnected\n");
                send_connection_status_response(true, ble_session_id());
            }
            if (udp_stream_has_peer()) {
                send_connection_status_response(false, 0);
            }
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
            send_connection_status_response(true, ble_session_id());
        }
        if (!notify && s_app.ble_notify_enabled) {
            s_app.streaming = false;
            s_app.pending_frames = 0;
        }
        s_app.ble_notify_enabled = notify;
        int64_t now = esp_timer_get_time();
        if (notify && now >= next_status) {
            send_connection_status_response(true, ble_session_id());
            next_status = esp_timer_get_time() + STATUS_INTERVAL_MS * 1000LL;
        }
        if (s_app.wifi_started && udp_stream_has_peer() &&
            (s_app.pending_frames > 0 || (s_app.streaming && now >= s_app.next_frame))) {
            bool single = s_app.pending_frames > 0;
            if (single) {
                --s_app.pending_frames;
            }
            capture_and_send(single);
            s_app.next_frame = esp_timer_get_time() +
                (int64_t)s_app.next_stream_interval_ms * 1000LL;
        }
        const uint32_t poll_interval_ms =
            s_app.streaming || s_app.pending_frames > 0
                ? MAIN_STREAM_POLL_INTERVAL_MS
                : MAIN_POLL_INTERVAL_MS;
        vTaskDelay(pdMS_TO_TICKS(poll_interval_ms));
    }
}

/*
 * Project author: Malak Adel Sayed Hassan.
 * Main software developer and original application/firmware code author:
 * Abdoul-Rahman Ayman (GitHub: abdou-da0wew).
 */
void app_main(void)
{
    ESP_LOGI(TAG, "SpectruLenPor firmware %s", FIRMWARE_VERSION);
    ESP_LOGI(TAG, "Project author: %s", PROJECT_AUTHOR_NAME);
    ESP_LOGI(TAG, "Software developer and code author: %s",
             FIRMWARE_DEVELOPER_NAME);
    ESP_LOGI(TAG, "Developer profile: %s", FIRMWARE_DEVELOPER_URL);
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
