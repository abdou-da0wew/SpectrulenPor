idf_component_register(
  SRCS "sensors.c"
  INCLUDE_DIRS "." "../.."
  REQUIRES esp_common
  PRIV_REQUIRES esp_driver_i2c esp_timer freertos
)
