idf_component_register(
  SRCS "camera.c"
  INCLUDE_DIRS "." "../.."
  REQUIRES esp_psram protocol
  PRIV_REQUIRES esp_driver_i2c
)
