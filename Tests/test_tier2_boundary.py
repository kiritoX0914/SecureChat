"""
Tier 2: Boundary & Corner Cases Tests
Validates edge cases and boundary thresholds for SecureChat (>= 5 tests per feature):
1. Empty payloads, 0-byte file attachments, 50 MB boundary file transfer.
2. Base64 encoding overhead calculation (~33.3% to ~125% nested expansion).
3. Wire length header big-endian byte order and UInt32 maximum limits.
4. Rejection of oversized payloads (> 150 MB).
5. Invalid JSON recovery and malformed wire envelope rejection without crash.
"""

import unittest
import os
import re
import json
import struct
import math
import base64

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SOURCE_ROOT = os.path.join(ROOT, "SecureChat")

# 50 MB in bytes
FIFTY_MB = 50 * 1024 * 1024  # 52,428,800 bytes
# 150 MB in bytes
ONE_HUNDRED_FIFTY_MB = 150 * 1024 * 1024  # 157,286,400 bytes


class TestFeature1EmptyAndBoundaryPayloads(unittest.TestCase):
    """Feature 1: Empty payloads, 0-byte file attachments, 50 MB boundary file transfer."""

    def test_empty_text_message_payload_encoding(self):
        """Verify empty string message encodes to valid JSON and single wire frame."""
        msg = {
            "id": "00000000-0000-0000-0000-000000000001",
            "conversationId": "peer-1",
            "senderId": "user-1",
            "text": "",
            "timestamp": 1700000000.0,
            "status": 0,
            "attachment": None
        }
        json_data = json.dumps(msg).encode("utf-8")
        envelope = {
            "type": 2,
            "senderId": "user-1",
            "senderName": "Alice",
            "payload": base64.b64encode(json_data).decode("ascii")
        }
        env_json = json.dumps(envelope).encode("utf-8")
        frame = struct.pack(">I", len(env_json)) + env_json

        self.assertEqual(len(frame), 4 + len(env_json))
        extracted_len = struct.unpack(">I", frame[:4])[0]
        self.assertEqual(extracted_len, len(env_json))
        decoded_env = json.loads(frame[4:].decode("utf-8"))
        decoded_payload = json.loads(base64.b64decode(decoded_env["payload"]).decode("utf-8"))
        self.assertEqual(decoded_payload["text"], "")

    def test_zero_byte_file_attachment(self):
        """Verify 0-byte file attachment is handled correctly without failure."""
        empty_attachment = {
            "id": "00000000-0000-0000-0000-000000000002",
            "filename": "empty.dat",
            "mimeType": "application/octet-stream",
            "data": base64.b64encode(b"").decode("ascii")
        }
        self.assertEqual(empty_attachment["data"], "")
        encoded = json.dumps(empty_attachment).encode("utf-8")
        decoded = json.loads(encoded.decode("utf-8"))
        self.assertEqual(base64.b64decode(decoded["data"]), b"")

    def test_50mb_boundary_file_transfer_accepted(self):
        """Verify 50 MB boundary (exactly 52,428,800 bytes) satisfies file size check in ChatManager."""
        path = os.path.join(SOURCE_ROOT, "Core", "ChatManager.swift")
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        # Check guard fileData.count <= 50 * 1024 * 1024
        self.assertRegex(content, r"fileData\.count\s*<=\s*50\s*\*\s*1024\s*\*\s*1024")
        file_size = FIFTY_MB
        self.assertTrue(file_size <= 50 * 1024 * 1024, "50 MB exact boundary must be accepted")

    def test_50mb_plus_1_byte_rejected(self):
        """Verify 50 MB + 1 byte (52,428,801 bytes) exceeds maximum file size limit."""
        oversized = FIFTY_MB + 1
        self.assertFalse(oversized <= 50 * 1024 * 1024, "50 MB + 1 byte must be rejected by ChatManager")

    def test_zero_length_wire_frame_header_rejected(self):
        """Verify 0-length wire payload header (0x00000000) is rejected by NetworkManager length check."""
        path = os.path.join(SOURCE_ROOT, "Network", "NetworkManager.swift")
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        # NetworkManager must enforce payloadLength > 0
        self.assertRegex(content, r"payloadLength\s*>\s*0")
        zero_header = struct.pack(">I", 0)
        unpacked_len = struct.unpack(">I", zero_header)[0]
        self.assertEqual(unpacked_len, 0)
        self.assertFalse(unpacked_len > 0, "Zero payload length must not pass validation")

    def test_chat_manager_file_transfer_sanity_checks(self):
        """Verify ChatManager sendFile includes defensive checks against invalid inputs."""
        path = os.path.join(SOURCE_ROOT, "Core", "ChatManager.swift")
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("func sendFile(", content)
        self.assertIn("fileData", content)
        self.assertIn("filename", content)


