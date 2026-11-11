#include <string.h>
#include <stdio.h>
#include "esp_log.h"
#include "esp_bt.h"
#include "esp_nimble_hci.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "host/ble_gatt.h"
#include "host/ble_gap.h"
#include "host/ble_att.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "ble.h"
#include "wifi.h"
#include "flashlight.h"

static const char *TAG = "BLE";

/* -----------------------------------------------------------------------
 *  Shared state (defined here; declared extern in config.h)
 * --------------------------------------------------------------------- */
volatile bool g_client_connected      = false;
volatile bool g_streaming             = false;
volatile bool g_flash_on              = false;
volatile bool g_restart_requested     = false;
volatile bool g_shutdown_requested    = false;
volatile bool g_wifi_config_get       = false;
volatile bool g_connection_status_get = false;
volatile bool g_wifi_config_pending   = false;
char          g_wifi_ssid[32]         = {0};
char          g_wifi_pass[64]         = {0};

/* Current BLE connection handle (for notifications). */
static uint16_t g_conn_handle = BLE_HS_CONN_HANDLE_NONE;

/* TX CCCD notifications enabled flag. */
static bool g_tx_notify_enabled = false;

/* -----------------------------------------------------------------------
 *  UUIDs
 * --------------------------------------------------------------------- */
static ble_uuid128_t s_svc_uuid;
static ble_uuid128_t s_tx_uuid;
static ble_uuid128_t s_rx_uuid;

/* -----------------------------------------------------------------------
 *  Attribute handles (resolved after service registration)
 * --------------------------------------------------------------------- */
static uint16_t h_tx_val;
static uint16_t h_rx_val;

/* -----------------------------------------------------------------------
 *  GATT access callback
 * --------------------------------------------------------------------- */
static int gatt_svc_access(uint16_t conn_handle, uint16_t attr_handle,
                           struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    int chr_idx = (int)(uintptr_t)arg;

    if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        return 0;
    }

    if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
        if (chr_idx == 1) { /* RX characteristic */
            if (ctxt->om != NULL && ctxt->om->om_len > 0) {
                uint8_t *data = ctxt->om->om_data;
                uint16_t len = ctxt->om->om_len;
                ble_handle_command(data[0], data + 1, len - 1);
            }
            return 0;
        }
        return BLE_ATT_ERR_UNLIKELY;
    }

    if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_DSC) {
        /* CCCD write on TX characteristic. */
        if (chr_idx == 2 && ctxt->om != NULL && ctxt->om->om_len >= 2) {
            uint16_t cccd = ctxt->om->om_data[0] | (ctxt->om->om_data[1] << 8);
            g_tx_notify_enabled = (cccd & 0x0001) != 0;
            if (!g_tx_notify_enabled) {
                g_streaming = false;
            }
        }
        return 0;
    }

    return BLE_ATT_ERR_UNLIKELY;
}

/* -----------------------------------------------------------------------
 *  Service definition
 * --------------------------------------------------------------------- */
#define CHR_TX  0
#define CHR_RX  1
#define DESC_TX_CCCD 2

static struct ble_gatt_svc_def g_gatt_svc_defs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                /* TX — notify */
                .uuid = &s_tx_uuid.u,
                .flags = BLE_GATT_CHR_F_NOTIFY,
                .access_cb = gatt_svc_access,
                .arg = (void *)(uintptr_t)CHR_TX,
                .descriptors = (struct ble_gatt_dsc_def[]) {
                    {
                        .uuid = BLE_UUID16_DECLARE(BLE_GATT_DSC_CLT_CFG_UUID16),
                        .flags = BLE_GATT_DSC_F_READ | BLE_GATT_DSC_F_WRITE,
                        .access_cb = gatt_svc_access,
                        .arg = (void *)(uintptr_t)DESC_TX_CCCD,
                    },
                    { 0 },
                },
            },
            {
                /* RX — write */
                .uuid = &s_rx_uuid.u,
                .flags = BLE_GATT_CHR_F_WRITE,
                .access_cb = gatt_svc_access,
                .arg = (void *)(uintptr_t)CHR_RX,
            },
            { 0 },
        },
    },
    { 0 },
};

/* -----------------------------------------------------------------------
 *  GAP event callback
 * --------------------------------------------------------------------- */
