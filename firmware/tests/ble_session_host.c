#include <inttypes.h>
#include <errno.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ble.h"
#include "wifi.h"

enum { BLE_HS_CONN_HANDLE_NONE = 65535, BLE_ATT_MTU_DFLT = 23,
    BLE_GAP_EVENT_CONNECT, BLE_GAP_EVENT_DISCONNECT, BLE_GAP_EVENT_ADV_COMPLETE,
    BLE_GAP_EVENT_SUBSCRIBE, BLE_GAP_EVENT_MTU, BLE_GAP_EVENT_NOTIFY_TX,
    BLE_GATT_ACCESS_OP_WRITE_CHR,
    BLE_ATT_ERR_WRITE_NOT_PERMITTED, BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN,
    BLE_ATT_ERR_UNLIKELY, BLE_ATT_ERR_VALUE_NOT_ALLOWED, BLE_ATT_ERR_INSUFFICIENT_RES,
    BLE_HS_ENOMEM, BLE_HS_EBUSY, MALLOC_CAP_INTERNAL = 1, MALLOC_CAP_8BIT = 2 };
typedef int portMUX_TYPE;
typedef void *QueueHandle_t;
typedef void *SemaphoreHandle_t;
#define portMUX_INITIALIZER_UNLOCKED 0
#define portENTER_CRITICAL(lock) host_enter(lock)
#define portEXIT_CRITICAL(lock) host_exit(lock)
#define pdMS_TO_TICKS(ticks) (ticks)
#define pdTRUE 1
#define portMAX_DELAY 0xffffffffU
struct os_mbuf { uint16_t len; uint8_t data[COMMAND_MAX_BYTES + STATUS_TEXT_CAPACITY]; };
struct ble_gatt_access_ctxt { int op; struct os_mbuf *om; };
struct ble_gap_event {
    int type;
    struct { int status; uint16_t conn_handle; } connect;
    struct { int reason; } disconnect;
    struct { uint16_t conn_handle, attr_handle; unsigned cur_notify; } subscribe;
    struct { uint16_t conn_handle, value; } mtu;
};
static int gap_event_cb(struct ble_gap_event *event, void *arg);
typedef struct { uint8_t *buf; size_t len, width, height; } camera_fb_t;
typedef int framesize_t;
enum { FRAMESIZE_QVGA = 0, FRAMESIZE_VGA = 1, FRAMESIZE_SVGA = 2, FRAMESIZE_XGA = 3 };
typedef struct { bool available; unsigned uv_raw, ir_raw; } as7265x_reading_t;
static const char *scenario;
static jmp_buf finished;
static int64_t clock_now;
static bool flash_on, camera_ready = true, triggered, awaiting_dequeue;
static bool command_processing;
static unsigned notify_calls, new_link_notifications, flash_on_calls, resets, save_calls;
static unsigned ble_init_calls;
static esp_err_t ble_init_result = ESP_OK;
static _Thread_local unsigned tx_locked, critical_depth;
static unsigned queue_head, queue_tail;
static pthread_mutex_t notification_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t critical_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t callback_gate = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t callback_condition = PTHREAD_COND_INITIALIZER;
static pthread_t reconnect_thread;
static bool thread_started, callback_blocked, callback_completed;
static uint32_t original_session;
static char notifications[2048];
static unsigned char queue_storage[BLE_COMMAND_QUEUE_LENGTH][sizeof(firmware_command_t) + 16U];
static size_t queue_item_size;
static uint8_t frame[4] = {255, 216, 255, 217};
static camera_fb_t host_fb = {frame, sizeof(frame), 1, 1};
void host_enter(portMUX_TYPE *lock);
void host_exit(portMUX_TYPE *lock);
void host_reconnect(void);
void host_queue(uint8_t code);
void *host_reconnect_thread(void *arg);
bool is_case(const char *name) { return strcmp(scenario, name) == 0; }
esp_err_t ble_init(void)
{
    ++ble_init_calls;
    return ble_init_result;
}