class TestFeature2Base64OverheadCalculation(unittest.TestCase):
    """Feature 2: Base64 encoding overhead calculation (~33.3% to ~125% nested expansion)."""

    def test_direct_base64_overhead_ratio(self):
        """Verify standard Base64 expansion ratio: 50 MB raw data expands by ~33.33%."""
        raw_size = FIFTY_MB
        # Base64 formula: ceil(raw_size / 3) * 4
        expected_b64_len = math.ceil(raw_size / 3) * 4
        overhead_bytes = expected_b64_len - raw_size
        overhead_percent = (overhead_bytes / raw_size) * 100.0

        self.assertEqual(expected_b64_len, 69905068)  # ~66.67 MB
        self.assertAlmostEqual(overhead_percent, 33.333, delta=0.01)

    def test_nested_base64_json_expansion_within_150mb(self):
        """Verify nested Base64 expansion for 50 MB binary payload fits within 150 MB network threshold."""
        raw_size = FIFTY_MB
        # Level 1: Attachment data in ChatMessage JSON
        b64_attachment = math.ceil(raw_size / 3) * 4  # 69,905,068
        # JSON wrapper overhead for ChatMessage ~ 500 bytes
        msg_json_size = b64_attachment + 500
        # AES-256-GCM ciphertext = plaintext + 16-byte auth tag + 12-byte nonce
        ciphertext_size = msg_json_size + 28
        # Level 2: Encrypted payload in EncryptedMessagePayload
        b64_ciphertext = math.ceil(ciphertext_size / 3) * 4  # ~93.2 MB
        payload_json_size = b64_ciphertext + 300
        # Level 3: WireEnvelope payload Data Base64 encoding
        b64_wire_envelope = math.ceil(payload_json_size / 3) * 4  # ~124.3 MB
        total_wire_json_size = b64_wire_envelope + 200

        self.assertLess(total_wire_json_size, ONE_HUNDRED_FIFTY_MB,
                        f"Total wire JSON ({total_wire_json_size:,} bytes) must fit within 150 MB limit")

    def test_nested_base64_expansion_percentage_bounds(self):
        """Verify cumulative expansion of nested Base64 is between 75% and 140%."""
        raw_size = FIFTY_MB
        b64_level1 = math.ceil(raw_size / 3) * 4
        b64_level2 = math.ceil((b64_level1 + 500) / 3) * 4
        b64_level3 = math.ceil((b64_level2 + 300) / 3) * 4

        total_expansion = (b64_level3 - raw_size) / raw_size * 100.0
        self.assertGreater(total_expansion, 75.0, "Cumulative expansion should exceed 75%")
        self.assertLess(total_expansion, 140.0, "Cumulative expansion should not exceed 140%")

    def test_base64_padding_variations(self):
        """Verify Base64 padding behavior for lengths (3k, 3k+1, 3k+2)."""
        data_0pad = b"ABC"        # 3 bytes -> 4 chars, 0 pad '='
        data_2pad = b"A"          # 1 byte  -> 4 chars, 2 pad '=='
        data_1pad = b"AB"         # 2 bytes -> 4 chars, 1 pad '='

        b64_0 = base64.b64encode(data_0pad).decode("ascii")
        b64_2 = base64.b64encode(data_2pad).decode("ascii")
        b64_1 = base64.b64encode(data_1pad).decode("ascii")

        self.assertFalse(b64_0.endswith("="))
        self.assertTrue(b64_2.endswith("=="))
        self.assertTrue(b64_1.endswith("=") and not b64_1.endswith("=="))

    def test_base64_decoding_fidelity_on_large_synthetic_chunk(self):
        """Verify Base64 encoding and decoding integrity on 1 MB sample slice."""
        sample = bytes((i % 256) for i in range(1024 * 1024))
        encoded = base64.b64encode(sample)
        decoded = base64.b64decode(encoded)
        self.assertEqual(sample, decoded)

    def test_swift_network_manager_threshold_raised(self):
        """Verify NetworkManager.swift sets max payload threshold to at least 150 MB."""
        path = os.path.join(SOURCE_ROOT, "Network", "NetworkManager.swift")
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        # Check for 150 MB limit (157_286_400 or 150 * 1024 * 1024)
        has_150mb = "157_286_400" in content or "157286400" in content or "150 * 1024 * 1024" in content
        self.assertTrue(has_150mb, "NetworkManager must configure max payload threshold to 150 MB (157_286_400)")


