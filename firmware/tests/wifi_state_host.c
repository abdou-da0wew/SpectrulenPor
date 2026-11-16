#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wifi.h"

typedef int portMUX_TYPE;
typedef const char *esp_event_base_t;
typedef void *esp_event_handler_instance_t;
typedef unsigned nvs_handle_t;
typedef struct { int unused; } wifi_init_config_t;
typedef struct {
    struct { uint8_t ssid[32], password[64]; int scan_method;
        struct { int rssi, authmode; } threshold;
        struct { bool required; } pmf_cfg;
    } sta;
} wifi_config_t;
typedef struct { unsigned reason; } wifi_event_sta_disconnected_t;
typedef struct { esp_netif_t *esp_netif; struct { esp_ip4_addr_t ip; } ip_info; } ip_event_got_ip_t;
enum { WIFI_EVENT_STA_CONNECTED, WIFI_EVENT_STA_DISCONNECTED, WIFI_EVENT_STA_START,
       WIFI_EVENT_STA_STOP, IP_EVENT_STA_GOT_IP, IP_EVENT_STA_LOST_IP,
       ESP_EVENT_ANY_ID, WIFI_STORAGE_RAM, WIFI_MODE_STA, WIFI_ALL_CHANNEL_SCAN,
       WIFI_AUTH_OPEN, WIFI_AUTH_WPA_PSK, WIFI_IF_STA, WIFI_PS_NONE,
       NVS_READONLY, NVS_READWRITE };
static const char wifi_events[] = "WIFI", ip_events[] = "IP";
#define WIFI_EVENT wifi_events
#define IP_EVENT ip_events
#define WIFI_INIT_CONFIG_DEFAULT() ((wifi_init_config_t){0})
#define portMUX_INITIALIZER_UNLOCKED 0
#define portENTER_CRITICAL(lock) host_enter(lock)
#define portEXIT_CRITICAL(lock) host_exit(lock)
static const char *scenario;
static bool hook_got_ip, defer_events;
static unsigned critical_depth, connect_calls, disconnect_calls, stop_calls, nvs_calls;
static int64_t clock_now;
static esp_netif_t host_netif;
static esp_err_t disconnect_result = ESP_OK;
static void (*registered_handler)(void *, esp_event_base_t, int32_t, void *);
void host_enter(portMUX_TYPE *lock) { (void)lock; ++critical_depth; }
void host_exit(portMUX_TYPE *lock)
{ (void)lock; if (!critical_depth) abort(); --critical_depth; }
bool is_case(const char *name) { return strcmp(scenario, name) == 0; }
void emit(esp_event_base_t base, int32_t event);
void assert_unlocked(void) { if (critical_depth) abort(); }
int64_t esp_timer_get_time(void)
{
    if (hook_got_ip) { hook_got_ip = false; emit(IP_EVENT, IP_EVENT_STA_GOT_IP); }
    return clock_now;
}
void host_log(const char *tag, const char *format, ...) { (void)tag; (void)format; }
#define ESP_LOGI(tag, ...) host_log(tag, __VA_ARGS__)
#define ESP_LOGW(tag, ...) host_log(tag, __VA_ARGS__)
#define ESP_LOGE(tag, ...) host_log(tag, __VA_ARGS__)
const char *esp_err_to_name(esp_err_t error) { (void)error; return "host-error"; }
esp_netif_t *esp_netif_create_default_wifi_sta(void) { return &host_netif; }
void esp_netif_destroy_default_wifi(esp_netif_t *netif) { (void)netif; }
esp_err_t esp_netif_set_hostname(esp_netif_t *netif, const char *hostname)
{ (void)netif; (void)hostname; assert_unlocked(); return ESP_OK; }
esp_err_t esp_netif_dhcpc_start(esp_netif_t *netif)
{ (void)netif; assert_unlocked(); return ESP_OK; }
esp_err_t esp_wifi_init(const wifi_init_config_t *config)
{ (void)config; assert_unlocked(); return ESP_OK; }
esp_err_t esp_wifi_deinit(void) { assert_unlocked(); return ESP_OK; }
esp_err_t esp_wifi_set_storage(int storage) { (void)storage; assert_unlocked(); return ESP_OK; }
esp_err_t esp_wifi_set_mode(int mode) { (void)mode; assert_unlocked(); return ESP_OK; }
esp_err_t esp_wifi_set_ps(int mode) { (void)mode; assert_unlocked(); return ESP_OK; }
esp_err_t esp_wifi_set_config(int interface, const wifi_config_t *config)
{ (void)interface; (void)config; assert_unlocked(); return ESP_OK; }
esp_err_t esp_event_handler_instance_register(esp_event_base_t base, int32_t event,
    void (*handler)(void *, esp_event_base_t, int32_t, void *), void *arg,
    esp_event_handler_instance_t *instance)
{
    (void)base; (void)event; (void)arg; registered_handler = handler;
    *instance = &host_netif; return ESP_OK;
}
esp_err_t esp_event_handler_instance_unregister(esp_event_base_t base, int32_t event,
    esp_event_handler_instance_t instance)
{ (void)base; (void)event; (void)instance; return ESP_OK; }
esp_err_t esp_wifi_start(void)
{
    assert_unlocked();
    if (!defer_events) emit(WIFI_EVENT, WIFI_EVENT_STA_START);
    return ESP_OK;
}
esp_err_t esp_wifi_stop(void)
{
    assert_unlocked(); ++stop_calls;
    if (!defer_events) emit(WIFI_EVENT, WIFI_EVENT_STA_STOP);
    return ESP_OK;
}
esp_err_t esp_wifi_connect(void)
{
    assert_unlocked(); ++connect_calls;
    if (!is_case("got_ip_without_association")) emit(WIFI_EVENT, WIFI_EVENT_STA_CONNECTED);
    if (is_case("connect_return_after_success")) {
        emit(IP_EVENT, IP_EVENT_STA_GOT_IP); return ESP_FAIL;
    }
    return ESP_OK;
}
esp_err_t esp_wifi_disconnect(void)
{
    assert_unlocked(); ++disconnect_calls;
    if (is_case("got_ip_during_timeout_disconnect")) emit(IP_EVENT, IP_EVENT_STA_GOT_IP);
    if (is_case("disconnect_failure_lost_ip")) emit(IP_EVENT, IP_EVENT_STA_LOST_IP);
    if (!defer_events && disconnect_result == ESP_OK) emit(WIFI_EVENT, WIFI_EVENT_STA_DISCONNECTED);
    return disconnect_result;
}
esp_err_t nvs_open(const char *space, int mode, nvs_handle_t *handle)
{ (void)space; (void)mode; (void)handle; ++nvs_calls; return ESP_ERR_NVS_NOT_FOUND; }
esp_err_t nvs_get_blob(nvs_handle_t handle, const char *key, void *data, size_t *size)
{ (void)handle; (void)key; (void)data; (void)size; ++nvs_calls; return ESP_FAIL; }
void nvs_close(nvs_handle_t handle) { (void)handle; ++nvs_calls; }
esp_err_t nvs_set_blob(nvs_handle_t handle, const char *key, const void *data, size_t size)
{ (void)handle; (void)key; (void)data; (void)size; ++nvs_calls; return ESP_FAIL; }
esp_err_t nvs_commit(nvs_handle_t handle) { (void)handle; ++nvs_calls; return ESP_FAIL; }
esp_err_t nvs_erase_key(nvs_handle_t handle, const char *key)
{ (void)handle; (void)key; ++nvs_calls; return ESP_FAIL; }

