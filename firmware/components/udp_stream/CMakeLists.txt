idf_component_register(
  SRCS "udp_stream.c"
  INCLUDE_DIRS "." "../.."
  REQUIRES esp_netif protocol
  PRIV_REQUIRES lwip freertos esp_timer heap
)
