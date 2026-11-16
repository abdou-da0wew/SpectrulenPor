idf_component_register(
  SRCS "ble.c"
  INCLUDE_DIRS "." "../.."
  REQUIRES bt protocol
  PRIV_REQUIRES freertos esp_timer wifi
)
