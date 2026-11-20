#include <string.h>
#include <inttypes.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_random.h"
#include "esp_heap_caps.h"
#include "lwip/sockets.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "udp_stream.h"

static const char *TAG = "UDP_STREAM";

static int s_sock = -1;
static bool s_started = false;

static esp_ip_addr_t s_app_ip;
static uint16_t s_app_port = 0;
static bool s_app_peer_known = false;
static uint32_t s_next_frame_id;

bool udp_stream_has_peer(void) { return s_app_peer_known && s_started; }

void udp_stream_clear_peer(void)
{
    s_app_peer_known = false;
    s_app_port = 0;
    memset(&s_app_ip, 0, sizeof(s_app_ip));
}

esp_err_t udp_stream_start(void)
{
    if (s_started) return ESP_OK;

    s_sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
    if (s_sock < 0) {
        ESP_LOGE(TAG, "Failed to create UDP socket");
        return ESP_FAIL;
    }

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(UDP_VIDEO_PORT);

    if (bind(s_sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        ESP_LOGE(TAG, "UDP bind failed: errno=%d", errno);
        close(s_sock);
        s_sock = -1;
        return ESP_FAIL;
    }

    int flags = fcntl(s_sock, F_GETFL, 0);
    if (flags < 0 || fcntl(s_sock, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(s_sock);
        s_sock = -1;
        return ESP_FAIL;
    }

    int rcvbuf = UDP_RCVBUF_BYTES;
    if (setsockopt(s_sock, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf)) < 0) {
        ESP_LOGW(TAG, "UDP SO_RCVBUF failed: errno=%d", errno);
    }

    s_next_frame_id = esp_random();
    s_started = true;
    ESP_LOGI(TAG, "UDP socket bound on port %d rcvbuf=%d",
             UDP_VIDEO_PORT, rcvbuf);
    return ESP_OK;
}

void udp_stream_stop(void)
{
    if (s_sock >= 0) {
        close(s_sock);
        s_sock = -1;
    }
    s_started = false;
    udp_stream_clear_peer();
}

bool udp_stream_send_control(const uint8_t *data, size_t len)
{
    if (data == NULL || len == 0 || len > STATUS_TEXT_CAPACITY ||
        !s_started || s_sock < 0 || !s_app_peer_known) {
        return false;
    }

    struct sockaddr_in destination = {0};
    destination.sin_family = AF_INET;
    destination.sin_port = htons(s_app_port);
    destination.sin_addr.s_addr = s_app_ip.u_addr.ip4.addr;

    int sent = -1;
    unsigned attempts = 0;
    while (attempts < UDP_CONTROL_SEND_ATTEMPTS) {
        ++attempts;
        sent = sendto(s_sock, data, len, 0,
                      (const struct sockaddr *)&destination,
                      sizeof(destination));
        if (sent == (int)len) break;
        bool transient = sent < 0 &&
            (errno == ENOMEM || errno == ENOBUFS ||
             errno == EAGAIN || errno == EWOULDBLOCK);
        if (!transient || attempts == UDP_CONTROL_SEND_ATTEMPTS) break;
        vTaskDelay(pdMS_TO_TICKS(UDP_CONTROL_RETRY_DELAY_MS));
    }
    if (sent != (int)len) {
        ESP_LOGW(TAG,
                 "operation=udp.control_send outcome=failure errno=%d sent=%d expected=%zu attempts=%u",
                 sent < 0 ? errno : 0, sent, len, attempts);
        return false;
    }

    /* Control datagrams are tiny and idempotent. A spaced duplicate makes
     * peer registration/status robust against an occasional Wi-Fi TX loss
     * without changing the application wire protocol. */
    vTaskDelay(pdMS_TO_TICKS(UDP_CONTROL_DUPLICATE_DELAY_MS));
    int repeated = sendto(s_sock, data, len, 0,
                          (const struct sockaddr *)&destination,
                          sizeof(destination));
    if (repeated != (int)len) {
        ESP_LOGW(TAG,
                 "operation=udp.control_repeat outcome=partial errno=%d sent=%d expected=%zu",
                 repeated < 0 ? errno : 0, repeated, len);
    }
    return true;
}

static bool send_datagram(const struct sockaddr_in *destination,
                          const uint8_t *packet, size_t packet_len,
                          int64_t deadline, uint32_t frame_id,
                          uint32_t sequence, bool parity, uint32_t packet_pace_ms)
{
    unsigned attempts = 0;
    int result = -1;
    int send_errno = 0;
    while (attempts < UDP_SEND_MAX_ATTEMPTS &&
           esp_timer_get_time() < deadline) {
        ++attempts;
        result = sendto(s_sock, packet, packet_len, 0,
                        (const struct sockaddr *)destination,
                        sizeof(*destination));
        send_errno = result < 0 ? errno : 0;
        if (result == (int)packet_len) {
            /* Yield after every datagram so the Wi-Fi driver can drain its
             * bounded TX pool instead of accepting a whole frame in a burst. */
            if (packet_pace_ms > 0U) {
                vTaskDelay(pdMS_TO_TICKS(packet_pace_ms));
            }
            return true;
        }
        bool transient = result < 0 &&
            (send_errno == ENOMEM || send_errno == ENOBUFS ||
             send_errno == EAGAIN || send_errno == EWOULDBLOCK);
        if (!transient) {
            break;
        }
        if (attempts < UDP_SEND_MAX_ATTEMPTS) {
            uint32_t delay_ms = UDP_SEND_RETRY_DELAY_MS << (attempts - 1U);
            if (delay_ms > UDP_SEND_RETRY_MAX_DELAY_MS) {
                delay_ms = UDP_SEND_RETRY_MAX_DELAY_MS;
            }
            vTaskDelay(pdMS_TO_TICKS(delay_ms));
        }
    }

    const char *code = esp_timer_get_time() >= deadline
        ? "UDP_SEND_DEADLINE"
        : result < 0 ? "UDP_SEND_SOCKET_ERROR" : "UDP_SEND_SHORT_WRITE";
    ESP_LOGW(TAG,
             "operation=udp.send outcome=failure code=%s errno=%d frame=%" PRIu32
             " packet=%s seq=%" PRIu32 " bytes=%zu result=%d attempts=%u"
             " heap=%zu largest=%zu",
             code, send_errno, frame_id, parity ? "parity" : "data", sequence,
             packet_len, result, attempts,
             heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT),
             heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
    return false;
}

bool udp_stream_send_frame(const uint8_t *jpeg, size_t len, uint32_t packet_pace_ms)
{
    static int64_t log_window_started, last_frame_started;
    static uint32_t log_frames;

    if (!s_started || s_sock < 0 || !s_app_peer_known ||
        !protocol_jpeg_valid(jpeg, len)) {
        return false;
    }

    struct sockaddr_in destination = {0};
    destination.sin_family = AF_INET;
    destination.sin_port = htons(s_app_port);
    destination.sin_addr.s_addr = s_app_ip.u_addr.ip4.addr;

    const size_t total = protocol_udp_packet_count(len);
    if (total == 0 || total > UINT32_MAX) {
        return false;
    }
    const uint32_t frame_id = ++s_next_frame_id;
    const int64_t started = esp_timer_get_time();
    const int64_t deadline =
        started + UDP_FRAME_SEND_TIMEOUT_MS * 1000LL;
    if (last_frame_started != 0 &&
        started - last_frame_started > 1500000LL) {
        log_window_started = 0;
        log_frames = 0;
    }
    if (log_window_started == 0) log_window_started = started;
    last_frame_started = started;
    uint8_t packet[UDP_MTU_SAFE];
    uint8_t parity[UDP_PAYLOAD_BYTES];
    size_t packet_len = 0;
    size_t parity_packets = 0;

    /*
     * JPEG is already compressed by the OV2640 hardware. Send small data
     * datagrams in sequence order, then one XOR parity packet for each strided
     * group: {0,4,8...}, {1,5,9...}, etc. Consecutive Wi-Fi burst losses land
     * in different groups and can therefore be recovered independently.
     * Only one parity buffer is needed; the JPEG is revisited per group.
     */
    const size_t group_count = total < UDP_FEC_GROUP_SIZE
        ? total : UDP_FEC_GROUP_SIZE;
    for (size_t sequence = 0; sequence < total; ++sequence) {
        if (!protocol_udp_encode_packet(jpeg, len, frame_id, sequence,
                                        packet, sizeof(packet), &packet_len) ||
            !send_datagram(&destination, packet, packet_len, deadline,
                           frame_id, (uint32_t)sequence, false, packet_pace_ms)) {
            return false;
        }
    }

    for (size_t group_index = 0; group_index < group_count; ++group_index) {
        memset(parity, 0, sizeof(parity));
        for (size_t sequence = group_index; sequence < total;
             sequence += UDP_FEC_GROUP_SIZE) {
            const size_t offset = sequence * UDP_PAYLOAD_BYTES;
            size_t chunk_len = len - offset;
            if (chunk_len > UDP_PAYLOAD_BYTES) {
                chunk_len = UDP_PAYLOAD_BYTES;
            }
            for (size_t i = 0; i < chunk_len; ++i) {
                parity[i] ^= jpeg[offset + i];
            }
        }
        if (!protocol_udp_encode_parity_packet(
                parity, sizeof(parity), len, frame_id, group_index, total,
                packet, sizeof(packet), &packet_len) ||
            !send_datagram(&destination, packet, packet_len, deadline,
                           frame_id, (uint32_t)group_index, true, packet_pace_ms)) {
            return false;
        }
        ++parity_packets;
    }

    const int64_t completed = esp_timer_get_time();
    if (++log_frames >= 128U) {
        const int64_t elapsed_us = completed - log_window_started;
        if (elapsed_us > 0) {
            const uint32_t fps_x100 = (uint32_t)(
                (uint64_t)log_frames * 100000000ULL / (uint64_t)elapsed_us);
            (void)fps_x100;
            ESP_LOGI(TAG,
                     "operation=udp.stream frames=%" PRIu32
                     " fps_x100=%" PRIu32
                     " last_bytes=%zu fragments=%zu parity=%zu",
                     log_frames, fps_x100, len, total, parity_packets);
        }
        log_window_started = completed;
        log_frames = 0;
    }
    return true;
}

bool udp_stream_receive_command(firmware_command_t *out)
{
    if (out == NULL || !s_started || s_sock < 0) {
        return false;
    }
    for (unsigned received = 0; received < UDP_POLL_MAX_PACKETS; ++received) {
        struct sockaddr_in src_addr = {0};
        socklen_t src_len = sizeof(src_addr);
        uint8_t buf[2];
        int n = recvfrom(s_sock, buf, sizeof(buf), 0,
                         (struct sockaddr *)&src_addr, &src_len);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            ESP_LOGW(TAG, "UDP recvfrom failed: errno=%d", errno);
            break;
        }
        ESP_LOGI(TAG,
                 "operation=udp.rx bytes=%d src_port=%u first=0x%02x",
                 n, (unsigned)ntohs(src_addr.sin_port),
                 n > 0 ? (unsigned)buf[0] : 0U);
        if (n != 1 || !protocol_command_allowed_over_udp(buf[0]) ||
            protocol_parse_command(buf, (size_t)n, out) != PROTOCOL_OK) {
            ESP_LOGW(TAG, "operation=udp.command.reject bytes=%d", n);
            continue;
        }
        esp_ip_addr_t src_ip = {
            .u_addr.ip4.addr = src_addr.sin_addr.s_addr,
            .type = ESP_IPADDR_TYPE_V4,
        };
        uint16_t src_port = ntohs(src_addr.sin_port);
        if (out->code == CMD_STREAM_ON || out->code == CMD_SINGLE_FRAME ||
            out->code == CMD_UDP_KEEPALIVE) {
            bool changed = !s_app_peer_known ||
                src_ip.u_addr.ip4.addr != s_app_ip.u_addr.ip4.addr ||
                src_port != s_app_port;
            udp_stream_set_app_peer(&src_ip, src_port);
            if (changed) {
                /* The echo resolves ARP before the first frame. Keepalive
                 * uses the same path to re-register a peer after WiFi recovery. */
                int sent = sendto(s_sock, buf, 1, 0,
                                   (struct sockaddr *)&src_addr, src_len);
                if (sent < 0) {
                    ESP_LOGW(TAG, "operation=udp.peer_probe errno=%d", errno);
                }
                vTaskDelay(pdMS_TO_TICKS(UDP_PEER_SETTLE_MS));
            }
        } else if (!s_app_peer_known ||
                   src_ip.u_addr.ip4.addr != s_app_ip.u_addr.ip4.addr ||
                   src_port != s_app_port) {
            continue;
        }
        return true;
    }
    return false;
}

void udp_stream_set_app_peer(const esp_ip_addr_t *ip, uint16_t port)
{
    if (ip == NULL || ip->type != ESP_IPADDR_TYPE_V4 ||
        ip->u_addr.ip4.addr == 0 || port == 0) {
        return;
    }
    if (s_app_peer_known &&
        s_app_ip.u_addr.ip4.addr == ip->u_addr.ip4.addr &&
        s_app_port == port)
        return;

    s_app_ip = *ip;
    s_app_port = port;
    s_app_peer_known = true;
    ESP_LOGI(TAG, "App peer: " IPSTR ":%d", IP2STR(&s_app_ip.u_addr.ip4), port);
}

esp_ip_addr_t udp_stream_app_address(void)
{
    return s_app_ip;
}
