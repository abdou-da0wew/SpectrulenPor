idf_component_register(
  SRCS "wifi.c"
  INCLUDE_DIRS "."
  REQUIRES driver esp_wifi mdns esp_netif lwip
)
