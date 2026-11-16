#ifndef SPECTRULENPOR_UDP_STREAM_H
#define SPECTRULENPOR_UDP_STREAM_H

#include "esp_netif.h"
#include "protocol.h"

/* Start UDP socket (bind to UDP_VIDEO_PORT) for tx + rx. */
esp_err_t udp_stream_start(void);

/* Stop UDP socket. */
void udp_stream_stop(void);

/* Send one JPEG frame over UDP to the app peer registered by stream control.
 * Packet: [seq:4][total:4][offset:4][size:4][payload...] */
bool udp_stream_send_frame(const uint8_t *jpeg, size_t len);

/* Poll bounded input and return one validated control command. */
bool udp_stream_receive_command(firmware_command_t *out);
bool udp_stream_has_peer(void);
void udp_stream_clear_peer(void);

/* Record the app peer so video goes unicast instead of broadcast. */
void udp_stream_set_app_peer(const esp_ip_addr_t *ip, uint16_t port);

/* Get the app peer address. */
esp_ip_addr_t udp_stream_app_address(void);

#endif /* SPECTRULENPOR_UDP_STREAM_H */
