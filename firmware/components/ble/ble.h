#ifndef SPECTRULENPOR_BLE_H
#define SPECTRULENPOR_BLE_H

#include "config.h"
#include <stdbool.h>

/* BLE connection / command state (volatile: updated from host callbacks). */
extern volatile bool g_client_connected;
extern volatile bool g_streaming;
extern volatile bool g_flash_on;
extern volatile bool g_restart_requested;
extern volatile bool g_shutdown_requested;
extern volatile bool g_wifi_config_get;
extern volatile bool g_connection_status_get;
extern volatile bool g_wifi_config_pending;
extern char          g_wifi_ssid[32];
extern char          g_wifi_pass[64];

/* Initialize NimBLE GATT server and start advertising. */
esp_err_t ble_init(void);

/* Send a text line over the TX characteristic (notify). */
void ble_send_text(const char *text);

/* Send raw bytes over TX, chunked into BLE notifications. */
void ble_send_bytes(const uint8_t *data, size_t len);

/* Handle an incoming RX command byte + optional payload. */
void ble_handle_command(uint8_t cmd, const uint8_t *payload, size_t payload_len);

#endif /* SPECTRULENPOR_BLE_H */
