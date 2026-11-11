idf_component_register(
  SRCS "ble.c"
  INCLUDE_DIRS "."
  REQUIRES driver nimble
  PRIV_REQUIRES esp_nimble_hci esp_nimble_host
)
