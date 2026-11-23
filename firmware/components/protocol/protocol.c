#include <string.h>
#include "protocol.h"

_Static_assert(UDP_PAYLOAD_BYTES + UDP_HEADER_LEN <= UDP_MTU_SAFE,
               "UDP fragments must fit the safe datagram size");
_Static_assert(sizeof(udp_frame_hdr_t) == UDP_HEADER_LEN,
               "UDP V2 header struct must match the wire header length");
_Static_assert(sizeof(BLE_PAIRING_CODE) - 1U == BLE_PAIRING_CODE_LEN,
               "BLE pairing code length must match its configured bytes");

static size_t bounded_length(const char *text, size_t capacity)
{
    const char *end = memchr(text, '\0', capacity);
    return end == NULL ? capacity : (size_t)(end - text);
}

bool protocol_wifi_credentials_valid(const firmware_wifi_credentials_t *wifi)
{
    if (wifi == NULL) {
        return false;
    }
    size_t ssid_len = bounded_length(wifi->ssid, sizeof(wifi->ssid));
    size_t pass_len = bounded_length(wifi->password, sizeof(wifi->password));
    if (ssid_len == 0 || ssid_len > WIFI_SSID_MAX_BYTES ||
        pass_len > WIFI_PASSWORD_MAX_BYTES) {
        return false;
    }
    /* Status lines carry the SSID, so reject line breaks/control characters. */
    for (size_t i = 0; i < ssid_len; ++i) {
        uint8_t c = (uint8_t)wifi->ssid[i];
        if (c < 0x20U || c == 0x7FU) {
            return false;
        }
    }
    if (pass_len == 0) {
        return true;
    }
    if (pass_len < WIFI_MIN_PASSPHRASE_BYTES) {
        return false;
    }
    if (pass_len == WIFI_PASSWORD_MAX_BYTES) {
        for (size_t i = 0; i < pass_len; ++i) {
            char c = wifi->password[i];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
                  (c >= 'A' && c <= 'F'))) {
                return false;
            }
        }
    }
    return true;
}

protocol_result_t protocol_parse_command(const uint8_t *data, size_t len,
                                         firmware_command_t *out)
{
    if (out == NULL) {
        return PROTOCOL_INVALID_PAYLOAD;
    }
    memset(out, 0, sizeof(*out));
    if (data == NULL || len == 0 || len > COMMAND_MAX_BYTES) {
        return PROTOCOL_INVALID_LENGTH;
    }
    if (data[0] > CMD_SET_VIDEO_PROFILE) {
        return PROTOCOL_UNKNOWN_COMMAND;
    }
    if (data[0] == CMD_SET_VIDEO_PROFILE) {
        if (len != 2U) {
            return PROTOCOL_INVALID_LENGTH;
        }
        if (data[1] != UINT8_MAX && data[1] > 4U) {
            return PROTOCOL_INVALID_PAYLOAD;
        }
        out->code = data[0];
        out->video_profile = data[1];
        return PROTOCOL_OK;
    }
    if (data[0] == CMD_WIFI_CONFIG_PUT) {
        const uint8_t *ssid = data + 1;
        size_t remaining = len - 1;
        const uint8_t *ssid_end = memchr(ssid, '\0', remaining);
        if (ssid_end == NULL) {
            return PROTOCOL_INVALID_PAYLOAD;
        }
        size_t ssid_len = (size_t)(ssid_end - ssid);
        if (ssid_len > WIFI_SSID_MAX_BYTES) {
            return PROTOCOL_INVALID_PAYLOAD;
        }
        remaining -= ssid_len + 1;
        const uint8_t *password = ssid_end + 1;
        const uint8_t *pass_end = memchr(password, '\0', remaining);
        if (pass_end == NULL || pass_end != data + len - 1) {
            return PROTOCOL_INVALID_PAYLOAD;
        }
        size_t pass_len = (size_t)(pass_end - password);
        if (pass_len > WIFI_PASSWORD_MAX_BYTES) {
            return PROTOCOL_INVALID_PAYLOAD;
        }
        /* Empty SSID + empty password = erase credentials */
        if (ssid_len == 0 && pass_len == 0) {
            out->code = data[0];
            return PROTOCOL_OK;
        }
        if (ssid_len == 0) {
            return PROTOCOL_INVALID_PAYLOAD;
        }
        firmware_wifi_credentials_t wifi = {0};
        memcpy(wifi.ssid, ssid, ssid_len);
        memcpy(wifi.password, password, pass_len);
        if (!protocol_wifi_credentials_valid(&wifi)) {
            return PROTOCOL_INVALID_PAYLOAD;
        }
        out->code = data[0];
        out->wifi = wifi;
        return PROTOCOL_OK;
    }
    if (data[0] == CMD_BLE_PAIR) {
        if (len != 1U + BLE_PAIRING_CODE_LEN) {
            return PROTOCOL_INVALID_LENGTH;
        }
        if (memcmp(data + 1, BLE_PAIRING_CODE, BLE_PAIRING_CODE_LEN) != 0) {
            return PROTOCOL_INVALID_PAYLOAD;
        }
        out->code = data[0];
        return PROTOCOL_OK;
    }
    /* All remaining commands carry no payload, including CMD_REBOOT. */
    if (len != 1) {
        return PROTOCOL_INVALID_LENGTH;
    }
    out->code = data[0];
    return PROTOCOL_OK;
}

