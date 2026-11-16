#ifndef SPECTRULENPOR_BLE_H
#define SPECTRULENPOR_BLE_H

#include "esp_err.h"
#include "protocol.h"

/* BLE is used ONLY for initial WiFi setup. After WiFi credentials are saved
 * and the device reboots, BLE is disabled and WiFi takes over completely. */

/* Initialize NimBLE GATT server and start advertising in setup mode. */
esp_err_t ble_init(void);

/* Send a text line over the TX characteristic (notify). */
esp_err_t ble_send_text(const char *text);

/* Send raw bytes over TX, chunked into BLE notifications. */
esp_err_t ble_send_bytes(const uint8_t *data, size_t len);

/* Command replies must never select a newer connection at send time. */
esp_err_t ble_send_text_for_session(uint32_t session, const char *text);
esp_err_t ble_send_bytes_for_session(uint32_t session, const uint8_t *data, size_t len);

typedef struct {
    firmware_command_t command;
    uint32_t session;
} ble_command_t;

/* Retain source identity through dequeue and revalidate at execution start. */
bool ble_next_command(ble_command_t *out);
bool ble_session_is_current(uint32_t session);

/* Connection state queried by the application task. */
bool ble_is_connected(void);
bool ble_can_notify(void);
bool ble_is_paired(void);
uint32_t ble_session_id(void);
uint32_t ble_notification_errors(void);

#endif /* SPECTRULENPOR_BLE_H */