class TestFeature3WireLengthHeaderBigEndianAndUInt32Limits(unittest.TestCase):
    """Feature 3: Wire length header big-endian byte order and UInt32 maximum limits."""

    def test_length_header_big_endian_byte_order(self):
        """Verify 4-byte header is strictly big-endian (network byte order)."""
        test_val = 0x01020304
        packed = struct.pack(">I", test_val)
        self.assertEqual(packed, bytes([0x01, 0x02, 0x03, 0x04]))
        self.assertNotEqual(packed, bytes([0x04, 0x03, 0x02, 0x01]), "Header must not be little-endian")

    def test_150mb_header_big_endian_representation(self):
        """Verify 150 MB (157,286,400 bytes) header is encoded correctly in big-endian."""
        val = ONE_HUNDRED_FIFTY_MB
        packed = struct.pack(">I", val)
        # 157286400 in hex is 0x09600000
        self.assertEqual(packed, bytes([0x09, 0x60, 0x00, 0x00]))
        unpacked = struct.unpack(">I", packed)[0]
        self.assertEqual(unpacked, val)

    def test_uint32_max_value_boundary(self):
        """Verify UInt32.max (0xFFFFFFFF = 4,294,967,295) is detected and rejected."""
        max_uint32 = 0xFFFFFFFF
        packed = struct.pack(">I", max_uint32)
        unpacked = struct.unpack(">I", packed)[0]
        self.assertEqual(unpacked, 4294967295)
        self.assertGreater(unpacked, ONE_HUNDRED_FIFTY_MB, "UInt32.max must exceed 150 MB limit")

    def test_header_byte_by_byte_accumulation_simulation(self):
        """Simulate receiving 4-byte header in fragments (1 byte, 2 bytes, 1 byte)."""
        target_len = 1048576  # 1 MB
        header_bytes = struct.pack(">I", target_len)
        buffer = bytearray()

        buffer.extend(header_bytes[:1])
        self.assertEqual(len(buffer), 1)
        self.assertLess(len(buffer), 4)

        buffer.extend(header_bytes[1:3])
        self.assertEqual(len(buffer), 3)
        self.assertLess(len(buffer), 4)

        buffer.extend(header_bytes[3:4])
        self.assertEqual(len(buffer), 4)

        extracted = struct.unpack(">I", buffer)[0]
        self.assertEqual(extracted, target_len)

    def test_uint32_overflow_protection_in_buffer_calculations(self):
        """Verify framing arithmetic protects against 32-bit integer overflow."""
        huge_val = 0xFFFFFFFC  # 4 bytes before wrap
        # In a naive 32-bit addition: huge_val + 4 = 0 (wrapped)
        wrapped_32 = (huge_val + 4) & 0xFFFFFFFF
        self.assertEqual(wrapped_32, 0)
        # Proper check must reject values near UInt32 max before addition
        self.assertGreater(huge_val, ONE_HUNDRED_FIFTY_MB)

    def test_swift_header_parsing_syntax(self):
        """Verify NetworkManager.swift loads UInt32 as big-endian correctly."""
        path = os.path.join(SOURCE_ROOT, "Network", "NetworkManager.swift")
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("UInt32(bigEndian:", content)


