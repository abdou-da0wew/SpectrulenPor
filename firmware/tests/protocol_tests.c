#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "protocol.h"

static unsigned checks;
#define CHECK(condition) do { \
    ++checks; \
    if (!(condition)) { \
        fprintf(stderr, "%s:%d: check failed: %s\n", __func__, __LINE__, #condition); \
        exit(EXIT_FAILURE); \
    } \
} while (0)

static size_t wifi_packet(uint8_t *out, const char *ssid, const char *password)
{
    size_t ssid_len = strlen(ssid) + 1;
    size_t pass_len = strlen(password) + 1;
    out[0] = CMD_WIFI_CONFIG_PUT;
    memcpy(out + 1, ssid, ssid_len);
    memcpy(out + 1 + ssid_len, password, pass_len);
    return 1 + ssid_len + pass_len;
}

static void check_invalid_command(const uint8_t *data, size_t len,
                                  protocol_result_t expected)
{
    firmware_command_t command;
    const firmware_command_t zero = {0};
    memset(&command, 0xA5, sizeof(command));
    CHECK(protocol_parse_command(data, len, &command) == expected);
    CHECK(memcmp(&command, &zero, sizeof(command)) == 0);
}

static void test_pairing(void)
{
    const uint8_t valid[] = {CMD_BLE_PAIR, '1', '1', '1', '1', '1'};
    firmware_command_t command;
    const firmware_command_t zero = {0};
    CHECK(sizeof(valid) == 1U + BLE_PAIRING_CODE_LEN);
    CHECK(memcmp(valid + 1, BLE_PAIRING_CODE, BLE_PAIRING_CODE_LEN) == 0);
    memset(&command, 0xA5, sizeof(command));
    CHECK(protocol_parse_command(valid, sizeof(valid), &command) == PROTOCOL_OK);
    CHECK(command.code == CMD_BLE_PAIR);
    CHECK(memcmp(&command.wifi, &zero.wifi, sizeof(command.wifi)) == 0);

    uint8_t invalid[sizeof(valid)];
    for (size_t i = 1; i < sizeof(valid); ++i) {
        memcpy(invalid, valid, sizeof(valid));
        invalid[i] = '0';
        check_invalid_command(invalid, sizeof(invalid), PROTOCOL_INVALID_PAYLOAD);
        invalid[i] = '\0';
        check_invalid_command(invalid, sizeof(invalid), PROTOCOL_INVALID_PAYLOAD);
    }

    uint8_t packet[COMMAND_MAX_BYTES + 1U];
    memset(packet, '1', sizeof(packet));
    packet[0] = CMD_BLE_PAIR;
    for (size_t len = 0; len <= sizeof(packet); ++len) {
        if (len != sizeof(valid)) {
            check_invalid_command(packet, len, PROTOCOL_INVALID_LENGTH);
        }
    }
    memcpy(packet, valid, sizeof(valid));
    packet[sizeof(valid)] = '\0';
    check_invalid_command(packet, sizeof(valid) + 1U, PROTOCOL_INVALID_LENGTH);
}

