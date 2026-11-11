idf_component_register(
  SRCS "main.c"
  INCLUDE_DIRS "."
  REQUIRES camera sensors flashlight ble wifi udp_stream
  PRIV_REQUIRES driver esp_camera esp_wifi nimble mdns
)
