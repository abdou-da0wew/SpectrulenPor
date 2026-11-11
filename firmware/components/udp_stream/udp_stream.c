#include <string.h>
#include <fcntl.h>
#include "esp_log.h"
#include "lwip/sockets.h"
#include "lwip/err.h"
#include "lwip/sys.h"
#include "udp_stream.h"
#include "wifi.h"
#include "ble.h"

static const char *TAG = "UDP_STREAM";

static int s_sock = -1;
static bool s_started = false;

static esp_ip_addr_t s_app_ip;
static uint16_t s_app_port = 0;
static bool s_app_peer_known = false;

static uint32_t g_seq = 0;

/* -----------------------------------------------------------------------
 *  Start UDP socket
 * --------------------------------------------------------------------- */
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

    /* Non-blocking so tx + rx polling won't block. */
    fcntl(s_sock, F_SETFL, O_NONBLOCK);

    s_started = true;
    ESP_LOGI(TAG, "UDP socket bound on port %d", UDP_VIDEO_PORT);
    return ESP_OK;
}

void udp_stream_stop(void)
{
    if (s_sock >= 0) {
        close(s_sock);
        s_sock = -1;
    }
    s_started = false;
}

/* -----------------------------------------------------------------------
 *  Send one JPEG frame (chunked into MTU-safe UDP packets)
 * --------------------------------------------------------------------- */
bool udp_stream_send_frame(const uint8_t *jpeg, size_t len)
{
    if (!s_started || s_sock < 0) return false;

    esp_ip_addr_t dest = s_app_peer_known ? s_app_ip : *IP_ADDR_BROADCAST;
    uint16_t port = s_app_port ? s_app_port : UDP_VIDEO_PORT;

    struct sockaddr_in dest_addr = {0};
    dest_addr.sin_family = AF_INET;
    dest_addr.sin_port = htons(port);
    memcpy(&dest_addr.sin_addr, ip_2_ip4(&dest)->addr, 4);

    g_seq++;
    size_t chunk_payload = UDP_MTU_SAFE - UDP_HEADER_LEN;
    uint32_t total = (len + chunk_payload - 1) / chunk_payload;
    if (total == 0) total = 1;

    size_t off = 0;
    uint32_t seq = 0;
    while (off < len) {
        size_t chunk = (off + chunk_payload <= len) ? chunk_payload : (len - off);

        uint8_t pkt[UDP_MTU_SAFE];
        udp_frame_hdr_t *h = (udp_frame_hdr_t *)pkt;
        h->seq = seq;
        h->total = total;
        h->offset = (uint32_t)off;
        h->size = (uint32_t)chunk;
        memcpy(pkt + UDP_HEADER_LEN, jpeg + off, chunk);

        int rc = sendto(s_sock, pkt, UDP_HEADER_LEN + chunk, 0,
                        (struct sockaddr *)&dest_addr, sizeof(dest_addr));
        if (rc < 0) {
            ESP_LOGW(TAG, "UDP sendto failed: errno=%d", errno);
        }

        off += chunk;
        seq++;
    }
    return true;
}

/* -----------------------------------------------------------------------
 *  Poll rx socket for app datagrams
 * --------------------------------------------------------------------- */
void udp_stream_poll(void)
{
    if (!s_started || s_sock < 0) return;

    struct sockaddr_in src_addr;
    socklen_t src_len = sizeof(src_addr);
    uint8_t buf[64];

    while (1) {
        int n = recvfrom(s_sock, buf, sizeof(buf), 0,
                         (struct sockaddr *)&src_addr, &src_len);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            ESP_LOGW(TAG, "UDP recvfrom failed: errno=%d", errno);
            break;
        }
        if (n == 0) break;

        esp_ip_addr_t src_ip;
        memcpy(ip_2_ip4(&src_ip)->addr, &src_addr.sin_addr, 4);
        uint16_t src_port = ntohs(src_addr.sin_port);

        /* Record app peer for unicast video. */
        udp_stream_set_app_peer(&src_ip, src_port);

        /* First byte = command (mirrors BLE command set). */
        uint8_t cmd = buf[0];
        switch (cmd) {
        case CMD_STREAM_ON:
            ESP_LOGI(TAG, "UDP cmd: stream on");
            break;
        case CMD_STREAM_OFF:
            ESP_LOGI(TAG, "UDP cmd: stream off");
            break;
        case CMD_SINGLE_FRAME:
            ESP_LOGI(TAG, "UDP cmd: single frame");
            break;
        case CMD_FLASH_ON:
        case CMD_FLASH_OFF:
            /* Typically handled via BLE; ignore duplicates here. */
            break;
        default:
            break;
        }
    }
}

/* -----------------------------------------------------------------------
 *  Peer accessors
 * --------------------------------------------------------------------- */
void udp_stream_set_app_peer(const esp_ip_addr_t *ip, uint16_t port)
{
    if (s_app_peer_known && s_app_ip.addr == ip->addr && s_app_port == port)
        return;

    s_app_ip = *ip;
    s_app_port = port;
    s_app_peer_known = true;
    ESP_LOGI(TAG, "App peer: " IPSTR ":%d", IP2STR(&s_app_ip), port);
}

esp_ip_addr_t udp_stream_app_address(void)
{
    return s_app_ip;
}
