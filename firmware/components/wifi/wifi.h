#ifndef SPECTRULENPOR_WIFI_H
#define SPECTRULENPOR_WIFI_H

#include "esp_netif.h"
#include "protocol.h"

#define WIFI_TAG "WIFI"

/* WiFi operates in STA mode only after BLE setup has saved credentials.
 * Credentials are stored persistently in NVS and reconnected automatically
 * on every boot. */
esp_err_t wifi_start_station(const firmware_wifi_credentials_t *credentials);
esp_err_t wifi_load_credentials(firmware_wifi_credentials_t *out);
esp_err_t wifi_save_credentials(const firmware_wifi_credentials_t *credentials);
esp_err_t wifi_erase_credentials(void);
void wifi_maintain(void);
esp_err_t wifi_stop_station(void);

bool wifi_is_connected(void);
bool wifi_is_associated(void);
const char *wifi_status_string(void);
void wifi_local_ip_str(char *buf, size_t bufsize);

esp_ip_addr_t wifi_app_address(void);
void wifi_set_app_peer(const esp_ip_addr_t *ip, uint16_t port);

#endif /* SPECTRULENPOR_WIFI_H */