bool protocol_command_allowed_over_udp(uint8_t code)
{
    return code <= CMD_FLASH_OFF || code == CMD_RESTART ||
           code == CMD_SHUTDOWN || code == CMD_CONNECTION_STATUS ||
           code == CMD_REBOOT || code == CMD_UDP_KEEPALIVE ||
           code == CMD_SET_VIDEO_PROFILE;
}

bool protocol_command_allowed_over_ble_setup(uint8_t code)
{
    switch (code) {
    case CMD_FLASH_ON:
    case CMD_FLASH_OFF:
    case CMD_RESTART:
    case CMD_SHUTDOWN:
    case CMD_WIFI_CONFIG_PUT:
    case CMD_WIFI_CONFIG_GET:
    case CMD_CONNECTION_STATUS:
    case CMD_BLE_PAIR:
    case CMD_REBOOT:
        return true;
    default:
        return false;
    }
}

bool protocol_jpeg_valid(const uint8_t *data, size_t len)
{
    return data != NULL && len >= JPEG_MIN_BYTES && len <= MAX_FRAME_BYTES &&
           data[0] == JPEG_MARKER_PREFIX && data[1] == JPEG_MARKER_SOI &&
           data[len - 2] == JPEG_MARKER_PREFIX && data[len - 1] == JPEG_MARKER_EOI;
}

size_t protocol_udp_packet_count(size_t frame_len)
{
    if (frame_len == 0 || frame_len > MAX_FRAME_BYTES) {
        return 0;
    }
    return 1U + (frame_len - 1U) / UDP_PAYLOAD_BYTES;
}

size_t protocol_udp_fec_group_size(size_t total)
{
    return total > 0 && total <= UDP_FEC_GROUP_SIZE
        ? 1U : UDP_FEC_GROUP_SIZE;
}

static void write_u32_le(uint8_t *out, uint32_t value)
{
    for (size_t i = 0; i < sizeof(value); ++i) {
        out[i] = (uint8_t)(value >> (i * 8U));
    }
}

bool protocol_udp_encode_packet(const uint8_t *frame, size_t frame_len,
                                uint32_t frame_id, size_t sequence,
                                uint8_t *packet, size_t capacity,
                                size_t *packet_len)
{
    if (packet_len == NULL) {
        return false;
    }
    *packet_len = 0;
    size_t count = protocol_udp_packet_count(frame_len);
    if (frame == NULL || packet == NULL || count == 0 || sequence >= count ||
        sequence > UINT32_MAX) {
        return false;
    }
    size_t offset = sequence * UDP_PAYLOAD_BYTES;
    size_t chunk = frame_len - offset;
    if (chunk > UDP_PAYLOAD_BYTES) {
        chunk = UDP_PAYLOAD_BYTES;
    }
    if (capacity < UDP_HEADER_LEN + chunk) {
        return false;
    }
    write_u32_le(packet, (uint32_t)sequence);
    write_u32_le(packet + 4, (uint32_t)count);
    write_u32_le(packet + 8, (uint32_t)offset);
    write_u32_le(packet + 12, (uint32_t)chunk);
    write_u32_le(packet + 16, frame_id);
    write_u32_le(packet + 20, (uint32_t)frame_len);
    memcpy(packet + UDP_HEADER_LEN, frame + offset, chunk);
    *packet_len = UDP_HEADER_LEN + chunk;
    return true;
}

bool protocol_udp_encode_parity_packet(const uint8_t *parity,
                                       size_t parity_len,
                                       size_t frame_len, uint32_t frame_id,
                                       size_t group_index, size_t total,
                                       uint8_t *packet, size_t capacity,
                                       size_t *packet_len)
{
    if (packet_len == NULL) {
        return false;
    }
    *packet_len = 0;
    size_t expected_total = protocol_udp_packet_count(frame_len);
    const size_t group_size = protocol_udp_fec_group_size(expected_total);
    size_t group_count = expected_total < group_size
        ? expected_total : group_size;
    if (parity == NULL || packet == NULL || expected_total == 0 ||
        total != expected_total || group_index >= group_count ||
        group_index > 0x7FFFFFFFU ||
        parity_len != UDP_PAYLOAD_BYTES ||
        capacity < UDP_HEADER_LEN + parity_len) {
        return false;
    }
    size_t group_start = group_index;
    size_t offset = group_start * UDP_PAYLOAD_BYTES;
    if (offset >= frame_len || offset > UINT32_MAX || frame_len > UINT32_MAX) {
        return false;
    }
    write_u32_le(packet, UDP_PARITY_SEQUENCE_FLAG | (uint32_t)group_index);
    write_u32_le(packet + 4, (uint32_t)expected_total);
    write_u32_le(packet + 8, (uint32_t)offset);
    write_u32_le(packet + 12, (uint32_t)parity_len);
    write_u32_le(packet + 16, frame_id);
    write_u32_le(packet + 20, (uint32_t)frame_len);
    memcpy(packet + UDP_HEADER_LEN, parity, parity_len);
    *packet_len = UDP_HEADER_LEN + parity_len;
    return true;
}
