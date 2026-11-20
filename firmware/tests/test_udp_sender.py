"""Exercise the actual UDP sender with a deterministic clock and socket spies."""

import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


FIRMWARE_ROOT = Path(__file__).resolve().parents[1]
STRICT_FLAGS = ("-std=c11", "-Wall", "-Wextra", "-Werror", "-Wpedantic",
                "-Wconversion", "-Wshadow")
HOST_STUBS = r"""
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <inttypes.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include "protocol.h"

static bool s_started = true, s_app_peer_known = true;
static int s_sock = 1;
static uint32_t s_next_frame_id = 100;
static uint16_t s_app_port = UDP_VIDEO_PORT;
static struct { struct { struct { uint32_t addr; } ip4; } u_addr; } s_app_ip;
static const char *TAG = "HOST";
static int scenario;
static int64_t now;
static unsigned clock_calls, send_calls, delay_calls;
static uint32_t sent_sequences[64];
static unsigned captured_sequences;
static char log_text[1024];
enum { MALLOC_CAP_INTERNAL = 1, MALLOC_CAP_8BIT = 2 };

static void host_log(const char *tag, const char *format, ...)
{
    (void)tag;
    va_list arguments;
    va_start(arguments, format);
    (void)vsnprintf(log_text, sizeof(log_text), format, arguments);
    va_end(arguments);
}
#define ESP_LOGW(tag, ...) host_log(tag, __VA_ARGS__)
#define ESP_LOGI(tag, ...) ((void)0)
#define pdMS_TO_TICKS(value) (value)
static size_t heap_caps_get_free_size(unsigned caps) { (void)caps; return 100000; }
static size_t heap_caps_get_largest_free_block(unsigned caps) { (void)caps; return 98000; }
static int64_t esp_timer_get_time(void)
{
    ++clock_calls;
    if (scenario == 1 && clock_calls > 1) now = UDP_FRAME_SEND_TIMEOUT_MS * 1000LL;
    return now;
}
static void vTaskDelay(unsigned ticks)
{
    ++delay_calls;
    now += (int64_t)ticks * 1000;
    if (scenario == 2 && send_calls == 1) now = UDP_FRAME_SEND_TIMEOUT_MS * 1000LL;
}
static int host_sendto(int socket, const void *packet, size_t length, int flags,
                           const struct sockaddr *address, socklen_t address_length)
{
    (void)socket; (void)packet; (void)flags; (void)address; (void)address_length;
    ++send_calls;
    if (scenario == 3 || (scenario == 6 && send_calls < 3)) {
        errno = ENOMEM;
        return -1;
    }
    if (scenario == 4) { errno = EHOSTUNREACH; return -1; }
    if (scenario == 5) return (int)length - 1;
    if (captured_sequences < sizeof(sent_sequences) / sizeof(sent_sequences[0]) && length >= 4U) {
        const uint8_t *bytes = packet;
        sent_sequences[captured_sequences++] =
            (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8U) |
            ((uint32_t)bytes[2] << 16U) | ((uint32_t)bytes[3] << 24U);
    }
    return (int)length;
}
#define sendto host_sendto
"""
HOST_ASSERTIONS = r"""
static void expect(bool condition, const char *reason)
{
    if (!condition) {
        fprintf(stderr, "%s: sends=%u delays=%u time=%lld log=%s\n", reason,
                send_calls, delay_calls, (long long)now, log_text);
        exit(EXIT_FAILURE);
    }
}
int main(int argc, char **argv)
{
    if (argc != 2) return EXIT_FAILURE;
    scenario = atoi(argv[1]);
    uint8_t jpeg[UDP_PAYLOAD_BYTES * 9U + JPEG_MIN_BYTES] = {0xff, 0xd8};
    const size_t jpeg_len = scenario == 8 ? sizeof(jpeg) : UDP_PAYLOAD_BYTES + JPEG_MIN_BYTES;
    jpeg[jpeg_len - 2] = 0xff;
    jpeg[jpeg_len - 1] = 0xd9;
    bool sent = udp_stream_send_frame(jpeg, jpeg_len, 4U);
    switch (scenario) {
    case 0:
        expect(sent && send_calls == 4 && log_text[0] == '\0', "successful frame includes data plus XOR parity");
        break;
    case 1:
        expect(!sent && send_calls == 0, "deadline before first attempt");
        expect(strstr(log_text, "code=UDP_SEND_DEADLINE") != NULL &&
               strstr(log_text, "attempts=0") != NULL && strstr(log_text, "seq=0 ") != NULL,
               "unattempted deadline must not be a socket failure");
        break;
    case 2:
        expect(!sent && send_calls == 1, "deadline between fragments");
        expect(strstr(log_text, "code=UDP_SEND_DEADLINE") != NULL &&
               strstr(log_text, "attempts=0") != NULL && strstr(log_text, "seq=1 ") != NULL,
               "next fragment expiry preserves no-attempt evidence");
        break;
    case 3:
        expect(!sent && send_calls == UDP_SEND_MAX_ATTEMPTS, "resource retries are bounded");
        expect(strstr(log_text, "code=UDP_SEND_SOCKET_ERROR") != NULL &&
               strstr(log_text, "errno=12 ") != NULL && strstr(log_text, "result=-1 ") != NULL &&
               strstr(log_text, "attempts=16") != NULL,
               "transient socket exhaustion retains final failure evidence");
        break;
    case 4:
        expect(!sent && send_calls == 1 && delay_calls == 0, "fatal error is not retried");
        expect(strstr(log_text, "code=UDP_SEND_SOCKET_ERROR") != NULL &&
               strstr(log_text, "attempts=1") != NULL, "fatal socket error identity");
        break;
    case 5:
        expect(!sent && send_calls == 1 && delay_calls == 0, "short datagram is not retried");
        expect(strstr(log_text, "code=UDP_SEND_SHORT_WRITE") != NULL,
               "short datagram identity");
        break;
    case 6:
        expect(sent && send_calls == 6 && log_text[0] == '\0', "transient retry recovers then sends parity");
        break;
    case 7: {
        unsigned before = send_calls;
        s_started = false;
        expect(!udp_stream_send_frame(jpeg, jpeg_len, 4U) && send_calls == before,
               "inactive sender performs no additional I/O");
        break;
    }
    case 8: {
        static const uint32_t expected[] = {
            0U, 1U, 2U, 3U, 4U, 5U, 6U, 7U, 8U, 9U,
            UDP_PARITY_SEQUENCE_FLAG | 0U,
            UDP_PARITY_SEQUENCE_FLAG | 1U,
            UDP_PARITY_SEQUENCE_FLAG | 2U,
            UDP_PARITY_SEQUENCE_FLAG | 3U,
        };
        expect(sent && send_calls == 14U && captured_sequences == 14U,
               "multi-group frame sends ten data packets and four strided parity packets");
        for (size_t i = 0; i < sizeof(expected) / sizeof(expected[0]); ++i) {
            expect(sent_sequences[i] == expected[i], "data packets are interleaved across FEC groups");
        }
        break;
    }
    default: return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
"""


class UdpSenderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shlex.split(os.environ.get("CC", "cc"))
        if not compiler or shutil.which(compiler[0]) is None:
            raise RuntimeError("Host C compiler required for the UDP sender regression")
        directory = tempfile.TemporaryDirectory(prefix="spectrulenpor-udp-sender-")
        cls.addClassCleanup(directory.cleanup)
        source = (FIRMWARE_ROOT / "components/udp_stream/udp_stream.c").read_text()
        start = source.index("\nstatic bool send_datagram(")
        end = source.index("\nbool udp_stream_receive_command(", start)
        harness = Path(directory.name) / "udp_sender.c"
        cls.binary = harness.with_suffix("")
        harness.write_text(HOST_STUBS + source[start:end] + HOST_ASSERTIONS)
        built = subprocess.run(compiler + list(STRICT_FLAGS) + [
            "-I", str(FIRMWARE_ROOT), "-I", str(FIRMWARE_ROOT / "components/protocol"),
            str(harness), str(FIRMWARE_ROOT / "components/protocol/protocol.c"),
            "-o", str(cls.binary)], capture_output=True, text=True, timeout=30)
        if built.returncode:
            raise AssertionError("Host UDP harness failed to compile:\n" + built.stdout + built.stderr)

    def assert_sender_result(self, scenario):
        process = subprocess.run([str(self.binary), str(scenario)], capture_output=True,
                                 text=True, timeout=5)
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)

    def test_successful_frame(self):
        self.assert_sender_result(0)

    def test_deadline_before_first_attempt(self):
        self.assert_sender_result(1)

    def test_deadline_between_fragments(self):
        self.assert_sender_result(2)

    def test_deadline_during_resource_retry(self):
        self.assert_sender_result(3)

    def test_non_transient_socket_error(self):
        self.assert_sender_result(4)

    def test_short_datagram(self):
        self.assert_sender_result(5)

    def test_transient_retry_recovery(self):
        self.assert_sender_result(6)

    def test_inactive_sender(self):
        self.assert_sender_result(7)

    def test_data_packets_are_interleaved_across_fec_groups(self):
        self.assert_sender_result(8)


if __name__ == "__main__":
    unittest.main()
