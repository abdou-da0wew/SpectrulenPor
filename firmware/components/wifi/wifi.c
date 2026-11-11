#include <string.h>
#include "esp_log.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "mdns.h"
#include "wifi.h"
#include "config.h"

static const char *TAG = WIFI_TAG;

static esp_netif_t *s_sta_netif = NULL;
static bool s_wifi_started = false;

static esp_ip_addr_t s_app_ip;
static uint16_t s_app_port = 0;
static bool s_app_peer_known = false;

/* Credentials from BLE. */
extern char g_wifi_ssid[32];
extern char g_wifi_pass[64];

static void wifi_event_handler(void *arg, esp_event_base_t event_base,
                               int32_t event_id, void *event_data)
{
    if (event_base == WIFI_EVENT) {
        switch (event_id) {
        case WIFI_EVENT_STA_START:
            ESP_LOGI(TAG, "STA start");
            esp_wifi_connect();
            break;
        case WIFI_EVENT_STA_CONNECTED:
            ESP_LOGI(TAG, "STA connected to AP");
            break;
        case WIFI_EVENT_STA_DISCONNECTED: {
            wifi_event_sta_disconnected_t *dis = event_data;
            ESP_LOGW(TAG, "STA disconnected (reason=%d)", dis->reason);
            if (s_wifi_started) {
                esp_wifi_connect();
            }
            break;
        }
        default:
            break;
        }
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *evt = event_data;
        ESP_LOGI(TAG, "Got IP: " IPSTR, IP2STR(&evt->ip_info.ip));
        s_sta_netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    }
}

esp_err_t wifi_start_station(void)
{
    if (s_wifi_started) return ESP_OK;

    ESP_LOGI(TAG, "Starting WiFi STA (SSID=%.31s)", g_wifi_ssid);

    s_sta_netif = esp_netif_create_default_wifi_sta();
    if (s_sta_netif == NULL) return ESP_FAIL;

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    esp_err_t ret = esp_wifi_init(&cfg);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "esp_wifi_init failed: %s", esp_err_to_name(ret));
        return ret;
    }

    ret = esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                              &wifi_event_handler, NULL, NULL);
    if (ret != ESP_OK) return ret;

    ret = esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                              &wifi_event_handler, NULL, NULL);
    if (ret != ESP_OK) return ret;

    wifi_config_t wifi_config = {0};
    strncpy((char *)wifi_config.sta.ssid, g_wifi_ssid,
            sizeof(wifi_config.sta.ssid) - 1);
    strncpy((char *)wifi_config.sta.password, g_wifi_pass,
            sizeof(wifi_config.sta.password) - 1);
    wifi_config.sta.threshold.authmode = WIFI_AUTH_OPEN;
    wifi_config.sta.pmf_cfg.capable = false;

    ret = esp_wifi_set_mode(WIFI_MODE_STA);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "set mode failed: %s", esp_err_to_name(ret));
        return ret;
    }

    ret = esp_wifi_set_config(WIFI_IF_STA, &wifi_config);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "set config failed: %s", esp_err_to_name(ret));
        return ret;
    }

    ret = esp_wifi_start();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "wifi_start failed: %s", esp_err_to_name(ret));
        return ret;
    }

    s_wifi_started = true;

    if (mdns_init() == ESP_OK) {
        mdns_hostname_set(WIFI_HOSTNAME);
        mdns_instance_name_set("SpectruLenPor Glasses");
        mdns_service_add(NULL, "_esp32-video", "_udp", UDP_VIDEO_PORT, NULL, 0);
        ESP_LOGI(TAG, "mDNS + service broadcast active");
    } else {
        ESP_LOGW(TAG, "mDNS init failed");
    }

    return ESP_OK;
}

void wifi_maintain(void)
{
    if (!s_wifi_started) return;
    if (!wifi_is_connected()) {
        esp_wifi_connect();
    }
}

void wifi_stop_station(void)
{
    if (s_wifi_started) {
        esp_wifi_disconnect();
        esp_wifi_stop();
        esp_wifi_deinit();
        s_wifi_started = false;
    }
    mdns_free();
}

bool wifi_is_connected(void)
{
    if (!s_wifi_started) return false;
    wifi_ap_record_t ap;
    return esp_wifi_sta_get_ap_info(&ap) == ESP_OK;
}

esp_ip_addr_t wifi_app_address(void)
{
    return s_app_ip;
}

void wifi_set_app_peer(const esp_ip_addr_t *ip, uint16_t port)
{
    s_app_ip = *ip;
    s_app_port = port;
    s_app_peer_known = true;
    ESP_LOGI(TAG, "App peer recorded: " IPSTR ":%d", IP2STR(&s_app_ip), port);
}

const char *wifi_status_string(void)
{
    if (wifi_is_connected()) return "connected";
    if (s_wifi_started) return "connecting";
    return "disconnected";
}

void wifi_local_ip_str(char *buf, size_t bufsize)
{
    if (!wifi_is_connected()) {
        snprintf(buf, bufsize, "0.0.0.0");
        return;
    }
    esp_netif_ip_info_t info;
    esp_netif_get_ip_info(s_sta_netif, &info);
    snprintf(buf, bufsize, IPSTR, IP2STR(&info.ip));
}
