#include <string.h>
#include <stdio.h>
#include "esp_log.h"
#include "esp_wifi.h"
#include "esp_wifi_default.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "wifi.h"
#include "protocol.h"
#include "config.h"

static const char *TAG = WIFI_TAG;

static esp_netif_t *s_sta_netif = NULL;
static bool s_initialized = false;

static esp_ip_addr_t s_app_ip;
static esp_event_handler_instance_t s_wifi_handler;
static esp_event_handler_instance_t s_ip_handler;

typedef struct {
    bool started;
    bool driver_started;
    bool connecting;
    bool disconnecting;
    bool has_ip;
    bool associated;
    uint32_t generation;
    unsigned attempts;
    int64_t last_attempt;
    esp_ip4_addr_t ip;
} wifi_state_t;

static wifi_state_t s_state;
static portMUX_TYPE s_state_lock = portMUX_INITIALIZER_UNLOCKED;

static wifi_state_t state_snapshot(void)
{
    portENTER_CRITICAL(&s_state_lock);
    wifi_state_t state = s_state;
    portEXIT_CRITICAL(&s_state_lock);
    return state;
}

static void wifi_event_handler(void *arg, esp_event_base_t event_base,
                               int32_t event_id, void *event_data)
{
    (void)arg;
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        portENTER_CRITICAL(&s_state_lock);
        s_state.driver_started = s_state.started;
        portEXIT_CRITICAL(&s_state_lock);
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_STOP) {
        portENTER_CRITICAL(&s_state_lock);
        s_state.driver_started = false;
        s_state.connecting = false;
        s_state.disconnecting = false;
        s_state.has_ip = false;
        s_state.associated = false;
        ++s_state.generation;
        portEXIT_CRITICAL(&s_state_lock);
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_CONNECTED) {
        portENTER_CRITICAL(&s_state_lock);
        bool accepted = s_state.started && s_state.driver_started &&
            !s_state.disconnecting && (s_state.connecting || s_state.has_ip);
        if (accepted) {
            s_state.associated = true;
        }
        portEXIT_CRITICAL(&s_state_lock);
        if (accepted) {
            esp_netif_dhcpc_start(s_sta_netif);
        }
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        const wifi_event_sta_disconnected_t *event = event_data;
        portENTER_CRITICAL(&s_state_lock);
        s_state.has_ip = false;
        s_state.associated = false;
        s_state.connecting = false;
        s_state.disconnecting = false;
        s_state.last_attempt = esp_timer_get_time();
        ++s_state.generation;
        portEXIT_CRITICAL(&s_state_lock);
        ESP_LOGW(TAG, "operation=wifi.disconnect reason=%u", event->reason);
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        const ip_event_got_ip_t *event = event_data;
        portENTER_CRITICAL(&s_state_lock);
        bool accepted = event->esp_netif == s_sta_netif && s_state.started &&
            s_state.driver_started && s_state.associated && !s_state.disconnecting;
        if (accepted) {
            s_state.ip = event->ip_info.ip;
            s_state.has_ip = true;
            s_state.connecting = false;
            s_state.attempts = 0;
            ++s_state.generation;
        }
        portEXIT_CRITICAL(&s_state_lock);
        if (accepted) {
            ESP_LOGI(TAG, "operation=wifi.got_ip ip=" IPSTR " outcome=success",
                     IP2STR(&event->ip_info.ip));
        }
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_LOST_IP) {
        portENTER_CRITICAL(&s_state_lock);
        if (s_state.has_ip) {
            s_state.has_ip = false;
            ++s_state.generation;
        }
        portEXIT_CRITICAL(&s_state_lock);
    }
}

static esp_err_t initialize_station(void)
{
    if (s_initialized) {
        return ESP_OK;
    }
    s_sta_netif = esp_netif_create_default_wifi_sta();
    if (s_sta_netif == NULL) {
        return ESP_ERR_NO_MEM;
    }
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    esp_err_t ret = esp_wifi_init(&cfg);
    if (ret != ESP_OK) {
        esp_netif_destroy_default_wifi(s_sta_netif);
        s_sta_netif = NULL;
        return ret;
    }
    ret = esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                              wifi_event_handler, NULL, &s_wifi_handler);
    if (ret == ESP_OK) {
        ret = esp_event_handler_instance_register(IP_EVENT, ESP_EVENT_ANY_ID,
                                                  wifi_event_handler, NULL, &s_ip_handler);
    }
    if (ret == ESP_OK) {
        ret = esp_wifi_set_storage(WIFI_STORAGE_RAM);
    }
    if (ret == ESP_OK) {
        ret = esp_wifi_set_mode(WIFI_MODE_STA);
    }
    if (ret == ESP_OK) {
        ret = esp_netif_set_hostname(s_sta_netif, WIFI_HOSTNAME);
    }
    if (ret != ESP_OK) {
        if (s_wifi_handler != NULL) {
            esp_event_handler_instance_unregister(WIFI_EVENT, ESP_EVENT_ANY_ID, s_wifi_handler);
            s_wifi_handler = NULL;
        }
        if (s_ip_handler != NULL) {
            esp_event_handler_instance_unregister(IP_EVENT, ESP_EVENT_ANY_ID, s_ip_handler);
            s_ip_handler = NULL;
        }
        esp_wifi_deinit();
        esp_netif_destroy_default_wifi(s_sta_netif);
        s_sta_netif = NULL;
        return ret;
    }
    s_initialized = true;
    return ESP_OK;
}

