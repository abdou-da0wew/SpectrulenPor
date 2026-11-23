#include <string.h>
#include <inttypes.h>
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "nimble/nimble_port.h"
#include "host/ble_hs.h"
#include "host/ble_hs_mbuf.h"
#include "host/ble_gap.h"
#include "host/ble_att.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "ble.h"
#include "wifi.h"

static const char *TAG = "BLE";

typedef struct {
    uint16_t handle;
    uint16_t mtu;
    bool connected;
    bool notify_enabled;
    bool paired;
    uint32_t session;
    uint32_t notification_errors;
} ble_link_t;

static ble_link_t s_link = {
    .handle = BLE_HS_CONN_HANDLE_NONE,
    .mtu = BLE_ATT_MTU_DFLT,
};
static portMUX_TYPE s_link_lock = portMUX_INITIALIZER_UNLOCKED;
/* A task mutex, never a spinlock around NimBLE calls. GAP callbacks run without
 * the NimBLE host lock; NOTIFY_TX does not take this mutex in our callback. */
static SemaphoreHandle_t s_tx_lock;
static QueueHandle_t s_commands;
static uint16_t s_tx_handle;
static uint8_t s_own_addr_type;

static ble_link_t link_snapshot(void)
{
    portENTER_CRITICAL(&s_link_lock);
    ble_link_t link = s_link;
    portEXIT_CRITICAL(&s_link_lock);
    return link;
}

bool ble_is_connected(void) { return link_snapshot().connected; }
bool ble_can_notify(void)
{
    ble_link_t link = link_snapshot();
    return link.connected && link.notify_enabled;
}
bool ble_is_paired(void) { return link_snapshot().paired; }
uint32_t ble_session_id(void) { return link_snapshot().session; }
uint32_t ble_notification_errors(void)
{
    return link_snapshot().notification_errors;
}

bool ble_session_is_current(uint32_t session)
{
    ble_link_t link = link_snapshot();
    return link.connected && link.session == session;
}

bool ble_next_command(ble_command_t *out)
{
    if (out == NULL || s_commands == NULL) {
        return false;
    }
    ble_command_t queued;
    while (xQueueReceive(s_commands, &queued, 0) == pdTRUE) {
        ble_link_t link = link_snapshot();
        if (link.connected && queued.session == link.session) {
            *out = queued;
            return true;
        }
    }
    return false;
}

static void link_reset(void)
{
    xSemaphoreTake(s_tx_lock, portMAX_DELAY);
    portENTER_CRITICAL(&s_link_lock);
    s_link.connected = false;
    s_link.notify_enabled = false;
    s_link.paired = false;
    s_link.handle = BLE_HS_CONN_HANDLE_NONE;
    s_link.mtu = BLE_ATT_MTU_DFLT;
    ++s_link.session;
    portEXIT_CRITICAL(&s_link_lock);
    xSemaphoreGive(s_tx_lock);
}

static void ble_advertise(void);

static int gap_event_cb(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            xSemaphoreTake(s_tx_lock, portMAX_DELAY);
            portENTER_CRITICAL(&s_link_lock);
            s_link.handle = event->connect.conn_handle;
            s_link.connected = true;
            s_link.notify_enabled = false;
            s_link.paired = false;
            s_link.mtu = BLE_ATT_MTU_DFLT;
            ++s_link.session;
            portEXIT_CRITICAL(&s_link_lock);
            xSemaphoreGive(s_tx_lock);
            ESP_LOGI(TAG, "operation=ble.connect handle=%u outcome=success",
                     event->connect.conn_handle);
        } else {
            ble_advertise();
        }
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        link_reset();
        ESP_LOGI(TAG, "operation=ble.disconnect reason=%d",
                 event->disconnect.reason);
        ble_advertise();
        break;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        ble_advertise();
        break;
    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.attr_handle == s_tx_handle) {
            portENTER_CRITICAL(&s_link_lock);
            if (s_link.connected && s_link.handle == event->subscribe.conn_handle) {
                s_link.notify_enabled = event->subscribe.cur_notify != 0;
            }
            portEXIT_CRITICAL(&s_link_lock);
            ESP_LOGI(TAG, "operation=ble.subscribe enabled=%u",
                     event->subscribe.cur_notify);
        }
        break;
    case BLE_GAP_EVENT_MTU:
        portENTER_CRITICAL(&s_link_lock);
        if (s_link.connected && s_link.handle == event->mtu.conn_handle) {
            s_link.mtu = event->mtu.value;
        }
        portEXIT_CRITICAL(&s_link_lock);
        ESP_LOGI(TAG, "operation=ble.mtu value=%u", event->mtu.value);
        break;
    default:
        break;
    }
    return 0;
}