static int gap_event_cb(struct ble_gap_event *event, void *arg)
{
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            g_conn_handle = event->connect.conn_handle;
            g_client_connected = true;
            g_tx_notify_enabled = false;
            ESP_LOGI(TAG, "BLE client connected (conn_handle=%d)", g_conn_handle);
        } else {
            ble_gap_adv_start(0, NULL, NULL, &gap_event_cb, NULL);
        }
        break;

    case BLE_GAP_EVENT_DISCONNECT:
        g_client_connected = false;
        g_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        g_streaming = false;
        g_flash_on = false;
        g_tx_notify_enabled = false;
        flashlight_set(false);
        ESP_LOGI(TAG, "BLE disconnected — restarting advertising");
        ble_gap_adv_start(0, NULL, NULL, &gap_event_cb, NULL);
        break;

    case BLE_GAP_EVENT_ADV_COMPLETE:
        ble_gap_adv_start(0, NULL, NULL, &gap_event_cb, NULL);
        break;

    case BLE_GAP_EVENT_SUBSCRIBE:
        ESP_LOGI(TAG, "Subscribe event: attr_handle=%d reason=%d",
                 event->subscribe.attr_handle, event->subscribe.reason);
        break;

    default:
        break;
    }
    return 0;
}

/* -----------------------------------------------------------------------
 *  BLE send helpers
 * --------------------------------------------------------------------- */
void ble_send_text(const char *text)
{
    if (!g_client_connected || !g_tx_notify_enabled) return;
    ble_send_bytes((const uint8_t *)text, strlen(text));
}

void ble_send_bytes(const uint8_t *data, size_t len)
{
    if (!g_client_connected || !g_tx_notify_enabled || h_tx_val == 0) return;

    for (size_t off = 0; off < len; off += BLE_CHUNK_SIZE) {
        size_t n = (off + BLE_CHUNK_SIZE <= len) ? BLE_CHUNK_SIZE : (len - off);
        struct os_mbuf *om = ble_hs_mbuf_from_flat(data + off, n);
        if (om == NULL) continue;
        int rc = ble_gattc_notify(g_conn_handle, h_tx_val, om);
        if (rc != 0) {
            ESP_LOGW(TAG, "BLE notify rc=%d", rc);
        }
        vTaskDelay(pdMS_TO_TICKS(3));
    }
}

/* -----------------------------------------------------------------------
 *  Command handler
 * --------------------------------------------------------------------- */
void ble_handle_command(uint8_t cmd, const uint8_t *payload, size_t payload_len)
{
    switch (cmd) {
    case CMD_STREAM_ON:
        g_streaming = true;
        ESP_LOGI(TAG, "CMD: stream ON");
        ble_send_text("$CMD:stream_on\n");
        break;

    case CMD_STREAM_OFF:
        g_streaming = false;
        ESP_LOGI(TAG, "CMD: stream OFF");
        ble_send_text("$CMD:stream_off\n");
        break;

    case CMD_SINGLE_FRAME:
        ESP_LOGI(TAG, "CMD: single frame requested");
        ble_send_text("$CMD:single_frame\n");
        g_streaming = true;
        break;

    case CMD_FLASH_ON:
        g_flash_on = true;
        flashlight_set(true);
        ESP_LOGI(TAG, "CMD: flashlight ON");
        ble_send_text("$CMD:flash_on\n");
        break;

    case CMD_FLASH_OFF:
        g_flash_on = false;
        flashlight_set(false);
        ESP_LOGI(TAG, "CMD: flashlight OFF");
        ble_send_text("$CMD:flash_off\n");
        break;

    case CMD_RESTART:
        g_restart_requested = true;
        ESP_LOGI(TAG, "CMD: restart queued");
        ble_send_text("$CMD:restart\n");
        break;

    case CMD_SHUTDOWN:
        g_shutdown_requested = true;
        ESP_LOGI(TAG, "CMD: shutdown queued");
        ble_send_text("$CMD:shutdown\n");
        break;

    case CMD_WIFI_CONFIG_PUT: {
        const char *ssid = (const char *)payload;
        size_t ssid_len = strlen(ssid);
        const char *pass = (ssid_len + 1 < payload_len)
            ? (const char *)(payload + ssid_len + 1) : "";
        strncpy(g_wifi_ssid, ssid, sizeof(g_wifi_ssid) - 1);
        g_wifi_ssid[sizeof(g_wifi_ssid) - 1] = '\0';
        strncpy(g_wifi_pass, pass, sizeof(g_wifi_pass) - 1);
        g_wifi_pass[sizeof(g_wifi_pass) - 1] = '\0';
        g_wifi_config_pending = true;
        ESP_LOGI(TAG, "CMD: wifi config put (SSID=%.31s)", g_wifi_ssid);
        ble_send_text("$CMD:wifi_config_received\n");
        break;
    }

    case CMD_WIFI_CONFIG_GET:
        g_wifi_config_get = true;
        ESP_LOGI(TAG, "CMD: wifi config get");
        break;

    case CMD_CONNECTION_STATUS:
        g_connection_status_get = true;
        ESP_LOGI(TAG, "CMD: connection status");
        break;

    default:
        break;
    }
}