static void test_commands(void)
{
    firmware_command_t command;
    firmware_command_t zero = {0};
    test_pairing();
    for (uint8_t code = CMD_STREAM_OFF; code <= CMD_REBOOT; ++code) {
        if (code == CMD_WIFI_CONFIG_PUT || code == CMD_BLE_PAIR) {
            continue;
        }
        CHECK(protocol_parse_command(&code, 1, &command) == PROTOCOL_OK);
        CHECK(command.code == code);
        CHECK(memcmp(&command.wifi, &zero.wifi, sizeof(command.wifi)) == 0);
    }
    const uint8_t video_profile_xga[] = {CMD_SET_VIDEO_PROFILE, 0};
    const uint8_t video_profile_qqvga[] = {CMD_SET_VIDEO_PROFILE, 4};
    const uint8_t video_profile_auto[] = {CMD_SET_VIDEO_PROFILE, UINT8_MAX};
    CHECK(protocol_parse_command(video_profile_xga, sizeof(video_profile_xga), &command) == PROTOCOL_OK);
    CHECK(command.code == CMD_SET_VIDEO_PROFILE && command.video_profile == 0);
    CHECK(protocol_parse_command(video_profile_qqvga, sizeof(video_profile_qqvga), &command) == PROTOCOL_OK);
    CHECK(command.code == CMD_SET_VIDEO_PROFILE && command.video_profile == 4);
    CHECK(protocol_parse_command(video_profile_auto, sizeof(video_profile_auto), &command) == PROTOCOL_OK);
    CHECK(command.code == CMD_SET_VIDEO_PROFILE && command.video_profile == UINT8_MAX);
    const uint8_t invalid_video_profile[] = {CMD_SET_VIDEO_PROFILE, 5};
    check_invalid_command(invalid_video_profile, sizeof(invalid_video_profile), PROTOCOL_INVALID_PAYLOAD);
    check_invalid_command(video_profile_xga, 1, PROTOCOL_INVALID_LENGTH);

    uint8_t unknown = 0xFF;
    CHECK(protocol_parse_command(&unknown, 1, &command) == PROTOCOL_UNKNOWN_COMMAND);
    CHECK(protocol_parse_command(NULL, 1, &command) == PROTOCOL_INVALID_LENGTH);
    CHECK(protocol_parse_command(&unknown, 0, &command) == PROTOCOL_INVALID_LENGTH);
    CHECK(protocol_parse_command(&unknown, 1, NULL) == PROTOCOL_INVALID_PAYLOAD);
    uint8_t extra[] = {CMD_FLASH_ON, 1};
    CHECK(protocol_parse_command(extra, sizeof(extra), &command) == PROTOCOL_INVALID_LENGTH);
    CHECK(protocol_parse_command(extra, COMMAND_MAX_BYTES + 1, &command) == PROTOCOL_INVALID_LENGTH);
    const uint8_t reboot_extra[] = {CMD_REBOOT, 0};
    check_invalid_command(reboot_extra, sizeof(reboot_extra), PROTOCOL_INVALID_LENGTH);

    uint8_t packet[COMMAND_MAX_BYTES + 8];
    size_t length = wifi_packet(packet, "TestAP", "abcdefgh");
    CHECK(protocol_parse_command(packet, length, &command) == PROTOCOL_OK);
    CHECK(strcmp(command.wifi.ssid, "TestAP") == 0);
    CHECK(strcmp(command.wifi.password, "abcdefgh") == 0);
    for (size_t prefix = 0; prefix < length; ++prefix) {
        memset(&command, 0xA5, sizeof(command));
        CHECK(protocol_parse_command(packet, prefix, &command) != PROTOCOL_OK);
        CHECK(memcmp(&command, &zero, sizeof(command)) == 0);
    }
    packet[length] = 0;
    CHECK(protocol_parse_command(packet, length + 1, &command) == PROTOCOL_INVALID_PAYLOAD);
    length = wifi_packet(packet, "TestAP", "");
    CHECK(protocol_parse_command(packet, length, &command) == PROTOCOL_OK);
    length = wifi_packet(packet, "", "");
    memset(&command, 0xA5, sizeof(command));
    CHECK(protocol_parse_command(packet, length, &command) == PROTOCOL_OK);
    CHECK(command.code == CMD_WIFI_CONFIG_PUT);
    CHECK(memcmp(&command.wifi, &zero.wifi, sizeof(command.wifi)) == 0);
    length = wifi_packet(packet, "", "abcdefgh");
    check_invalid_command(packet, length, PROTOCOL_INVALID_PAYLOAD);
    length = wifi_packet(packet, "TestAP", "1234567");
    CHECK(protocol_parse_command(packet, length, &command) == PROTOCOL_INVALID_PAYLOAD);
    length = wifi_packet(packet, "Test\nAP", "abcdefgh");
    CHECK(protocol_parse_command(packet, length, &command) == PROTOCOL_INVALID_PAYLOAD);

    char ssid[WIFI_SSID_CAPACITY + 1];
    char password[WIFI_PASSWORD_CAPACITY + 1];
    memset(ssid, 'S', WIFI_SSID_MAX_BYTES);
    ssid[WIFI_SSID_MAX_BYTES] = '\0';
    memset(password, 'a', WIFI_PASSWORD_MAX_BYTES);
    password[WIFI_PASSWORD_MAX_BYTES] = '\0';
    length = wifi_packet(packet, ssid, password);
    CHECK(length == COMMAND_MAX_BYTES);
    CHECK(protocol_parse_command(packet, length, &command) == PROTOCOL_OK);
    CHECK(strlen(command.wifi.ssid) == WIFI_SSID_MAX_BYTES);
    CHECK(strlen(command.wifi.password) == WIFI_PASSWORD_MAX_BYTES);
    CHECK(strcmp(command.wifi.ssid, ssid) == 0);
    CHECK(strcmp(command.wifi.password, password) == 0);
    password[0] = 'G';
    CHECK(protocol_parse_command(packet, wifi_packet(packet, ssid, password), &command)
          == PROTOCOL_INVALID_PAYLOAD);
    password[WIFI_PASSWORD_MAX_BYTES - 1] = '\0';
    CHECK(protocol_parse_command(packet, wifi_packet(packet, ssid, password), &command)
          == PROTOCOL_OK);
    ssid[WIFI_SSID_MAX_BYTES] = 'S';
    ssid[WIFI_SSID_MAX_BYTES + 1] = '\0';
    CHECK(protocol_parse_command(packet, wifi_packet(packet, ssid, password), &command)
          != PROTOCOL_OK);
    CHECK(!protocol_wifi_credentials_valid(NULL));
    firmware_wifi_credentials_t unterminated;
    memset(&unterminated, 'a', sizeof(unterminated));
    CHECK(!protocol_wifi_credentials_valid(&unterminated));
    for (unsigned code = 0; code <= 255; ++code) {
        CHECK(protocol_command_allowed_over_udp((uint8_t)code) ==
              (code <= CMD_FLASH_OFF || code == CMD_RESTART ||
               code == CMD_SHUTDOWN || code == CMD_CONNECTION_STATUS ||
               code == CMD_REBOOT || code == CMD_UDP_KEEPALIVE ||
               code == CMD_SET_VIDEO_PROFILE));
    }
    const uint8_t ble_setup_codes[] = {
        CMD_FLASH_ON, CMD_FLASH_OFF, CMD_RESTART, CMD_SHUTDOWN,
        CMD_WIFI_CONFIG_PUT, CMD_WIFI_CONFIG_GET, CMD_CONNECTION_STATUS,
        CMD_BLE_PAIR, CMD_REBOOT,
    };
    for (unsigned code = 0; code <= 255; ++code) {
        bool allowed = false;
        for (size_t i = 0; i < sizeof(ble_setup_codes); ++i) {
            if (ble_setup_codes[i] == code) allowed = true;
        }
        CHECK(protocol_command_allowed_over_ble_setup((uint8_t)code) == allowed);
    }
}

