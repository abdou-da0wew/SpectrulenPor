import unittest

from testbench.settings import FRAME_EXPIRY_SECONDS
from testbench.transport import Reassembler, WIRE

PEER = ("192.168.1.100", WIRE.UDP_PORT)


def fragment(seq, total, data, offset=None, size=None):
    return WIRE.UDP_HEADER.pack(seq, total, seq * WIRE.UDP_PAYLOAD_BYTES if offset is None else offset,
                                len(data) if size is None else size) + data


class ReassemblyTests(unittest.TestCase):
    def setUp(self):
        self.now = 0
        self.parser = Reassembler(PEER, clock=lambda: self.now)

    def feed(self, packet, peer=PEER):
        return self.parser.feed(packet, peer)

    def test_actual_512_byte_wire_contract(self):
        first = b"a" * WIRE.UDP_PAYLOAD_BYTES
        last = b"b" * 10
        self.assertIsNone(self.feed(fragment(0, 2, first)))
        self.assertEqual(self.feed(fragment(1, 2, last)), (0, first + last))
        self.assertEqual(self.parser.packets, 2)
        self.assertFalse(self.parser.parts)

    def test_out_of_order_after_first_packet(self):
        chunks = [b"a" * 512, b"b" * 512, b"c" * 10]
        for seq in (0, 2):
            self.assertIsNone(self.feed(fragment(seq, 3, chunks[seq])))
        self.assertEqual(self.feed(fragment(1, 3, chunks[1]))[1], b"".join(chunks))

    def test_duplicate_first_and_last_chunks_do_not_reset(self):
        first = fragment(0, 3, b"a" * 512)
        middle = fragment(1, 3, b"b" * 512)
        self.feed(first)
        self.feed(middle)
        self.feed(first)
        self.feed(middle)
        self.assertEqual(self.feed(fragment(2, 3, b"c"))[1], b"a" * 512 + b"b" * 512 + b"c")
        self.assertEqual(self.parser.dropped_frames, 0)

    def test_conflicting_duplicate_invalidates(self):
        self.feed(fragment(0, 3, b"a" * 512))
        self.feed(fragment(1, 3, b"b" * 512))
        self.feed(fragment(1, 3, b"c" * 512))
        self.assertEqual(self.parser.protocol_errors, 1)
        self.assertEqual(self.parser.dropped_frames, 1)
        self.assertFalse(self.parser.parts)
        self.assertEqual(self.parser.last_incomplete["expected_chunks"], 3)
        self.assertEqual(self.parser.last_incomplete["received_chunks"], 2)
        self.assertEqual(self.parser.last_incomplete["reason"], "conflicting_duplicate")

    def test_first_fragment_required(self):
        self.assertIsNone(self.feed(fragment(1, 2, b"b")))
        self.assertFalse(self.parser.parts)

    def test_expiry_without_more_datagrams(self):
        self.feed(fragment(0, 2, b"a" * 512))
        self.now = FRAME_EXPIRY_SECONDS
        self.parser.expire()
        self.assertEqual(self.parser.dropped_frames, 1)
        self.assertFalse(self.parser.parts)
        self.assertEqual(self.parser.last_incomplete["expected_chunks"], 2)
        self.assertEqual(self.parser.last_incomplete["received_chunks"], 1)
        self.assertEqual(self.parser.last_incomplete["reason"], "expired")

    def test_new_frame_drops_incomplete(self):
        self.feed(fragment(0, 2, b"a" * 512))
        self.feed(fragment(0, 2, b"b" * 512))
        self.assertEqual(self.parser.dropped_frames, 1)

    def test_source_and_port_exact_match(self):
        packet = fragment(0, 1, b"data")
        self.assertIsNone(self.feed(packet, (PEER[0], PEER[1] + 1)))
        self.assertIsNone(self.feed(packet, ("192.168.1.101", PEER[1])))
        self.assertEqual(self.parser.protocol_errors, 2)

    def test_header_bounds_lengths_and_canonical_offsets(self):
        packets = (b"", b"x" * 15, fragment(0, 0, b"a"), fragment(1, 1, b"a"),
                   fragment(0, 1025, b"a" * 512), fragment(0, 2, b"a"),
                   fragment(0, 1, b"a", offset=1), fragment(0, 1, b"a", size=2),
                   fragment(0, 1, b"a" * 513), fragment(0, 1, b""))
        for packet in packets:
            with self.subTest(packet=packet[:16]):
                self.assertIsNone(self.feed(packet))
                self.assertFalse(self.parser.parts)
        self.assertEqual(self.parser.protocol_errors, len(packets))

    def test_only_defined_echoes_accepted(self):
        self.feed(b"\x01")
        self.feed(b"\x02")
        self.assertEqual(self.parser.protocol_errors, 0)
        self.feed(b"\x03")
        self.assertEqual(self.parser.protocol_errors, 1)

    def test_maximum_frame_bounded(self):
        for seq in range(1024):
            result = self.feed(fragment(seq, 1024, b"x" * 512))
        self.assertEqual(len(result[1]), WIRE.MAX_FRAME_BYTES)
        self.assertFalse(self.parser.parts)


if __name__ == "__main__":
    unittest.main()
