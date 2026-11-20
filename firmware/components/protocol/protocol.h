#ifndef SPECTRULENPOR_PROTOCOL_H
#define SPECTRULENPOR_PROTOCOL_H

#include "config.h"

typedef struct {
    char ssid[WIFI_SSID_CAPACITY];
    char password[WIFI_PASSWORD_CAPACITY];
} firmware_wifi_credentials_t;

typedef struct {
    uint8_t code;
    firmware_wifi_credentials_t wifi;
} firmware_command_t;

typedef enum {
    PROTOCOL_OK,
    PROTOCOL_INVALID_LENGTH,
    PROTOCOL_INVALID_PAYLOAD,
    PROTOCOL_UNKNOWN_COMMAND,
} protocol_result_t;

/* Decode one complete command; never read past len or retain failed input. */
protocol_result_t protocol_parse_command(const uint8_t *data, size_t len,
                                         firmware_command_t *out);
bool protocol_wifi_credentials_valid(const firmware_wifi_credentials_t *wifi);
bool protocol_command_allowed_over_udp(uint8_t code);
bool protocol_command_allowed_over_ble_setup(uint8_t code);

/* Marker validation only. The hardware test also decodes the full JPEG. */
bool protocol_jpeg_valid(const uint8_t *data, size_t len);

size_t protocol_udp_packet_count(size_t frame_len);
/*
 * Project author: Malak Adel Sayed Hassan.
 * Software developer and original code author: Abdou (عبد الرحمن أيمن محمد).
 * Device attribution is exposed separately in BLE scan-response metadata;
 * do not change the UDP V2 wire layout to carry human-readable author strings.
 *
 * Device identity is carried separately in the BLE scan response; the UDP V2
 * header remains a fixed six-field binary contract with no text metadata.
 *
 * V2 wire header: seq, total_data_fragments, byte_offset, payload_size,
 * frame_id, frame_size (six little-endian uint32 values).
 * A parity packet sets UDP_PARITY_SEQUENCE_FLAG in seq; the remaining low
 * bits contain the strided FEC group index (data sequence modulo group count).
 * Its offset identifies that group's first data fragment.
 */
bool protocol_udp_encode_packet(const uint8_t *frame, size_t frame_len,
                                uint32_t frame_id, size_t sequence,
                                uint8_t *packet, size_t capacity,
                                size_t *packet_len);
bool protocol_udp_encode_parity_packet(const uint8_t *parity,
                                       size_t parity_len,
                                       size_t frame_len, uint32_t frame_id,
                                       size_t group_index, size_t total,
                                       uint8_t *packet, size_t capacity,
                                       size_t *packet_len);

#endif