static void test_jpeg(void)
{
    const uint8_t jpeg[] = {0xFF, 0xD8, 0x00, 0xAA, 0xFF, 0xD9};
    CHECK(protocol_jpeg_valid(jpeg, sizeof(jpeg)));
    CHECK(!protocol_jpeg_valid(NULL, sizeof(jpeg)));
    CHECK(!protocol_jpeg_valid(jpeg, MAX_FRAME_BYTES + 1));
    for (size_t prefix = 0; prefix < sizeof(jpeg); ++prefix) {
        CHECK(!protocol_jpeg_valid(jpeg, prefix));
    }
    uint8_t wrong[sizeof(jpeg)];
    memcpy(wrong, jpeg, sizeof(jpeg));
    wrong[0] = 0;
    CHECK(!protocol_jpeg_valid(wrong, sizeof(wrong)));
    memcpy(wrong, jpeg, sizeof(jpeg));
    wrong[sizeof(wrong) - 1] = 0;
    CHECK(!protocol_jpeg_valid(wrong, sizeof(wrong)));
}

/* Independent decoder matching the companion app's wire contract. */
static uint32_t read_u32_le(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void test_udp(void)
{
    uint8_t packet[UDP_MTU_SAFE];
    size_t packet_len;
    const uint8_t frame[] = {0xFF, 0xD8, 0xFF, 0xD9};
    const uint32_t frame_id = 42U;
    const uint8_t expected[] = {
        0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0,
        42, 0, 0, 0, 4, 0, 0, 0, 0xFF, 0xD8, 0xFF, 0xD9,
    };
    CHECK(protocol_udp_encode_packet(frame, sizeof(frame), frame_id, 0,
                                     packet, sizeof(packet), &packet_len));
    CHECK(packet_len == sizeof(expected));
    CHECK(memcmp(packet, expected, sizeof(expected)) == 0);
    CHECK(!protocol_udp_encode_packet(NULL, 4, frame_id, 0, packet, sizeof(packet), &packet_len));
    CHECK(packet_len == 0);
    CHECK(!protocol_udp_encode_packet(frame, 4, frame_id, 0, NULL, sizeof(packet), &packet_len));
    CHECK(!protocol_udp_encode_packet(frame, 0, frame_id, 0, packet, sizeof(packet), &packet_len));
    CHECK(!protocol_udp_encode_packet(frame, MAX_FRAME_BYTES + 1, frame_id, 0, packet, sizeof(packet), &packet_len));
    CHECK(!protocol_udp_encode_packet(frame, 4, frame_id, 1, packet, sizeof(packet), &packet_len));
    CHECK(!protocol_udp_encode_packet(frame, 4, frame_id, 0, packet, sizeof(packet), NULL));
    memset(packet, 0xA5, sizeof(packet));
    CHECK(!protocol_udp_encode_packet(frame, 4, frame_id, 0, packet, sizeof(expected) - 1, &packet_len));
    for (size_t i = 0; i < sizeof(packet); ++i) {
        CHECK(packet[i] == 0xA5);
    }

    uint8_t parity[UDP_PAYLOAD_BYTES] = {0};
    CHECK(protocol_udp_encode_parity_packet(
        parity, sizeof(parity), sizeof(frame), frame_id, 0, 1,
        packet, sizeof(packet), &packet_len));
    CHECK(packet_len == UDP_HEADER_LEN + UDP_PAYLOAD_BYTES);
    CHECK(read_u32_le(packet) == (UDP_PARITY_SEQUENCE_FLAG | 0U));
    CHECK(read_u32_le(packet + 4) == 1U);
    CHECK(read_u32_le(packet + 8) == 0U);
    CHECK(read_u32_le(packet + 12) == UDP_PAYLOAD_BYTES);
    CHECK(read_u32_le(packet + 16) == frame_id);
    CHECK(read_u32_le(packet + 20) == sizeof(frame));

    /* Larger frames retain four strided groups: group one covers 1, 5, 9... . */
    const size_t strided_frame_len = 6U * UDP_PAYLOAD_BYTES + 1U;
    CHECK(protocol_udp_encode_parity_packet(
        parity, sizeof(parity), strided_frame_len, frame_id, 1, 7,
        packet, sizeof(packet), &packet_len));
    CHECK(read_u32_le(packet) == (UDP_PARITY_SEQUENCE_FLAG | 1U));
    CHECK(read_u32_le(packet + 4) == 7U);
    CHECK(read_u32_le(packet + 8) == UDP_PAYLOAD_BYTES);
    CHECK(read_u32_le(packet + 20) == strided_frame_len);
    CHECK(!protocol_udp_encode_parity_packet(
        parity, sizeof(parity), 2U * UDP_PAYLOAD_BYTES + 1U, frame_id, 1, 3,
        packet, sizeof(packet), &packet_len));

    CHECK(!protocol_udp_encode_parity_packet(
        parity, sizeof(parity) - 1, sizeof(frame), frame_id, 0, 1,
        packet, sizeof(packet), &packet_len));

    const size_t payload = UDP_PAYLOAD_BYTES;
    CHECK(protocol_udp_packet_count(0) == 0);
    CHECK(protocol_udp_packet_count(payload) == 1);
    CHECK(protocol_udp_packet_count(payload + 1) == 2);
    CHECK(UDP_HEADER_LEN + UDP_PAYLOAD_BYTES == UDP_MTU_SAFE);
    CHECK(protocol_udp_packet_count(2893U) == 2U);
    CHECK(protocol_udp_packet_count(MAX_FRAME_BYTES + 1) == 0);
    const size_t lengths[] = {
        1, 3, 4, 959, 960, 961, 4096, 16384, MAX_FRAME_BYTES
    };
    for (size_t test = 0; test < sizeof(lengths) / sizeof(lengths[0]); ++test) {
        size_t length = lengths[test];
        uint8_t *source = malloc(length);
        uint8_t *decoded = calloc(length, 1);
        CHECK(source != NULL && decoded != NULL);
        for (size_t i = 0; i < length; ++i) {
            source[i] = (uint8_t)((i * 37U + 11U) & 0xFFU);
        }
        size_t count = protocol_udp_packet_count(length);
        size_t offset = 0;
        for (size_t seq = 0; seq < count; ++seq) {
            CHECK(protocol_udp_encode_packet(source, length, frame_id, seq,
                                             packet, sizeof(packet), &packet_len));
            CHECK(read_u32_le(packet) == seq);
            CHECK(read_u32_le(packet + 4) == count);
            CHECK(read_u32_le(packet + 8) == offset);
            CHECK(read_u32_le(packet + 16) == frame_id);
            CHECK(read_u32_le(packet + 20) == length);
            size_t bytes = read_u32_le(packet + 12);
            CHECK(packet_len == UDP_HEADER_LEN + bytes);
            CHECK(packet_len <= UDP_MTU_SAFE);
            CHECK(offset + bytes <= length);
            memcpy(decoded + offset, packet + UDP_HEADER_LEN, bytes);
            offset += bytes;
        }
        CHECK(offset == length);
        CHECK(memcmp(source, decoded, length) == 0);
        free(source);
        free(decoded);
    }
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        return EXIT_FAILURE;
    }
    if (strcmp(argv[1], "commands") == 0) {
        test_commands();
    } else if (strcmp(argv[1], "jpeg") == 0) {
        test_jpeg();
    } else if (strcmp(argv[1], "udp") == 0) {
        test_udp();
    } else {
        return EXIT_FAILURE;
    }
    printf("%s: %u checks passed\n", argv[1], checks);
    return EXIT_SUCCESS;
}
