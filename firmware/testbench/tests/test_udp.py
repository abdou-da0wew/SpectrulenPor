import unittest

from testbench.settings import FRAME_EXPIRY_SECONDS
from testbench.transport import Reassembler, WIRE

PEER = ("192.168.1.100", WIRE.UDP_PORT)


def data_fragment(seq, total, frame_id, frame_size, data, offset=None):
    if offset is None:
        offset = seq * WIRE.UDP_PAYLOAD_BYTES
    return WIRE.UDP_HEADER.pack(
        seq, total, offset, len(data), frame_id, frame_size
    ) + data


def frame_packets(frame, frame_id=1):
    total = (len(frame) + WIRE.UDP_PAYLOAD_BYTES - 1) // WIRE.UDP_PAYLOAD_BYTES
    packets = [
        data_fragment(seq, total, frame_id, len(frame),
                      frame[seq * WIRE.UDP_PAYLOAD_BYTES:(seq + 1) * WIRE.UDP_PAYLOAD_BYTES])
        for seq in range(total)
    ]
    for group_index in range(min(total, WIRE.UDP_FEC_GROUP_SIZE)):
        parity = bytearray(WIRE.UDP_PAYLOAD_BYTES)
        for seq in range(group_index, total, WIRE.UDP_FEC_GROUP_SIZE):
            offset = seq * WIRE.UDP_PAYLOAD_BYTES
            chunk = frame[offset:offset + WIRE.UDP_PAYLOAD_BYTES]
            for index, value in enumerate(chunk):
                parity[index] ^= value
        packets.append(WIRE.UDP_HEADER.pack(
            WIRE.UDP_PARITY_SEQUENCE_FLAG | group_index,
            total,
            group_index * WIRE.UDP_PAYLOAD_BYTES,
            WIRE.UDP_PAYLOAD_BYTES,
            frame_id,
            len(frame),
        ) + bytes(parity))
    return packets