static int gatt_svr_chr_access(uint16_t conn_handle, uint16_t attr_handle,
                               struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)attr_handle;
    (void)arg;

    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR || ctxt->om == NULL) {
        return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    }

    uint16_t length = OS_MBUF_PKTLEN(ctxt->om);
    if (length == 0 || length > COMMAND_MAX_BYTES) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }

    uint8_t data[COMMAND_MAX_BYTES];
    uint16_t copied = 0;
    if (ble_hs_mbuf_to_flat(ctxt->om, data, sizeof(data), &copied) != 0) {
        return BLE_ATT_ERR_UNLIKELY;
    }

    ble_command_t queued = {0};
    protocol_result_t result = protocol_parse_command(data, copied, &queued.command);
    if (result != PROTOCOL_OK) {
        return result == PROTOCOL_INVALID_LENGTH
            ? BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN : BLE_ATT_ERR_VALUE_NOT_ALLOWED;
    }

    ble_link_t link = link_snapshot();
    if (!link.connected || link.handle != conn_handle) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    if ((queued.command.code == CMD_WIFI_CONFIG_PUT ||
         queued.command.code == CMD_REBOOT) && !link.paired) {
        /* This is application authorization, not SMP security pairing.
         * Authentication errors make BlueZ negotiate link security and retry. */
        ESP_LOGW(TAG, "operation=ble.reject command=0x%02x code=PAIR_REQUIRED",
                 queued.command.code);
        return BLE_ATT_ERR_VALUE_NOT_ALLOWED;
    }
    queued.session = link.session;
    if (xQueueSend(s_commands, &queued, 0) != pdTRUE) {
        return BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if (queued.command.code == CMD_BLE_PAIR) {
        portENTER_CRITICAL(&s_link_lock);
        if (s_link.connected && s_link.session == queued.session) {
            s_link.paired = true;
        }
        portEXIT_CRITICAL(&s_link_lock);
    }
    /* GPIO, NVS, WiFi and camera operations run on the application task. */
    return 0;
}

static const struct ble_gatt_chr_def gatt_svr_chrs[] = {
    {
        .uuid = BLE_UUID16_DECLARE(BLE_TX_UUID16),
        .flags = BLE_GATT_CHR_F_NOTIFY,
        .access_cb = gatt_svr_chr_access,
        .val_handle = &s_tx_handle,
    },
    {
        .uuid = BLE_UUID16_DECLARE(BLE_RX_UUID16),
        .flags = BLE_GATT_CHR_F_WRITE,
        .access_cb = gatt_svr_chr_access,
    },
    { 0 },
};

static const struct ble_gatt_svc_def gatt_svr_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = BLE_UUID16_DECLARE(BLE_SVC_UUID16),
        .characteristics = gatt_svr_chrs,
    },
    { 0 },
};

esp_err_t ble_send_text(const char *text)
{
    return ble_send_text_for_session(ble_session_id(), text);
}

esp_err_t ble_send_text_for_session(uint32_t session, const char *text)
{
    return text == NULL ? ESP_ERR_INVALID_ARG
        : ble_send_bytes_for_session(session, (const uint8_t *)text, strlen(text));
}

