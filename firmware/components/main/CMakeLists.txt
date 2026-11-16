idf_component_register(
  SRCS "main.c"
  INCLUDE_DIRS "." "../.."
  REQUIRES ov2640 sensors flashlight ble wifi udp_stream protocol
  PRIV_REQUIRES nvs_flash esp_event esp_netif esp_timer esp_system freertos
)