const char *esp_err_to_name(esp_err_t error)
{
    (void)error;
    return "host-error";
}
void host_log(const char *tag, const char *format, ...)
{
    (void)tag;
    if (strstr(format, "operation=command.execute") ||
        strstr(format, "operation=command.reject")) command_processing = false;
}
#define ESP_LOGI(tag, ...) host_log(tag, __VA_ARGS__)
#define ESP_LOGW(tag, ...) host_log(tag, __VA_ARGS__)
#define ESP_LOGE(tag, ...) host_log(tag, __VA_ARGS__)
#define OS_MBUF_PKTLEN(om) ((om)->len)
int64_t esp_timer_get_time(void) { return clock_now; }
int xSemaphoreTake(SemaphoreHandle_t mutex, unsigned timeout)
{
    (void)timeout;
    if (tx_locked) abort();
    if (thread_started && pthread_equal(pthread_self(), reconnect_thread)) {
        int result = pthread_mutex_trylock(mutex);
        if (result == EBUSY) {
            if (pthread_mutex_lock(&callback_gate)) abort();
            callback_blocked = true;
            if (pthread_cond_signal(&callback_condition)) abort();
            if (pthread_mutex_unlock(&callback_gate)) abort();
            if (pthread_mutex_lock(mutex)) abort();
        } else if (result != 0) abort();
    } else if (pthread_mutex_lock(mutex)) abort();
    ++tx_locked;
    return pdTRUE;
}
int xSemaphoreGive(SemaphoreHandle_t mutex)
{
    if (tx_locked != 1) abort();
    --tx_locked;
    if (pthread_mutex_unlock(mutex)) abort();
    if (thread_started && !pthread_equal(pthread_self(), reconnect_thread)) {
        if (pthread_join(reconnect_thread, NULL)) abort();
        thread_started = false;
    }
    return pdTRUE;
}
int xQueueReceive(QueueHandle_t queue, void *item, unsigned timeout)
{
    (void)queue; (void)timeout;
    if (!triggered && (is_case("new_stream_during_drain") || is_case("new_flash_during_drain"))) {
        triggered = true;
        host_reconnect();
        host_queue(is_case("new_stream_during_drain") ? CMD_STREAM_ON : CMD_FLASH_ON);
    }
    if (queue_head == queue_tail) { command_processing = false; return 0; }
    memcpy(item, queue_storage[queue_head++], queue_item_size);
    command_processing = true;
    if (is_case("stale_at_execution") && !triggered) awaiting_dequeue = true;
    return pdTRUE;
}
int xQueueSend(QueueHandle_t queue, const void *item, unsigned timeout)
{
    (void)queue; (void)timeout;
    if (queue_tail == BLE_COMMAND_QUEUE_LENGTH) return 0;
    memcpy(queue_storage[queue_tail++], item, queue_item_size);
    return pdTRUE;
}
int ble_hs_mbuf_to_flat(struct os_mbuf *om, void *out, uint16_t capacity, uint16_t *copied)
{
    if (om->len > capacity) return -1;
    memcpy(out, om->data, om->len); *copied = om->len; return 0;
}
struct os_mbuf *ble_hs_mbuf_from_flat(const void *data, uint16_t length)
{
    if (!triggered && is_case("reconnect_at_mbuf_allocation")) {
        triggered = true;
        if (pthread_mutex_lock(&callback_gate)) abort();
        thread_started = true;
        if (pthread_create(&reconnect_thread, NULL, host_reconnect_thread, NULL)) abort();
        while (!callback_blocked && !callback_completed) {
            if (pthread_cond_wait(&callback_condition, &callback_gate)) abort();
        }
        if (pthread_mutex_unlock(&callback_gate)) abort();
    }
    struct os_mbuf *om = malloc(sizeof(*om));
    if (!om || length > sizeof(om->data)) abort();
    memcpy(om->data, data, length); om->len = length; return om;
}
int ble_gatts_notify_custom(uint16_t handle, uint16_t attribute, struct os_mbuf *om)
{
    (void)handle; (void)attribute;
    if (critical_depth) abort();
    /* Pinned NimBLE calls NOTIFY_TX synchronously from notify_custom. Exercise
     * the actual application callback while the submission mutex is held. */
    struct ble_gap_event event = {.type = BLE_GAP_EVENT_NOTIFY_TX};
    (void)gap_event_cb(&event, NULL);
    ++notify_calls;
    if (is_case("retry_reconnect") && !triggered) { free(om); return BLE_HS_EBUSY; }
    if (command_processing && ble_session_id() != original_session) ++new_link_notifications;
    size_t used = strlen(notifications);
    if (used + om->len >= sizeof(notifications)) abort();
    memcpy(notifications + used, om->data, om->len);
    notifications[used + om->len] = '\0';
    free(om); return 0;
}
void vTaskDelay(unsigned ticks)
{
    if (critical_depth || tx_locked) abort();
    clock_now += (int64_t)ticks * 1000;
    if (!triggered && ((is_case("reconnect_after_config_ack") &&
        strstr(notifications, "$CMD:wifi_config_received\n")) ||
        (is_case("reconnect_after_mac") && strstr(notifications, "$ESP_MAC:AB:AB:AB:AB:AB:AB\n")) ||
        (is_case("reconnect_after_name") && strstr(notifications, "$ESP_NAME:" WIFI_HOSTNAME "\n")) ||
        (is_case("reconnect_during_chunks") && notify_calls > 0) || is_case("retry_reconnect"))) {
        triggered = true; host_reconnect();
    }
    if (ticks == MAIN_POLL_INTERVAL_MS) longjmp(finished, 1);
}
bool camera_is_ready(void) { return camera_ready; }
esp_err_t camera_set_udp_mode(bool udp) { (void)udp; return ESP_OK; }
esp_err_t camera_set_udp_profile(framesize_t size, int quality)
{ (void)size; (void)quality; return ESP_OK; }
camera_fb_t *camera_capture(void)
{
    if (!triggered && is_case("reconnect_before_capture")) { triggered = true; host_reconnect(); }
    return &host_fb;
}
void camera_release(camera_fb_t *captured) { (void)captured; }
size_t camera_psram_bytes(void) { return 0; }
bool flashlight_is_on(void) { return flash_on; }
esp_err_t flashlight_set(bool on)
{
    if (on) ++flash_on_calls;
    flash_on = on;
    if (!triggered && (is_case("reconnect_before_ack") || is_case("reconnect_before_error"))) {
        triggered = true; host_reconnect();
        if (is_case("reconnect_before_error")) return ESP_FAIL;
    }
    return ESP_OK;
}
void esp_restart(void) { abort(); }
esp_err_t esp_read_mac(uint8_t *mac, int kind)
{ (void)kind; memset(mac, 0xab, 6); return ESP_OK; }
#define ESP_MAC_WIFI_STA 0
size_t heap_caps_get_free_size(unsigned caps) { (void)caps; return 0; }
size_t heap_caps_get_minimum_free_size(unsigned caps) { (void)caps; return 0; }
bool sensors_available(void) { return false; }
esp_err_t sensors_read_uv_ir(as7265x_reading_t *reading)
{ reading->available = false; return ESP_ERR_INVALID_STATE; }
esp_err_t wifi_save_credentials(const firmware_wifi_credentials_t *credentials)
{
    (void)credentials; ++save_calls;
    if (!triggered && is_case("reconnect_before_config_ack")) {
        triggered = true; host_reconnect();
    }
    return ESP_OK;
}
esp_err_t wifi_erase_credentials(void) { return ESP_OK; }
esp_err_t wifi_start_station(const firmware_wifi_credentials_t *credentials)
{ (void)credentials; return ESP_OK; }
esp_err_t wifi_stop_station(void) { return ESP_OK; }
void wifi_maintain(void) {}
bool wifi_is_connected(void) { return false; }
int wifi_rssi_dbm(void) { return -65; }
const char *wifi_status_string(void) { return "disconnected"; }
void wifi_local_ip_str(char *buffer, size_t capacity)
{
    (void)snprintf(buffer, capacity, "0.0.0.0");
    if (!triggered && is_case("reconnect_before_status")) { triggered = true; host_reconnect(); }
}
void udp_stream_stop(void) { ++resets; }
esp_err_t udp_stream_start(void) { return ESP_OK; }
bool udp_stream_has_peer(void) { return false; }
bool udp_stream_send_frame(const uint8_t *data, size_t length, uint32_t packet_pace_ms)
{ (void)data; (void)length; (void)packet_pace_ms; return false; }
bool udp_stream_send_control(const uint8_t *data, size_t length)
{ (void)data; (void)length; return true; }
bool udp_stream_receive_command(firmware_command_t *out) { (void)out; return false; }