/* ACTUAL_WIFI */

void emit(esp_event_base_t base, int32_t event)
{
    wifi_event_sta_disconnected_t disconnected = {.reason = 201};
    ip_event_got_ip_t got_ip = {.esp_netif = &host_netif, .ip_info = {{0x0100007fU}}};
    registered_handler(NULL, base, event,
        base == IP_EVENT ? (void *)&got_ip : (void *)&disconnected);
}
static void expect(bool condition, const char *reason)
{
    if (!condition) {
        fprintf(stderr, "%s: started=%d connecting=%d has_ip=%d associated=%d attempts=%u"
            " connects=%u disconnects=%u stops=%u status=%s\n", reason,
            s_state.started, s_state.connecting, s_state.has_ip, s_state.associated,
            s_state.attempts, connect_calls, disconnect_calls, stop_calls, wifi_status_string());
        exit(EXIT_FAILURE);
    }
}
static void advance_retry(void) { clock_now += WIFI_RETRY_INTERVAL_MS * 1000LL; }
int main(int argc, char **argv)
{
    if (argc != 2) return EXIT_FAILURE;
    scenario = argv[1];
    firmware_wifi_credentials_t credentials = {.ssid = "host-test", .password = "synthetic-pass"};
    expect(wifi_start_station(&credentials) == ESP_OK, "station start");
    wifi_maintain();
    expect(connect_calls == 1, "first attempt starts once");
    if (is_case("got_ip_before_timeout")) {
        clock_now += WIFI_CONNECT_TIMEOUT_MS * 1000LL;
        hook_got_ip = true;
        wifi_maintain();
        expect(wifi_is_connected() && disconnect_calls == 0,
               "GOT_IP accepted before timeout claim must not be disconnected");
    } else if (is_case("got_ip_during_timeout_disconnect")) {
        clock_now += WIFI_CONNECT_TIMEOUT_MS * 1000LL;
        wifi_maintain();
        expect(!wifi_is_connected() && s_state.attempts == 1,
               "timeout winner must reject late GOT_IP without resetting attempts");
    } else if (is_case("got_ip_after_disconnect")) {
        emit(WIFI_EVENT, WIFI_EVENT_STA_DISCONNECTED);
        emit(IP_EVENT, IP_EVENT_STA_GOT_IP);
        expect(!wifi_is_connected() && s_state.attempts == 1, "disconnected attempt cannot accept IP");
    } else if (is_case("got_ip_after_stop")) {
        expect(wifi_stop_station() == ESP_OK, "stop station");
        emit(IP_EVENT, IP_EVENT_STA_GOT_IP);
        expect(!wifi_is_connected() && s_state.attempts == 1, "stopped IP must not reset attempts");
    } else if (is_case("got_ip_without_association")) {
        emit(IP_EVENT, IP_EVENT_STA_GOT_IP);
        expect(!wifi_is_connected() && s_state.attempts == 1, "IP needs current association");
    } else if (is_case("restart_event_order")) {
        defer_events = true;
        expect(wifi_start_station(&credentials) == ESP_OK, "restart station");
        emit(WIFI_EVENT, WIFI_EVENT_STA_STOP);
        emit(IP_EVENT, IP_EVENT_STA_GOT_IP);
        wifi_maintain();
        expect(connect_calls == 1 && !wifi_is_connected(), "restart must await driver START");
        emit(WIFI_EVENT, WIFI_EVENT_STA_START);
        wifi_maintain();
        expect(connect_calls == 2, "new driver START permits current attempt");
        emit(IP_EVENT, IP_EVENT_STA_GOT_IP);
        expect(wifi_is_connected(), "current restarted association accepts IP");
    } else if (is_case("timeout_disconnect_order")) {
        defer_events = true;
        clock_now += WIFI_CONNECT_TIMEOUT_MS * 1000LL;
        wifi_maintain(); advance_retry(); wifi_maintain();
        expect(connect_calls == 1, "timeout must await disconnect before retry");
        emit(WIFI_EVENT, WIFI_EVENT_STA_DISCONNECTED);
        emit(IP_EVENT, IP_EVENT_STA_GOT_IP);
        expect(!wifi_is_connected(), "old post-disconnect IP rejected");
        advance_retry(); wifi_maintain();
        expect(connect_calls == 2, "retry proceeds after current disconnect and interval");
    } else if (is_case("twenty_attempts")) {
        for (unsigned i = 1; i < WIFI_MAX_RETRIES; ++i) {
            emit(WIFI_EVENT, WIFI_EVENT_STA_DISCONNECTED);
            advance_retry(); wifi_maintain();
        }
        emit(WIFI_EVENT, WIFI_EVENT_STA_DISCONNECTED);
        advance_retry(); wifi_maintain();
        expect(connect_calls == WIFI_MAX_RETRIES && strcmp(wifi_status_string(), "failed") == 0 &&
               nvs_calls == 0, "exact attempt exhaustion preserves credentials and mode");
    } else if (is_case("success_then_disconnect")) {
        emit(IP_EVENT, IP_EVENT_STA_GOT_IP);
        expect(wifi_is_connected() && s_state.attempts == 0, "success resets attempts");
        emit(WIFI_EVENT, WIFI_EVENT_STA_DISCONNECTED);
        advance_retry(); wifi_maintain();
        expect(connect_calls == 2 && s_state.attempts == 1, "lost connection starts new retry budget");
    } else if (is_case("connect_return_after_success")) {
        expect(wifi_is_connected() && s_state.attempts == 0 && !s_state.connecting,
               "connect return must not overwrite handler success");
    } else if (is_case("stopped")) {
        expect(wifi_stop_station() == ESP_OK, "stop station");
        clock_now += WIFI_CONNECT_TIMEOUT_MS * 1000LL;
        wifi_maintain();
        expect(connect_calls == 1 && disconnect_calls == 0, "stopped maintenance is inert");
    } else if (is_case("disconnect_failure") || is_case("disconnect_failure_lost_ip")) {
        disconnect_result = ESP_FAIL;
        clock_now += WIFI_CONNECT_TIMEOUT_MS * 1000LL;
        wifi_maintain();
        emit(IP_EVENT, IP_EVENT_STA_GOT_IP);
        expect(!wifi_is_connected() && disconnect_calls == 1, "failed disconnect cannot accept late IP");
        advance_retry(); wifi_maintain();
        expect(connect_calls == 2, "failed driver disconnect cannot leave retry permanently blocked");
    } else return EXIT_FAILURE;
    return EXIT_SUCCESS;
}