class ReassemblyTests(unittest.TestCase):
    def setUp(self):
        self.now = 0
        self.parser = Reassembler(PEER, clock=lambda: self.now)

    def feed(self, packet, peer=PEER):
        return self.parser.feed(packet, peer)

    def test_v2_wire_contract_uses_six_u32_fields_and_1200_byte_payloads(self):
        self.assertEqual(WIRE.UDP_HEADER.format, "<IIIIII")
        self.assertEqual(WIRE.UDP_HEADER.size, 24)
        self.assertEqual(WIRE.UDP_PAYLOAD_BYTES, 1200)
        self.assertEqual(WIRE.UDP_FEC_GROUP_SIZE, 4)

    def test_out_of_order_reassembly_with_frame_id(self):
        frame = b"F" * 2500
        packets = frame_packets(frame, frame_id=42)
        result = None
        for packet in reversed(packets):
            completed = self.feed(packet)
            if completed is not None:
                result = completed
        self.assertEqual(result, (0, frame))
        self.assertEqual(self.parser.packets, 0)
        self.assertEqual(self.parser.parity_packets, 3)
        self.assertFalse(self.parser.parts)

    def test_one_missing_datagram_is_recovered_by_xor_parity(self):
        frame = b"F" * 2500
        packets = frame_packets(frame, frame_id=5)
        # Drop data fragment zero; parity for group zero repairs it.
        packets = packets[1:]
        result = None
        for packet in packets:
            completed = self.feed(packet)
            if completed is not None:
                result = completed
        self.assertEqual(result, (0, frame))
        self.assertEqual(self.parser.packets, 2)
        self.assertEqual(self.parser.parity_packets, 1)

    def test_one_loss_per_fec_group_is_recovered_independently(self):
        frame = bytes((index * 17) & 0xFF for index in range(10 * WIRE.UDP_PAYLOAD_BYTES + 17))
        packets = frame_packets(frame, frame_id=9)
        dropped_sequences = {0, 1}
        result = None
        for packet in packets:
            raw_seq = WIRE.UDP_HEADER.unpack_from(packet)[0]
            if not raw_seq & WIRE.UDP_PARITY_SEQUENCE_FLAG and raw_seq in dropped_sequences:
                continue
            completed = self.feed(packet)
            if completed is not None:
                result = completed
        self.assertEqual(result, (0, frame))

    def test_adjacent_burst_losses_are_recovered_by_strided_fec(self):
        frame = bytes((index * 19) & 0xFF for index in range(10 * WIRE.UDP_PAYLOAD_BYTES + 17))
        packets = frame_packets(frame, frame_id=12)
        result = None
        for packet in packets:
            raw_seq = WIRE.UDP_HEADER.unpack_from(packet)[0]
            if not raw_seq & WIRE.UDP_PARITY_SEQUENCE_FLAG and raw_seq in {0, 1, 2}:
                continue
            completed = self.feed(packet)
            if completed is not None:
                result = completed
        self.assertEqual(result, (0, frame))

    def test_two_losses_in_same_group_skip_frame(self):
        frame = b"X" * (10 * WIRE.UDP_PAYLOAD_BYTES + 17)
        packets = frame_packets(frame, frame_id=10)
        dropped = {0, 4}
        for packet in packets:
            raw_seq = WIRE.UDP_HEADER.unpack_from(packet)[0]
            if not raw_seq & WIRE.UDP_PARITY_SEQUENCE_FLAG and raw_seq in dropped:
                continue
            self.assertIsNone(self.feed(packet))
        self.assertEqual(self.parser.parts.keys(), {1, 2, 3, 5, 6, 7, 8, 9, 10})
        self.assertFalse(self.parser.last_incomplete)

    def test_identical_duplicates_are_ignored(self):
        frame = b"F" * 2500
        packets = frame_packets(frame)
        self.feed(packets[0])
        self.feed(packets[0])
        result = None
        for packet in packets[1:]:
            completed = self.feed(packet)
            if completed is not None:
                result = completed
        self.assertEqual(result, (0, frame))

    def test_conflicting_duplicate_invalidates_frame(self):
        frame = b"F" * 2500
        packets = frame_packets(frame)
        self.feed(packets[0])
        conflicting = bytearray(packets[0])
        conflicting[WIRE.UDP_HEADER.size] ^= 1
        self.assertIsNone(self.feed(bytes(conflicting)))
        self.assertEqual(self.parser.protocol_errors, 1)
        self.assertEqual(self.parser.dropped_frames, 1)
        self.assertFalse(self.parser.parts)
        self.assertEqual(self.parser.last_incomplete["reason"], "conflicting_duplicate")

    def test_newer_frame_replaces_partial_and_old_packets_are_ignored(self):
        old_frame = b"A" * 2500
        new_frame = b"B" * 2500
        old_packets = frame_packets(old_frame, frame_id=100)
        new_packets = frame_packets(new_frame, frame_id=101)
        self.feed(old_packets[0])
        result = None
        for packet in new_packets:
            completed = self.feed(packet)
            if completed is not None:
                result = completed
        self.assertEqual(result, (0, new_frame))
        self.assertEqual(self.parser.dropped_frames, 1)
        for packet in old_packets[1:]:
            self.assertIsNone(self.feed(packet))

    def test_frame_id_wraparound_is_handled(self):
        old = frame_packets(b"A" * 5, frame_id=0xFFFFFFFE)
        new = frame_packets(b"B" * 5, frame_id=1)
        old_result = None
        for packet in old:
            completed = self.feed(packet)
            if completed is not None:
                old_result = completed
        new_result = None
        for packet in new:
            completed = self.feed(packet)
            if completed is not None:
                new_result = completed
        self.assertEqual(old_result, (0, b"A" * 5))
        self.assertEqual(new_result, (0, b"B" * 5))

    def test_expiry_without_more_datagrams(self):
        frame = b"F" * 2500
        self.feed(frame_packets(frame)[0])
        self.now = FRAME_EXPIRY_SECONDS
        self.parser.expire()
        self.assertEqual(self.parser.dropped_frames, 1)
        self.assertFalse(self.parser.parts)
        self.assertEqual(self.parser.last_incomplete["expected_chunks"], 3)
        self.assertEqual(self.parser.last_incomplete["received_chunks"], 1)
        self.assertEqual(self.parser.last_incomplete["reason"], "expired")

    def test_invalid_source_and_control_echoes(self):
        self.assertIsNone(self.feed(bytes([WIRE.CMD_STREAM_ON])))
        self.assertIsNone(self.feed(bytes([WIRE.CMD_SINGLE_FRAME])))
        self.assertIsNone(self.feed(bytes([WIRE.CMD_UDP_KEEPALIVE])))
        packet = frame_packets(b"F" * 5)[0]
        self.assertIsNone(self.feed(packet, (PEER[0], PEER[1] + 1)))
        self.assertEqual(self.parser.protocol_errors, 1)

    def test_header_bounds_sizes_offsets_and_fec_metadata(self):
        frame = b"F" * 2500
        malformed = (
            b"",
            b"x" * 23,
            WIRE.UDP_HEADER.pack(0, 0, 0, 1, 1, 4) + b"x",
            WIRE.UDP_HEADER.pack(2, 2, 2400, 100, 1, 2500) + b"x" * 100,
            WIRE.UDP_HEADER.pack(0, 3, 1, 1200, 1, 2500) + b"x" * 1200,
            WIRE.UDP_HEADER.pack(0, 3, 0, 1201, 1, 2500) + b"x" * 1201,
            WIRE.UDP_HEADER.pack(WIRE.UDP_PARITY_SEQUENCE_FLAG | 99, 3, 0, 1200, 1, 2500)
            + b"x" * 1200,
        )
        for packet in malformed:
            self.assertIsNone(self.feed(packet))
        self.assertEqual(self.parser.protocol_errors, len(malformed))
        self.assertFalse(self.parser.parts)

    def test_maximum_frame_is_bounded_and_reassembled(self):
        frame = bytes((index * 13) & 0xFF for index in range(WIRE.MAX_FRAME_BYTES))
        result = None
        for packet in frame_packets(frame, frame_id=123):
            completed = self.feed(packet)
            if completed is not None:
                result = completed
        self.assertEqual(result, (0, frame))
        self.assertFalse(self.parser.parts)


if __name__ == "__main__":
    unittest.main()