#define TAG BLE_TAG
/* ACTUAL_BLE_STATE */
/* ACTUAL_BLE_SEND */
static void ble_advertise(void) { (void)s_own_addr_type; }
#undef TAG
#define TAG MAIN_TAG
/* ACTUAL_MAIN */
#undef TAG

void host_enter(portMUX_TYPE *lock)
{ (void)lock; if (pthread_mutex_lock(&critical_mutex)) abort(); ++critical_depth; }
void host_exit(portMUX_TYPE *lock)
{
    (void)lock;
    if (!critical_depth) abort();
    --critical_depth;
    if (pthread_mutex_unlock(&critical_mutex)) abort();
    if (awaiting_dequeue && !critical_depth) {
        awaiting_dequeue = false; triggered = true; host_reconnect();
    }
}
void host_connect(void)
{
    struct ble_gap_event event = {.type = BLE_GAP_EVENT_CONNECT};
    event.connect.conn_handle = 7;
    (void)gap_event_cb(&event, NULL);
    event.type = BLE_GAP_EVENT_SUBSCRIBE;
    event.subscribe.attr_handle = s_tx_handle;
    event.subscribe.conn_handle = 7;
    event.subscribe.cur_notify = 1;
    (void)gap_event_cb(&event, NULL);
}
void host_reconnect(void)
{
    struct ble_gap_event event = {.type = BLE_GAP_EVENT_DISCONNECT};
    (void)gap_event_cb(&event, NULL);
    host_connect();
}
void *host_reconnect_thread(void *arg)
{
    (void)arg;
    /* The creator publishes the pthread id before releasing this gate. */
    if (pthread_mutex_lock(&callback_gate)) abort();
    if (pthread_mutex_unlock(&callback_gate)) abort();
    host_reconnect();
    if (pthread_mutex_lock(&callback_gate)) abort();
    callback_completed = true;
    if (pthread_cond_signal(&callback_condition)) abort();
    if (pthread_mutex_unlock(&callback_gate)) abort();
    return NULL;
}
int host_write(uint8_t code)
{
    struct os_mbuf om = {.len = 1};
    om.data[0] = code;
    if (code == CMD_BLE_PAIR) {
        memcpy(om.data + 1, BLE_PAIRING_CODE, BLE_PAIRING_CODE_LEN);
        om.len = 1 + BLE_PAIRING_CODE_LEN;
    } else if (code == CMD_WIFI_CONFIG_PUT) {
        static const char payload[] = "host-test\0synthetic-pass\0";
        memcpy(om.data + 1, payload, sizeof(payload) - 1);
        om.len = (uint16_t)sizeof(payload);
    }
    struct ble_gatt_access_ctxt access = {.op = BLE_GATT_ACCESS_OP_WRITE_CHR, .om = &om};
    return gatt_svr_chr_access(7, 0, &access, NULL);
}
void host_queue(uint8_t code) { if (host_write(code) != 0) abort(); }
static void expect(bool condition, const char *reason)
{
    if (!condition) {
        fprintf(stderr, "%s: app_session=%" PRIu32 " link_session=%" PRIu32
            " stream=%d flash=%d on_calls=%u resets=%u new_notifications=%u notify=%u text=%s\n",
            reason, s_app.ble_session, ble_session_id(), s_app.streaming, flash_on,
            flash_on_calls, resets, new_link_notifications, notify_calls, notifications);
        exit(EXIT_FAILURE);
    }
}
int main(int argc, char **argv)
{
    if (argc != 2) return EXIT_FAILURE;
    scenario = argv[1];
    s_commands = queue_storage;
    queue_item_size = sizeof(ble_command_t);
    s_tx_handle = 1;
    s_tx_lock = &notification_mutex;
    if (is_case("recovery_delayed")) {
        clock_now = 1000000;
        maintain_ble_recovery(false);
        expect(ble_init_calls == 0 && !s_app.ble_started,
               "BLE recovery must not start before its delay");
        clock_now += (int64_t)(WIFI_BLE_RECOVERY_DELAY_MS - 1U) * 1000LL;
        maintain_ble_recovery(false);
        expect(ble_init_calls == 0 && !s_app.ble_started,
               "BLE recovery remains delayed until the threshold");
        clock_now += 1000;
        maintain_ble_recovery(false);
        expect(ble_init_calls == 1 && s_app.ble_started,
               "BLE commissioning starts at the WiFi outage threshold");
        maintain_ble_recovery(false);
        expect(ble_init_calls == 1,
               "successful BLE recovery is not initialized twice");
        return EXIT_SUCCESS;
    }
    if (is_case("recovery_wifi_reset")) {
        clock_now = 1000000;
        maintain_ble_recovery(false);
        clock_now += (int64_t)(WIFI_BLE_RECOVERY_DELAY_MS - 1U) * 1000LL;
        maintain_ble_recovery(true);
        clock_now += 1000;
        maintain_ble_recovery(false);
        clock_now += (int64_t)(WIFI_BLE_RECOVERY_DELAY_MS - 1U) * 1000LL;
        maintain_ble_recovery(false);
        expect(ble_init_calls == 0,
               "a recovered WiFi link resets the offline recovery timer");
        clock_now += 1000;
        maintain_ble_recovery(false);
        expect(ble_init_calls == 1 && s_app.ble_started,
               "fresh WiFi outage reaches BLE recovery threshold");
        return EXIT_SUCCESS;
    }
    if (is_case("recovery_init_retry")) {
        clock_now = 1000000;
        ble_init_result = ESP_FAIL;
        maintain_ble_recovery(false);
        clock_now += (int64_t)WIFI_BLE_RECOVERY_DELAY_MS * 1000LL;
        maintain_ble_recovery(false);
        expect(ble_init_calls == 1 && !s_app.ble_started,
               "failed BLE initialization is recorded without claiming success");
        clock_now += (int64_t)(WIFI_RETRY_INTERVAL_MS - 1U) * 1000LL;
        maintain_ble_recovery(false);
        expect(ble_init_calls == 1,
               "failed BLE initialization uses a bounded retry interval");
        clock_now += 1000;
        ble_init_result = ESP_OK;
        maintain_ble_recovery(false);
        expect(ble_init_calls == 2 && s_app.ble_started,
               "BLE recovery retries and succeeds after transient init failure");
        return EXIT_SUCCESS;
    }
    host_connect();
    original_session = ble_session_id();
    s_app.ble_started = true;
    s_app.ble_session = original_session;
    s_app.ble_notify_enabled = true;
    s_app.standby = true;
    if (is_case("new_stream_during_drain") || is_case("new_flash_during_drain")) {
        flash_on = true;
    } else if (is_case("stale_queue")) {
        host_queue(CMD_FLASH_ON); host_reconnect();
    } else if (is_case("pairing_is_scoped")) {
        expect(host_write(CMD_WIFI_CONFIG_PUT) == BLE_ATT_ERR_VALUE_NOT_ALLOWED, "unpaired config rejected");
        host_queue(CMD_BLE_PAIR);
        expect(ble_is_paired(), "pair authorizes current session");
        host_reconnect();
        expect(!ble_is_paired() && host_write(CMD_REBOOT) == BLE_ATT_ERR_VALUE_NOT_ALLOWED,
               "new connection must not inherit authorization");
        return EXIT_SUCCESS;
    } else if (is_case("reconnect_during_chunks") || is_case("reconnect_at_mbuf_allocation") ||
               is_case("retry_reconnect")) {
        uint8_t data[BLE_ATT_MTU_DFLT * 2] = {0};
        command_processing = true;
        memset(data, 'x', sizeof(data));
        esp_err_t result = ble_send_bytes(data, sizeof(data));
        expect(result != ESP_OK && new_link_notifications == 0,
               "old notification tail must not cross connection identity");
        if (is_case("reconnect_at_mbuf_allocation")) {
            expect(callback_blocked && callback_completed && !thread_started,
                   "actual reset callback must wait until notification submission unlocks");
        }
        return EXIT_SUCCESS;
    } else if (is_case("reconnect_before_status")) {
        host_queue(CMD_CONNECTION_STATUS);
    } else if (is_case("config_responses") || is_case("reconnect_before_config_ack") ||
               is_case("reconnect_after_config_ack") || is_case("reconnect_after_mac") ||
               is_case("reconnect_after_name")) {
        host_queue(CMD_BLE_PAIR); host_queue(CMD_WIFI_CONFIG_PUT);
        /* Drain pairing first so the reconnect hook targets config responses. */
        triggered = true;
        if (setjmp(finished) == 0) run_application();
        triggered = false;
        if (!is_case("config_responses")) {
            queue_head = queue_tail = 0;
            notifications[0] = '\0'; notify_calls = 0;
            host_queue(CMD_WIFI_CONFIG_PUT);
        }
    } else if (is_case("reconnect_before_capture")) {
        host_queue(CMD_STREAM_ON);
    } else {
        host_queue(CMD_FLASH_ON);
    }
    if (setjmp(finished) == 0) run_application();
    if (is_case("new_stream_during_drain")) {
        expect(s_app.ble_session == ble_session_id() && !s_app.streaming && resets == 1,
               "new session must be reconciled before rejecting BLE stream_on");
        expect(strstr(notifications, "$ERROR:VIDEO_AND_RUNTIME_COMMANDS_REQUIRE_UDP\n") != NULL,
               "BLE stream command must receive an explicit UDP-required error");
        if (setjmp(finished) == 0) run_application();
        expect(!s_app.streaming && resets == 1,
               "next iteration must not turn a BLE stream command into capture");
    } else if (is_case("new_flash_during_drain")) {
        expect(s_app.ble_session == ble_session_id() && flash_on && resets == 1,
               "new session reset must precede flash_on, not erase it later");
        if (setjmp(finished) == 0) run_application();
        expect(flash_on && resets == 1, "next iteration preserves new-session flashlight");
    } else if (is_case("stale_at_execution") || is_case("stale_queue")) {
        expect(flash_on_calls == 0, "closed command must not execute GPIO");
    } else if (is_case("config_responses")) {
        expect(save_calls == 1 && strstr(notifications, "$CMD:wifi_config_received\n") &&
               strstr(notifications, "$ESP_MAC:AB:AB:AB:AB:AB:AB\n") &&
               strstr(notifications, "$ESP_NAME:" WIFI_HOSTNAME "\n") &&
               strstr(notifications, "$WIFI_CFG:ssid=host-test\n"), "existing config byte protocol");
    } else if (is_case("reconnect_before_capture")) {
        expect(s_app.frames_sent == 0 && !strstr(notifications, "\xff\xd8"),
               "captured old-session JPEG cannot start sending on replacement connection");
    } else {
        expect(new_link_notifications == 0, "command responses must remain bound to source session");
        if (is_case("reconnect_after_config_ack")) {
            expect(strstr(notifications, "$CMD:wifi_config_received\n") &&
                   !strstr(notifications, "$ESP_MAC:"), "only old-session config ACK may survive");
        } else if (is_case("reconnect_after_mac")) {
            expect(strstr(notifications, "$ESP_MAC:AB:AB:AB:AB:AB:AB\n") &&
                   !strstr(notifications, "$ESP_NAME:"), "name/config must not cross session after MAC");
        } else if (is_case("reconnect_after_name")) {
            expect(strstr(notifications, "$ESP_NAME:" WIFI_HOSTNAME "\n") &&
                   !strstr(notifications, "$WIFI_CFG:"), "config getter must not cross session after name");
        }
    }
    return EXIT_SUCCESS;
}