esp_err_t ble_send_bytes(const uint8_t *data, size_t len)
{
    return ble_send_bytes_for_session(ble_session_id(), data, len);
}

esp_err_t ble_send_bytes_for_session(uint32_t session, const uint8_t *data, size_t len)
{
    if (data == NULL || len == 0 || len > MAX_FRAME_BYTES) {
        return ESP_ERR_INVALID_ARG;
    }
    if (s_tx_lock == NULL || s_tx_handle == 0) {
        return ESP_ERR_INVALID_STATE;
    }
    size_t offset = 0;
    while (offset < len) {
        int64_t deadline = esp_timer_get_time() + BLE_NOTIFY_TIMEOUT_MS * 1000LL;
        bool sent = false;
        while (!sent) {
            /* Serialize identity validation and submission with reset/connect,
             * including reuse of a controller connection handle. */
            xSemaphoreTake(s_tx_lock, portMAX_DELAY);
            ble_link_t link = link_snapshot();
            if (!link.connected || !link.notify_enabled ||
                link.session != session || link.mtu <= 3) {
                xSemaphoreGive(s_tx_lock);
                return ESP_ERR_INVALID_STATE;
            }
            size_t chunk = len - offset;
            size_t limit = link.mtu - 3U;
            if (limit > BLE_CHUNK_SIZE) {
                limit = BLE_CHUNK_SIZE;
            }
            if (chunk > limit) {
                chunk = limit;
            }
            struct os_mbuf *om = ble_hs_mbuf_from_flat(data + offset, (uint16_t)chunk);
            int rc = om == NULL ? BLE_HS_ENOMEM
                                : ble_gatts_notify_custom(link.handle, s_tx_handle, om);
            xSemaphoreGive(s_tx_lock);
            if (rc == 0) {
                offset += chunk;
                sent = true;
            } else if ((rc != BLE_HS_ENOMEM && rc != BLE_HS_EBUSY) ||
                       esp_timer_get_time() >= deadline) {
                portENTER_CRITICAL(&s_link_lock);
                ++s_link.notification_errors;
                portEXIT_CRITICAL(&s_link_lock);
                ESP_LOGW(TAG, "operation=ble.notify outcome=failure rc=%d", rc);
                return ESP_FAIL;
            } else {
                vTaskDelay(pdMS_TO_TICKS(BLE_NOTIFY_RETRY_MS));
            }
        }
        vTaskDelay(pdMS_TO_TICKS(BLE_NOTIFY_PACE_MS));
    }
    return ESP_OK;
}

/*
 * Project author: Malak Adel Sayed Hassan.
 * BLE firmware and original code author: Abdoul-Rahman Ayman (GitHub: abdou-da0wew).
 */
static void ble_advertise(void)
{
    struct ble_hs_adv_fields fields = {0};
    struct ble_hs_adv_fields scan_response = {0};
    static const ble_uuid16_t service_uuid = BLE_UUID16_INIT(BLE_SVC_UUID16);
    static uint8_t identity_service_data[] = {
        0xE0, 0xFF,
        'D', 'E', 'V', ':', 'a', 'b', 'd', 'o', 'u', '-', 'd', 'a', '0', 'w', 'e', 'w', ';',
        'P', ':', 'M', 'a', 'l', 'a', 'k',
    };
    _Static_assert(sizeof(identity_service_data) + 2U <= 31U,
                   "BLE identity scan response must fit legacy advertising limits");
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.name = (const uint8_t *)BLE_DEV_NAME;
    fields.name_len = strlen(BLE_DEV_NAME);
    fields.name_is_complete = 1;
    fields.uuids16 = &service_uuid;
    fields.num_uuids16 = 1;
    fields.uuids16_is_complete = 1;
    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "operation=ble.advertisement outcome=failure rc=%d", rc);
        return;
    }

    /*
     * Keep the legacy device name and FFE0 UUID in the primary advertisement.
     * Put project attribution in scan-response service data so discovery and
     * the existing GATT contract remain compatible with older app builds.
     */
    scan_response.svc_data_uuid16 = identity_service_data;
    scan_response.svc_data_uuid16_len = (uint8_t)sizeof(identity_service_data);
    rc = ble_gap_adv_rsp_set_fields(&scan_response);
    if (rc != 0) {
        ESP_LOGE(TAG, "operation=ble.scan_response outcome=failure rc=%d", rc);
        return;
    }

    struct ble_gap_adv_params params = {0};
    params.conn_mode = BLE_GAP_CONN_MODE_UND;
    params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    rc = ble_gap_adv_start(s_own_addr_type, NULL, BLE_HS_FOREVER,
                           &params, gap_event_cb, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "operation=ble.advertise outcome=failure rc=%d", rc);
    } else {
        ESP_LOGI(TAG, "operation=ble.advertise name=%s outcome=success", BLE_DEV_NAME);
    }
}