esp_err_t wifi_load_credentials(firmware_wifi_credentials_t *out)
{
    if (out == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    memset(out, 0, sizeof(*out));
    nvs_handle_t handle;
    esp_err_t ret = nvs_open(WIFI_NVS_NAMESPACE, NVS_READONLY, &handle);
    if (ret != ESP_OK) {
        return ret;
    }
    size_t size = sizeof(*out);
    ret = nvs_get_blob(handle, WIFI_NVS_KEY_SSID, out, &size);
    nvs_close(handle);
    if (ret == ESP_OK &&
        (size != sizeof(*out) || !protocol_wifi_credentials_valid(out))) {
        ret = ESP_ERR_INVALID_STATE;
    }
    if (ret != ESP_OK) {
        memset(out, 0, sizeof(*out));
    }
    return ret;
}

esp_err_t wifi_save_credentials(const firmware_wifi_credentials_t *credentials)
{
    if (!protocol_wifi_credentials_valid(credentials)) {
        return ESP_ERR_INVALID_ARG;
    }
    nvs_handle_t handle;
    esp_err_t ret = nvs_open(WIFI_NVS_NAMESPACE, NVS_READWRITE, &handle);
    if (ret != ESP_OK) {
        return ret;
    }
    ret = nvs_set_blob(handle, WIFI_NVS_KEY_SSID, credentials, sizeof(*credentials));
    if (ret == ESP_OK) {
        ret = nvs_commit(handle);
    }
    nvs_close(handle);
    return ret;
}

esp_err_t wifi_erase_credentials(void)
{
    nvs_handle_t handle;
    esp_err_t ret = nvs_open(WIFI_NVS_NAMESPACE, NVS_READWRITE, &handle);
    if (ret != ESP_OK) {
        return ret;
    }
    ret = nvs_erase_key(handle, WIFI_NVS_KEY_SSID);
    if (ret == ESP_OK || ret == ESP_ERR_NVS_NOT_FOUND) {
        ret = nvs_commit(handle);
    }
    nvs_close(handle);
    return ret;
}

esp_err_t wifi_stop_station(void)
{
    portENTER_CRITICAL(&s_state_lock);
    if (!s_state.started) {
        portEXIT_CRITICAL(&s_state_lock);
        return ESP_OK;
    }
    s_state.started = false;
    s_state.driver_started = false;
    s_state.connecting = false;
    s_state.disconnecting = false;
    s_state.has_ip = false;
    s_state.associated = false;
    ++s_state.generation;
    portEXIT_CRITICAL(&s_state_lock);
    return esp_wifi_stop();
}

esp_err_t wifi_start_station(const firmware_wifi_credentials_t *credentials)
{
    if (!protocol_wifi_credentials_valid(credentials)) {
        return ESP_ERR_INVALID_ARG;
    }
    esp_err_t ret = initialize_station();
    if (ret == ESP_OK) {
        ret = wifi_stop_station();
    }
    if (ret != ESP_OK) {
        return ret;
    }
    wifi_config_t config = {0};
    memcpy(config.sta.ssid, credentials->ssid, strlen(credentials->ssid));
    memcpy(config.sta.password, credentials->password, strlen(credentials->password));
    config.sta.scan_method = WIFI_ALL_CHANNEL_SCAN;
    config.sta.threshold.rssi = WIFI_MIN_RSSI_DBM;
    config.sta.threshold.authmode = credentials->password[0] == '\0'
        ? WIFI_AUTH_OPEN : WIFI_AUTH_WPA_PSK;
    config.sta.pmf_cfg.required = false;
    ret = esp_wifi_set_config(WIFI_IF_STA, &config);
    if (ret != ESP_OK) {
        return ret;
    }
    portENTER_CRITICAL(&s_state_lock);
    uint32_t generation = s_state.generation + 1U;
    s_state = (wifi_state_t){
        .started = true,
        .generation = generation,
        .last_attempt = esp_timer_get_time() - WIFI_RETRY_INTERVAL_MS * 1000LL,
    };
    portEXIT_CRITICAL(&s_state_lock);
    ret = esp_wifi_start();
    if (ret != ESP_OK) {
        portENTER_CRITICAL(&s_state_lock);
        s_state.started = false;
        s_state.driver_started = false;
        s_state.connecting = false;
        s_state.associated = false;
        s_state.has_ip = false;
        ++s_state.generation;
        portEXIT_CRITICAL(&s_state_lock);
        return ret;
    }
    ret = esp_wifi_set_ps(WIFI_PS_NONE);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "operation=wifi.power_save code=%s", esp_err_to_name(ret));
    }
    ret = esp_wifi_set_max_tx_power(84);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "operation=wifi.tx_power code=%s", esp_err_to_name(ret));
    }
    ESP_LOGI(TAG, "operation=wifi.start outcome=success");
    return ESP_OK;
}