/* -----------------------------------------------------------------------
 *  Advertising
 * --------------------------------------------------------------------- */
static void ble_advertise(void)
{
    struct ble_gap_adv_params adv_params = {0};
    adv_params.conn_mode = BLE_GAP_CONN_MODE_UND;
    adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    adv_params.channel_map = BLE_GAP_ADV_CHANNEL_MAP_ALL;
    adv_params.filter_policy = 0;
    adv_params.itvl_min = 0x0020;
    adv_params.itvl_max = 0x0040;

    ble_svc_gap_device_name_set(BLE_DEV_NAME);

    int rc = ble_gap_adv_start(&adv_params, NULL, BLE_HS_FOREVER,
                               &gap_event_cb, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "Advertising start failed: %d", rc);
    } else {
        ESP_LOGI(TAG, "Advertising as %s", BLE_DEV_NAME);
    }
}

/* -----------------------------------------------------------------------
 *  Sync callback — called when NimBLE host + controller are synced
 * --------------------------------------------------------------------- */
static void on_sync(void)
{
    int rc = ble_svc_gap_device_name_set(BLE_DEV_NAME);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_svc_gap_device_name_set failed: %d", rc);
        return;
    }

    rc = ble_gatts_count_svc(g_gatt_svc_defs);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gatts_count_svc failed: %d", rc);
        return;
    }

    rc = ble_gatts_add_svcs(g_gatt_svc_defs);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gatts_add_svcs failed: %d", rc);
        return;
    }

    /* Resolve TX / RX characteristic handles. */
    struct ble_gatt_svc *svc;
    rc = ble_gatts_find_svc(&s_svc_uuid.u, &svc);
    if (rc != 0) {
        ESP_LOGE(TAG, "find svc failed: %d", rc);
        return;
    }

    struct ble_gatt_chr *chr;
    rc = ble_gatts_find_chr(svc, &s_tx_uuid.u, &chr);
    if (rc != 0) {
        ESP_LOGE(TAG, "find TX chr failed: %d", rc);
        return;
    }
    h_tx_val = chr->def_handle;

    rc = ble_gatts_find_chr(svc, &s_rx_uuid.u, &chr);
    if (rc != 0) {
        ESP_LOGE(TAG, "find RX chr failed: %d", rc);
        return;
    }
    h_rx_val = chr->def_handle;

    /* Register GAP event listener. */
    struct ble_gap_event_listener listener = {
        .cb = gap_event_cb,
        .arg = NULL,
    };
    ble_gap_event_listener_register(&listener);

    ble_advertise();
    ESP_LOGI(TAG, "BLE initialized, advertising as %s", BLE_DEV_NAME);
}

/* -----------------------------------------------------------------------
 *  NimBLE host task
 * --------------------------------------------------------------------- */
static void nimble_host_task(void *param)
{
    nimble_port_run();
    vTaskDelete(NULL);
}

/* -----------------------------------------------------------------------
 *  Public init
 * --------------------------------------------------------------------- */
esp_err_t ble_init(void)
{
    esp_err_t ret;

    ret = esp_nimble_hci_and_controller_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "esp_nimble_hci_and_controller_init failed: %s",
                 esp_err_to_name(ret));
        return ret;
    }

    ret = nimble_port_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init failed: %s", esp_err_to_name(ret));
        return ret;
    }

    /* Set sync callback so we init GATT after host/controller sync. */
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.store_status_cb = NULL;

    /* UUIDs. */
    ble_uuid128_from_string(BLE_SVC_UUID,  &s_svc_uuid);
    ble_uuid128_from_string(BLE_TX_CHAR_UUID, &s_tx_uuid);
    ble_uuid128_from_string(BLE_RX_CHAR_UUID, &s_rx_uuid);

    /* GATT server init. */
    ble_gatts_init();

    /* Start host task. */
    xTaskCreate(nimble_host_task, "nimble_host", 4096, NULL, 5, NULL);

    ESP_LOGI(TAG, "BLE init called, waiting for sync...");
    return ESP_OK;
}