static void on_sync(void)
{
    int rc = ble_hs_id_infer_auto(0, &s_own_addr_type);
    if (rc != 0) {
        ESP_LOGE(TAG, "operation=ble.address_type outcome=failure rc=%d", rc);
        return;
    }
    ble_advertise();
}

static void on_reset(int reason)
{
    link_reset();
    ESP_LOGE(TAG, "operation=ble.host_reset reason=%d", reason);
}

static void nimble_host_task(void *param)
{
    (void)param;
    nimble_port_run();
    vTaskDelete(NULL);
}

esp_err_t ble_init(void)
{
    s_tx_lock = xSemaphoreCreateMutex();
    if (s_tx_lock == NULL) {
        return ESP_ERR_NO_MEM;
    }
    s_commands = xQueueCreate(BLE_COMMAND_QUEUE_LENGTH, sizeof(ble_command_t));
    if (s_commands == NULL) {
        vSemaphoreDelete(s_tx_lock);
        s_tx_lock = NULL;
        return ESP_ERR_NO_MEM;
    }
    esp_err_t ret = nimble_port_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init failed: %s", esp_err_to_name(ret));
        vQueueDelete(s_commands);
        s_commands = NULL;
        vSemaphoreDelete(s_tx_lock);
        s_tx_lock = NULL;
        return ret;
    }

    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.store_status_cb = NULL;

    ble_svc_gap_init();
    ble_svc_gatt_init();
    int rc = ble_svc_gap_device_name_set(BLE_DEV_NAME);
    if (rc == 0) {
        rc = ble_att_set_preferred_mtu(BLE_PREFERRED_MTU);
    }
    if (rc == 0) {
        rc = ble_gatts_count_cfg(gatt_svr_svcs);
    }
    if (rc == 0) {
        rc = ble_gatts_add_svcs(gatt_svr_svcs);
    }
    if (rc != 0) {
        ESP_LOGE(TAG, "operation=ble.gap_device_name outcome=failure rc=%d", rc);
        nimble_port_deinit();
        vQueueDelete(s_commands);
        s_commands = NULL;
        vSemaphoreDelete(s_tx_lock);
        s_tx_lock = NULL;
        return ESP_FAIL;
    }
    if (xTaskCreatePinnedToCore(nimble_host_task, "nimble_host", BLE_HOST_STACK_BYTES,
                                NULL, BLE_HOST_PRIORITY, NULL,
                                CONFIG_BT_NIMBLE_PINNED_TO_CORE) != pdPASS) {
        nimble_port_deinit();
        vQueueDelete(s_commands);
        s_commands = NULL;
        vSemaphoreDelete(s_tx_lock);
        s_tx_lock = NULL;
        return ESP_ERR_NO_MEM;
    }
    ESP_LOGI(TAG, "operation=ble.init outcome=success");
    return ESP_OK;
}