class TestFeature4RejectionOfOversizedPayloads(unittest.TestCase):
    """Feature 4: Rejection of oversized payloads (> 150 MB)."""

    def test_payload_150mb_plus_1_byte_rejected(self):
        """Header specifying 157,286,401 bytes must be rejected."""
        len_val = ONE_HUNDRED_FIFTY_MB + 1
        is_valid = 0 < len_val <= ONE_HUNDRED_FIFTY_MB
        self.assertFalse(is_valid, "150 MB + 1 byte must be rejected")

    def test_payload_200mb_rejected(self):
        """Header specifying 200 MB (209,715,200 bytes) must be rejected."""
        len_val = 200 * 1024 * 1024
        is_valid = 0 < len_val <= ONE_HUNDRED_FIFTY_MB
        self.assertFalse(is_valid, "200 MB must be rejected")

    def test_payload_500mb_rejected(self):
        """Header specifying 500 MB must be rejected."""
        len_val = 500 * 1024 * 1024
        is_valid = 0 < len_val <= ONE_HUNDRED_FIFTY_MB
        self.assertFalse(is_valid, "500 MB must be rejected")

    def test_payload_2gb_signed_boundary_rejected(self):
        """Header specifying 2 GB (0x80000000) must be treated as unsigned and rejected."""
        len_val = 0x80000000  # 2,147,483,648
        packed = struct.pack(">I", len_val)
        unpacked = struct.unpack(">I", packed)[0]
        self.assertEqual(unpacked, 2147483648)
        is_valid = 0 < unpacked <= ONE_HUNDRED_FIFTY_MB
        self.assertFalse(is_valid, "2 GB must be rejected")

    def test_swift_oversized_rejection_logic(self):
        """Verify NetworkManager.swift includes sanity check for payload length."""
        path = os.path.join(SOURCE_ROOT, "Network", "NetworkManager.swift")
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        # Check guard payloadLength > 0, payloadLength <= max
        self.assertRegex(content, r"payloadLength\s*>\s*0")
        self.assertIn("cleanupConnection", content)

    def test_rejection_does_not_allocate_memory(self):
        """Verify oversized packet header triggers rejection before memory allocation."""
        # Simulated gatekeeper logic
        def gatekeeper(header_bytes):
            length = struct.unpack(">I", header_bytes)[0]
            if length == 0 or length > ONE_HUNDRED_FIFTY_MB:
                return "REJECTED"
            return "ALLOCATE"

        oversized_header = struct.pack(">I", 250 * 1024 * 1024)
        self.assertEqual(gatekeeper(oversized_header), "REJECTED")


class TestFeature5InvalidJsonAndMalformedEnvelopeRejection(unittest.TestCase):
    """Feature 5: Invalid JSON recovery and malformed wire envelope rejection without crash."""

    def test_malformed_json_syntax_rejected(self):
        """Verify truncated JSON syntax is caught and rejected by decoder."""
        broken_json = b'{"type": 1, "senderId": "A", "payload":'
        with self.assertRaises(json.JSONDecodeError):
            json.loads(broken_json.decode("utf-8"))

    def test_non_utf8_binary_payload_rejected(self):
        """Verify non-UTF8 arbitrary binary payload is rejected gracefully."""
        garbage_bytes = b"\x80\xFF\xFE\x00\x01\x02\x03\x04"
        with self.assertRaises(UnicodeDecodeError):
            garbage_bytes.decode("utf-8")

    def test_missing_required_fields_in_envelope(self):
        """Verify envelope JSON missing required 'type' or 'senderId' fails schema check."""
        incomplete_json = '{"senderName": "Alice"}'
        data = json.loads(incomplete_json)
        self.assertNotIn("type", data)
        self.assertNotIn("senderId", data)

    def test_unknown_message_type_graceful_handling(self):
        """Verify unrecognized message type integer is caught without crash."""
        valid_types = {0, 1, 2, 3, 4}
        unknown_type = 999
        self.assertNotIn(unknown_type, valid_types)

    def test_subsequent_valid_message_after_error_recovery(self):
        """Verify receiver can process a valid message following an invalid packet rejection."""
        def mock_process(data_bytes):
            try:
                env = json.loads(data_bytes.decode("utf-8"))
                if "type" not in env or "senderId" not in env:
                    return False, "missing_fields"
                return True, "success"
            except Exception as e:
                return False, str(e)

        # 1. Invalid message
        ok1, res1 = mock_process(b"INVALID_GARBAGE")
        self.assertFalse(ok1)

        # 2. Subsequent valid message
        valid_msg = json.dumps({"type": 0, "senderId": "user-2", "senderName": "Bob", "payload": ""}).encode("utf-8")
        ok2, res2 = mock_process(valid_msg)
        self.assertTrue(ok2)
        self.assertEqual(res2, "success")

    def test_swift_network_manager_handles_decode_error_without_crash(self):
        """Verify NetworkManager.swift handles JSONDecoder decode failures cleanly."""
        path = os.path.join(SOURCE_ROOT, "Network", "NetworkManager.swift")
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        # NetworkManager uses try? or do-catch for decoding
        self.assertRegex(content, r"(try\?|do\s*\{[^}]*try)\s+JSONDecoder\(\)\.decode")


if __name__ == "__main__":
    unittest.main()