void wifi_maintain(void)
{
    /* Only the application task calls start/stop/maintain. Event handlers race
     * with this task, so claim each action against live state under the mux.
     * Never hold the mux through a driver/netif call or wait for the event loop. */
    int64_t now = esp_timer_get_time();
    portENTER_CRITICAL(&s_state_lock);
    if (!s_state.started || !s_state.driver_started || s_state.has_ip || s_state.disconnecting) {
        portEXIT_CRITICAL(&s_state_lock);
        return;
    }
    if (s_state.connecting) {
        if (now - s_state.last_attempt < WIFI_CONNECT_TIMEOUT_MS * 1000LL) {
            portEXIT_CRITICAL(&s_state_lock);
            return;
        }
        /* This transition competes atomically with GOT_IP. Once it wins, late
         * association/IP events cannot resurrect the timed-out attempt. */
        s_state.connecting = false;
        s_state.associated = false;
        s_state.disconnecting = true;
        s_state.last_attempt = now;
        uint32_t generation = ++s_state.generation;
        portEXIT_CRITICAL(&s_state_lock);
        esp_err_t ret = esp_wifi_disconnect();
        if (ret != ESP_OK) {
            portENTER_CRITICAL(&s_state_lock);
            if (s_state.generation == generation) {
                s_state.disconnecting = false;
            }
            portEXIT_CRITICAL(&s_state_lock);
            ESP_LOGW(TAG, "operation=wifi.disconnect outcome=failure code=%s", esp_err_to_name(ret));
        }
        ESP_LOGW(TAG, "operation=wifi.connect outcome=failure code=WIFI_CONNECT_TIMEOUT");
        return;
    }
    if (s_state.attempts >= WIFI_MAX_RETRIES ||
        now - s_state.last_attempt < WIFI_RETRY_INTERVAL_MS * 1000LL) {
        portEXIT_CRITICAL(&s_state_lock);
        return;
    }
    s_state.connecting = true;
    s_state.associated = false;
    s_state.last_attempt = now;
    unsigned attempt = ++s_state.attempts;
    uint32_t generation = ++s_state.generation;
    portEXIT_CRITICAL(&s_state_lock);
    esp_err_t ret = esp_wifi_connect();
    ESP_LOGI(TAG, "operation=wifi.connect_attempt attempt=%u outcome=%s",
             attempt, ret == ESP_OK ? "started" : "failure");
    if (ret != ESP_OK) {
        portENTER_CRITICAL(&s_state_lock);
        if (s_state.generation == generation && s_state.connecting && !s_state.has_ip) {
            s_state.connecting = false;
            s_state.associated = false;
            ++s_state.generation;
        }
        portEXIT_CRITICAL(&s_state_lock);
        ESP_LOGW(TAG, "operation=wifi.connect outcome=failure code=%s", esp_err_to_name(ret));
    }
}

bool wifi_is_connected(void)
{
    wifi_state_t state = state_snapshot();
    return state.started && state.has_ip;
}

bool wifi_is_associated(void)
{
    wifi_state_t state = state_snapshot();
    return state.started && state.associated;
}

esp_ip_addr_t wifi_app_address(void)
{
    return s_app_ip;
}

void wifi_set_app_peer(const esp_ip_addr_t *ip, uint16_t port)
{
    (void)port;
    if (ip != NULL) {
        s_app_ip = *ip;
    }
}

const char *wifi_status_string(void)
{
    wifi_state_t state = state_snapshot();
    if (state.started && state.has_ip) {
        return "connected";
    }
    if (!state.started) {
        return "disconnected";
    }
    return state.attempts >= WIFI_MAX_RETRIES && !state.connecting
        ? "failed" : "connecting";
}

void wifi_local_ip_str(char *buf, size_t bufsize)
{
    if (buf == NULL || bufsize == 0) {
        return;
    }
    wifi_state_t state = state_snapshot();
    esp_ip4_addr_t ip = state.has_ip ? state.ip : (esp_ip4_addr_t){0};
    snprintf(buf, bufsize, IPSTR, IP2STR(&ip));
}
