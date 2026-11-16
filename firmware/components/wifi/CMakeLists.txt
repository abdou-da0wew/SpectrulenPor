idf_component_register(
  SRCS "wifi.c"
  INCLUDE_DIRS "." "../.."
  REQUIRES esp_netif protocol
  PRIV_REQUIRES esp_wifi esp_event nvs_flash freertos esp_timer
)
