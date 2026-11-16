#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include "esp_log.h"
#include "esp_timer.h"
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

    int sndbuf = UDP_SNDBUF_BYTES;
    int rcvbuf = UDP_RCVBUF_BYTES;
    if (setsockopt(s_sock, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf)) < 0) {
        ESP_LOGW(TAG, "UDP SO_SNDBUF failed: errno=%d", errno);
    }
    if (setsockopt(s_sock, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf)) < 0) {
        ESP_LOGW(TAG, "UDP SO_RCVBUF failed: errno=%d", errno);
    }

    s_started = true;
    ESP_LOGI(TAG, "UDP socket bound on port %d sndbuf=%d rcvbuf=%d",
             UDP_VIDEO_PORT, sndbuf, rcvbuf);
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

bool udp_stream_send_frame(const uint8_t *jpeg, size_t len)
{
    if (!s_started || s_sock < 0 || !s_app_peer_known ||
        !protocol_jpeg_valid(jpeg, len)) {
        return false;
    }

    struct sockaddr_in dest_addr = {0};
    dest_addr.sin_family = AF_INET;
    dest_addr.sin_port = htons(s_app_port);
    dest_addr.sin_addr.s_addr = s_app_ip.u_addr.ip4.addr;
    size_t count = protocol_udp_packet_count(len);
    int64_t deadline = esp_timer_get_time() + UDP_FRAME_SEND_TIMEOUT_MS * 1000LL;
    for (size_t seq = 0; seq < count; ++seq) {
        uint8_t packet[UDP_MTU_SAFE];
        size_t packet_len;
        if (!protocol_udp_encode_packet(jpeg, len, seq, packet,
                                         sizeof(packet), &packet_len)) {
            return false;
        }
        for (unsigned copy = 0; copy < UDP_FRAGMENT_REDUNDANCY; ++copy) {
            if (copy > 0) {
                vTaskDelay(pdMS_TO_TICKS(UDP_SEND_RETRY_DELAY_MS));
            }
            int result = -1;
            int send_errno = 0;
            unsigned attempts = 0;
            bool deadline_expired = false;
            while (true) {
                if (esp_timer_get_time() >= deadline) {
                    deadline_expired = true;
                    break;
                }
                ++attempts;
                result = sendto(s_sock, packet, packet_len, 0,
                                 (struct sockaddr *)&dest_addr, sizeof(dest_addr));
                send_errno = result < 0 ? errno : 0;
                if (result >= 0 || (send_errno != ENOMEM && send_errno != ENOBUFS &&
                                     send_errno != EAGAIN && send_errno != EWOULDBLOCK)) {
                    break;
                }
                vTaskDelay(pdMS_TO_TICKS(UDP_SEND_RETRY_DELAY_MS));
            }
            if (result != (int)packet_len) {
                const char *code = deadline_expired ? "UDP_SEND_DEADLINE" :
                    result < 0 ? "UDP_SEND_SOCKET_ERROR" : "UDP_SEND_SHORT_WRITE";
                ESP_LOGW(TAG, "operation=udp.send outcome=failure code=%s errno=%d seq=%zu"
                         " total=%zu bytes=%zu result=%d attempts=%u heap=%zu largest=%zu",
                         code, send_errno, seq, count, packet_len, result, attempts,
                         heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT),
                         heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
                return false;
            }
            /* Let the WiFi driver drain the TX buffer before the next packet.
             * ESP-IDF recommends pacing sendto() calls to avoid ENOMEM when
             * static/dynamic TX buffers fill up during a burst. */
            vTaskDelay(pdMS_TO_TICKS(UDP_SEND_PACE_MS));
        }
        vTaskDelay(pdMS_TO_TICKS(UDP_PACKET_PACE_MS));
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
        if (n != 1 || !protocol_command_allowed_over_udp(buf[0]) ||
            protocol_parse_command(buf, (size_t)n, out) != PROTOCOL_OK) {
            continue;
        }
        esp_ip_addr_t src_ip = {
            .u_addr.ip4.addr = src_addr.sin_addr.s_addr,
            .type = ESP_IPADDR_TYPE_V4,
        };
        uint16_t src_port = ntohs(src_addr.sin_port);
        if (out->code == CMD_STREAM_ON || out->code == CMD_SINGLE_FRAME) {
            bool changed = !s_app_peer_known ||
                src_ip.u_addr.ip4.addr != s_app_ip.u_addr.ip4.addr ||
                src_port != s_app_port;
            udp_stream_set_app_peer(&src_ip, src_port);
            if (changed) {
                /* A short control echo is ignored by legacy frame receivers.
                 * It resolves ARP before the first JPEG fragment burst. */
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
