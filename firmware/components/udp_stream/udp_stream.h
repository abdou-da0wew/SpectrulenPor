#ifndef SPECTRULENPOR_UDP_STREAM_H
#define SPECTRULENPOR_UDP_STREAM_H

#include "esp_netif.h"
#include "protocol.h"

/* Start UDP socket (bind to UDP_VIDEO_PORT) for tx + rx. */
esp_err_t udp_stream_start(void);

/* Stop UDP socket. */
void udp_stream_stop(void);

/* Send one V2 JPEG frame over UDP to the registered mobile peer. */
bool udp_stream_send_frame(const uint8_t *jpeg, size_t len, uint32_t packet_pace_ms);
/* Send a short command/status response to the registered mobile peer. */
bool udp_stream_send_control(const uint8_t *data, size_t len);

/* Poll bounded input and return one validated control command. */
bool udp_stream_receive_command(firmware_command_t *out);
bool udp_stream_has_peer(void);
void udp_stream_clear_peer(void);

/* Record the app peer so video goes unicast instead of broadcast. */
void udp_stream_set_app_peer(const esp_ip_addr_t *ip, uint16_t port);

/* Get the app peer address. */
esp_ip_addr_t udp_stream_app_address(void);

#endif /* SPECTRULENPOR_UDP_STREAM_H */
