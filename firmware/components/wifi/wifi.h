#ifndef SPECTRULENPOR_WIFI_H
#define SPECTRULENPOR_WIFI_H

#include "esp_netif.h"
#include "config.h"

#define WIFI_TAG "WIFI"

esp_err_t wifi_start_station(void);
void wifi_maintain(void);
void wifi_stop_station(void);

bool wifi_is_connected(void);
const char *wifi_status_string(void);
void wifi_local_ip_str(char *buf, size_t bufsize);

esp_ip_addr_t wifi_app_address(void);
void wifi_set_app_peer(const esp_ip_addr_t *ip, uint16_t port);

#endif /* SPECTRULENPOR_WIFI_H */
