"""
test_challenger_adversarial.py
Adversarial Stress Testing Harness for SecureChat Networking & Framing Protocol

Written and executed by Challenger subagent (challenger_1).
Tests packet framing, fragmentation, boundary limits, 50MB file transfer overhead,
chunked streaming under various TCP segment sizes, and live TCP loopback framing.
"""

import unittest
import os
import sys
import json
import struct
import base64
import hashlib
import socket
import threading
import time
import random
import math

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SOURCE_ROOT = os.path.join(ROOT, "SecureChat")

FIFTY_MB = 50 * 1024 * 1024         # 52,428,800 bytes
ONE_HUNDRED_FIFTY_MB = 150 * 1024 * 1024  # 157,286,400 bytes


class FramingDecoderOracle:
    """Simulates NetworkManager.receiveLoop and receivePayload framing state machine."""

    def __init__(self, max_payload_length=ONE_HUNDRED_FIFTY_MB):
        self.max_payload_length = max_payload_length
        self.buffer = bytearray()
        self.delivered_payloads = []
        self.connection_dropped = False
        self.drop_reason = None

    def feed(self, chunk: bytes):
        if self.connection_dropped:
            return
        self.buffer.extend(chunk)
        self._process()

    def _process(self):
        while not self.connection_dropped:
            # Need at least 4 bytes for header
            if len(self.buffer) < 4:
                break
            payload_len = struct.unpack(">I", self.buffer[:4])[0]
            if payload_len == 0:
                self.connection_dropped = True
                self.drop_reason = "Zero-length payload header"
                return
            if payload_len > self.max_payload_length:
                self.connection_dropped = True
                self.drop_reason = f"Oversized payload header: {payload_len} > {self.max_payload_length}"
                return

            total_needed = 4 + payload_len
            if len(self.buffer) < total_needed:
                # Still waiting for rest of payload
                break

            # Full frame available
            payload = bytes(self.buffer[4:total_needed])
            self.buffer = self.buffer[total_needed:]
            self.delivered_payloads.append(payload)


class TestAdversarialPacketFraming(unittest.TestCase):
    """Stress testing framing edge cases: back-to-back, fragmentation, zero-length, UInt32 max, malformed."""

    def test_back_to_back_pipelined_packets(self):
        """Feed 100 back-to-back packets of random sizes into a single buffer feed."""
        oracle = FramingDecoderOracle()
        expected_payloads = []
        combined_stream = bytearray()

        for i in range(100):
            payload = f'{{"id": {i}, "data": "{"X" * (i * 50)}}}'.encode("utf-8")
            expected_payloads.append(payload)
            frame = struct.pack(">I", len(payload)) + payload
            combined_stream.extend(frame)

        # Feed entire multi-packet stream in a single feed call
        oracle.feed(bytes(combined_stream))

        self.assertFalse(oracle.connection_dropped, f"Connection was dropped: {oracle.drop_reason}")
        self.assertEqual(len(oracle.delivered_payloads), 100)
        self.assertEqual(oracle.delivered_payloads, expected_payloads)
        self.assertEqual(len(oracle.buffer), 0)

    def test_fragmented_header_arrivals(self):
        """Header split across arrivals: 1+3 bytes, 2+2 bytes, 1+1+1+1 bytes."""
        splits = [
            [1, 3],
            [2, 2],
            [1, 1, 2],
            [1, 1, 1, 1],
            [3, 1],
        ]
        for split in splits:
            with self.subTest(split=split):
                oracle = FramingDecoderOracle()
                payload = b'{"status": "fragmented_test"}'
                header = struct.pack(">I", len(payload))

                # Send header fragments
                idx = 0
                for count in split:
                    chunk = header[idx : idx + count]
                    idx += count
                    oracle.feed(chunk)
                    if idx < 4:
                        self.assertEqual(len(oracle.delivered_payloads), 0)

                # Now send payload
                oracle.feed(payload)

                self.assertFalse(oracle.connection_dropped)
                self.assertEqual(len(oracle.delivered_payloads), 1)
                self.assertEqual(oracle.delivered_payloads[0], payload)
                self.assertEqual(len(oracle.buffer), 0)

    def test_byte_by_byte_payload_delivery(self):
        """Deliver a full packet (header + payload) exactly 1 byte at a time."""
        oracle = FramingDecoderOracle()
        payload = b'{"type": 2, "message": "one byte at a time stress test"}'
        packet = struct.pack(">I", len(payload)) + payload

        for b in packet:
            oracle.feed(bytes([b]))

        self.assertFalse(oracle.connection_dropped)
        self.assertEqual(len(oracle.delivered_payloads), 1)
        self.assertEqual(oracle.delivered_payloads[0], payload)
        self.assertEqual(len(oracle.buffer), 0)

    def test_zero_length_packet_rejection(self):
        """Zero-length payload header (0x00000000) must trigger connection teardown."""
        oracle = FramingDecoderOracle()
        zero_header = struct.pack(">I", 0)
        oracle.feed(zero_header)

        self.assertTrue(oracle.connection_dropped)
        self.assertIn("Zero-length", oracle.drop_reason)
        self.assertEqual(len(oracle.delivered_payloads), 0)

    def test_maximum_uint32_header_rejection(self):
        """Maximum UInt32 (0xFFFFFFFF = ~4.29 GB) and large values must reject before buffer allocation."""
        test_values = [
            0xFFFFFFFF,           # 4,294,967,295 (max UInt32)
            0x80000000,           # 2,147,483,648 (signed 32-bit boundary)
            ONE_HUNDRED_FIFTY_MB + 1,  # 157,286,401 (150 MB + 1 byte)
            200 * 1024 * 1024,    # 200 MB
            500 * 1024 * 1024,    # 500 MB
        ]
        for val in test_values:
            with self.subTest(val=val):
                oracle = FramingDecoderOracle()
                header = struct.pack(">I", val)
                oracle.feed(header)

                self.assertTrue(oracle.connection_dropped)
                self.assertIn("Oversized", oracle.drop_reason)
                self.assertEqual(len(oracle.delivered_payloads), 0)

    def test_malformed_non_json_payload_resilience(self):
        """Verify that malformed payloads do not crash framing or drop connection on identified peers."""
        # Malformed payloads
        bad_payloads = [
            b"\x80\xFF\xFE\x00\x01\x02",       # Non-UTF-8 arbitrary binary
            b'{"type": 2, "senderId": "alice',   # Truncated JSON
            b"not a json document at all",       # Plain string
            b"{}",                              # Missing required fields
            json.dumps({"type": 999}).encode(), # Unknown message type
        ]

        # Valid payload following the bad ones
        good_payload = json.dumps({
            "type": 2,
            "senderId": "alice-id",
            "senderName": "Alice",
            "payload": base64.b64encode(b"valid").decode("ascii")
        }).encode("utf-8")

        # The FramingDecoder accumulates all properly framed frames
        oracle = FramingDecoderOracle()
        all_frames = bytearray()
        for bad in bad_payloads:
            all_frames.extend(struct.pack(">I", len(bad)) + bad)
        all_frames.extend(struct.pack(">I", len(good_payload)) + good_payload)

        oracle.feed(bytes(all_frames))
        self.assertFalse(oracle.connection_dropped)
        self.assertEqual(len(oracle.delivered_payloads), len(bad_payloads) + 1)

        # In ChatManager, each payload is passed to handleReceivedData:
        # verify ChatManager error-handling pattern (try JSONDecoder -> catch -> log error, don't crash)
        decoded_envelopes = []
        errors_caught = 0
        for payload in oracle.delivered_payloads:
            try:
                env = json.loads(payload.decode("utf-8"))
                if "type" in env and "senderId" in env and "payload" in env:
                    decoded_envelopes.append(env)
                else:
                    errors_caught += 1
            except Exception:
                errors_caught += 1

        self.assertEqual(errors_caught, len(bad_payloads))
        self.assertEqual(len(decoded_envelopes), 1)
        self.assertEqual(decoded_envelopes[0]["senderId"], "alice-id")

    def test_wire_protocol_single_4byte_prefix_audit(self):
        """Mathematical and AST/regex audit: exactly ONE 4-byte length prefix on wire."""
        # 1. WireEnvelope.wireData() must return raw JSON, NO prefix
        models_path = os.path.join(SOURCE_ROOT, "Models", "Models.swift")
        with open(models_path, "r", encoding="utf-8") as f:
            models_code = f.read()

        self.assertRegex(models_code, r"func\s+wireData\(\)\s*throws\s*->\s*Data\s*\{\s*try\s*JSONEncoder\(\)\.encode\(self\)\s*\}")

        # 2. NetworkManager.sendFramed adds EXACTLY 4 bytes
        nm_path = os.path.join(SOURCE_ROOT, "Network", "NetworkManager.swift")
        with open(nm_path, "r", encoding="utf-8") as f:
            nm_code = f.read()

        self.assertIn("var length = UInt32(data.count).bigEndian", nm_code)
        self.assertIn("var frame = Data(bytes: &length, count: 4)", nm_code)
        self.assertIn("frame.append(data)", nm_code)

        # 3. ChatManager.handleReceivedData does NOT strip 4 bytes
        cm_path = os.path.join(SOURCE_ROOT, "Core", "ChatManager.swift")
        with open(cm_path, "r", encoding="utf-8") as f:
            cm_code = f.read()

        # Should NOT contain data.dropFirst(4) or data.subdata(in: 4...)
        self.assertNotIn("dropFirst(4)", cm_code)
        self.assertNotIn("subdata(in: 4", cm_code)
        self.assertRegex(cm_code, r"JSONDecoder\(\)\.decode\(WireEnvelope\.self,\s*from:\s*data\)")


class TestAdversarialPayloadSizeBoundaries(unittest.TestCase):
    """Stress testing 50 MB payload math, nested Base64 expansion, and TCP streaming accumulation."""

    def test_50mb_binary_file_expansion_exact_math(self):
        """Calculate and verify exact mathematical sizes for 50 MB binary file transfer."""
        raw_size = FIFTY_MB  # 52,428,800 bytes

        # 1. First Base64 expansion: Attachment.data in ChatMessage
        # Base64 formula: ceil(n / 3) * 4
        # 52,428,800 = 17,476,266 * 3 + 2 -> ceil(52428800 / 3) = 17,476,267 -> * 4 = 69,905,068 bytes
        expected_b64_1 = math.ceil(raw_size / 3.0) * 4
        self.assertEqual(expected_b64_1, 69_905_068)
        single_b64_mb = expected_b64_1 / (1024 * 1024)
        self.assertAlmostEqual(single_b64_mb, 66.66667, delta=0.01)

        # 2. ChatMessage JSON serialization overhead:
        # Fields: id (36), senderId (~36), recipientId (~36), text (~20), timestamp (~20), status (1), contentType (1), attachment metadata (~150)
        # Total ChatMessage JSON plaintext: ~69,905,068 + ~300 = ~69,905,368 bytes
        cm_json_len = expected_b64_1 + 300

        # 3. AES-256-GCM encryption:
        # Ciphertext length = plaintext length + 16-byte auth tag
        ciphertext_len = cm_json_len + 16

        # 4. Second Base64 expansion: EncryptedMessagePayload.ciphertext in EncryptedMessagePayload JSON
        expected_b64_2 = math.ceil(ciphertext_len / 3.0) * 4
        # ~93,207,180 bytes
        emp_json_len = expected_b64_2 + 200

        # 5. Third Base64 expansion: WireEnvelope.payload (Data) in WireEnvelope JSON
        expected_b64_3 = math.ceil(emp_json_len / 3.0) * 4
        # ~124,276,508 bytes
        wire_envelope_json_len = expected_b64_3 + 120

        # Total wire packet with 4-byte header
        total_wire_packet = 4 + wire_envelope_json_len

        # Verify envelope fits under 150 MB (157,286,400 bytes)
        self.assertLess(total_wire_packet, ONE_HUNDRED_FIFTY_MB)
        margin = ONE_HUNDRED_FIFTY_MB - total_wire_packet
        self.assertGreater(margin, 30 * 1024 * 1024, "At least 30 MB safety margin within 150 MB limit")

    def test_50mb_full_simulation_roundtrip_and_chunked_reconstruction(self):
        """End-to-end empirical simulation: 50 MB binary file -> triple Base64 -> frame -> 64KB chunked receive -> unframe -> triple Base64 decode -> SHA256 match."""
        # 1. 50 MB deterministic binary file
        raw_50mb = b"SECURE_CHAT_50MB_PAYLOAD_TEST_" * (FIFTY_MB // 30) + b"EXTRA" * ((FIFTY_MB % 30) // 5)
        raw_50mb = raw_50mb[:FIFTY_MB]
        self.assertEqual(len(raw_50mb), FIFTY_MB)
        original_sha = hashlib.sha256(raw_50mb).hexdigest()

        # 2. ChatMessage serialization with Base64 attachment
        attachment_b64 = base64.b64encode(raw_50mb).decode("ascii")
        self.assertEqual(len(attachment_b64), 69_905_068)  # Exactly ceil(52428800/3)*4
        chat_msg = {
            "id": "11111111-2222-3333-4444-555555555555",
            "senderId": "peer-alice",
            "recipientId": "peer-bob",
            "text": "📎 presentation.mp4",
            "timestamp": 1700000000.0,
            "status": 0,
            "contentType": 2,
            "attachment": {
                "filename": "presentation.mp4",
                "mimeType": "video/mp4",
                "data": attachment_b64,
                "fileSize": FIFTY_MB
            }
        }
        chat_msg_json = json.dumps(chat_msg).encode("utf-8")
        self.assertGreater(len(chat_msg_json), 69_905_068)

        # 3. Simulate AEAD encryption (AES-256-GCM adds 16-byte tag)
        ciphertext = chat_msg_json + b"16_BYTE_AUTH_TAG"
        ciphertext_b64 = base64.b64encode(ciphertext).decode("ascii")

        # 4. EncryptedMessagePayload JSON serialization
        emp = {
            "messageId": "11111111-2222-3333-4444-555555555555",
            "ciphertext": ciphertext_b64,
            "nonce": base64.b64encode(b"012345678901").decode("ascii"),
            "ratchetPublicKey": base64.b64encode(b"R" * 32).decode("ascii"),
            "previousChainLength": 0,
            "messageNumber": 1
        }
        emp_json = json.dumps(emp).encode("utf-8")

        # 5. WireEnvelope JSON serialization (WireEnvelope.payload is Data, so JSONEncoder encodes to Base64)
        env_payload_b64 = base64.b64encode(emp_json).decode("ascii")
        envelope = {
            "type": 2,
            "senderId": "peer-alice",
            "senderName": "Alice",
            "payload": env_payload_b64
        }
        wire_envelope_json = json.dumps(envelope).encode("utf-8")
        wire_envelope_len = len(wire_envelope_json)

        # Confirm total envelope length is within 150 MB (157,286,400 bytes)
        self.assertLess(wire_envelope_len, ONE_HUNDRED_FIFTY_MB)
        # Expected around 124.28 MB decimal / 118.52 MiB (~124,276,611 bytes)
        self.assertTrue(115 * 1024 * 1024 < wire_envelope_len < 130 * 1024 * 1024 or
                        115_000_000 < wire_envelope_len < 130_000_000,
                        f"Envelope length {wire_envelope_len} not within expected window")

        # 6. Prepend single 4-byte big-endian framing header
        wire_frame = struct.pack(">I", wire_envelope_len) + wire_envelope_json

        # 7. Feed into FramingDecoderOracle in 64 KB chunks
        oracle = FramingDecoderOracle(max_payload_length=ONE_HUNDRED_FIFTY_MB)
        chunk_size = 65536
        offset = 0
        while offset < len(wire_frame):
            chunk = wire_frame[offset : offset + chunk_size]
            oracle.feed(chunk)
            offset += chunk_size

        self.assertFalse(oracle.connection_dropped, f"Decoder dropped connection: {oracle.drop_reason}")
        self.assertEqual(len(oracle.delivered_payloads), 1)

        # 8. Unframe, unpack, and verify SHA256 integrity
        delivered_bytes = oracle.delivered_payloads[0]
        self.assertEqual(len(delivered_bytes), wire_envelope_len)
        decoded_envelope = json.loads(delivered_bytes.decode("utf-8"))
        decoded_emp_json = base64.b64decode(decoded_envelope["payload"])
        decoded_emp = json.loads(decoded_emp_json.decode("utf-8"))
        decoded_ciphertext = base64.b64decode(decoded_emp["ciphertext"])
        decoded_chat_msg_json = decoded_ciphertext[:-16]  # strip 16-byte auth tag
        decoded_chat_msg = json.loads(decoded_chat_msg_json.decode("utf-8"))
        recovered_50mb = base64.b64decode(decoded_chat_msg["attachment"]["data"])

        self.assertEqual(len(recovered_50mb), FIFTY_MB)
        self.assertEqual(hashlib.sha256(recovered_50mb).hexdigest(), original_sha)

    def test_exact_150mb_boundary_acceptance_and_rejection(self):
        """Test exact 150 MB boundary: 157,286,400 accepted, 157,286,401 rejected."""
        oracle_accept = FramingDecoderOracle(max_payload_length=ONE_HUNDRED_FIFTY_MB)
        # Header with exactly 150 MB (157,286,400)
        oracle_accept.feed(struct.pack(">I", ONE_HUNDRED_FIFTY_MB))
        # Connection should NOT be dropped; it is waiting for payload data
        self.assertFalse(oracle_accept.connection_dropped)
        self.assertEqual(len(oracle_accept.buffer), 4)

        oracle_reject = FramingDecoderOracle(max_payload_length=ONE_HUNDRED_FIFTY_MB)
        # Header with 150 MB + 1 byte (157,286,401)
        oracle_reject.feed(struct.pack(">I", ONE_HUNDRED_FIFTY_MB + 1))
        # Connection MUST be dropped immediately
        self.assertTrue(oracle_reject.connection_dropped)
        self.assertIn("Oversized", oracle_reject.drop_reason)

    def test_chunked_streaming_accumulation_various_segment_sizes(self):
        """Simulate chunked streaming accumulation across various TCP MSS / segment sizes."""
        # Construct synthetic ~1 MB payload for detailed chunk testing
        payload_size = 1024 * 1024  # 1 MB
        synthetic_payload = os.urandom(payload_size)
        expected_sha = hashlib.sha256(synthetic_payload).hexdigest()

        packet = struct.pack(">I", payload_size) + synthetic_payload

        segment_sizes = [
            512,            # Small segment / low-MTU link
            1460,           # Standard Ethernet TCP MSS (1500 MTU - 40 TCP/IP)
            8192,           # 8 KB socket buffer
            65536,          # 64 KB max NetworkManager chunk size
        ]

        for seg_size in segment_sizes:
            with self.subTest(segment_size=seg_size):
                oracle = FramingDecoderOracle()
                offset = 0
                while offset < len(packet):
                    chunk = packet[offset : offset + seg_size]
                    oracle.feed(chunk)
                    offset += seg_size

                self.assertFalse(oracle.connection_dropped)
                self.assertEqual(len(oracle.delivered_payloads), 1)
                reconstructed = oracle.delivered_payloads[0]
                self.assertEqual(len(reconstructed), payload_size)
                self.assertEqual(hashlib.sha256(reconstructed).hexdigest(), expected_sha)

    def test_chunked_streaming_random_jitter_segments(self):
        """Simulate streaming accumulation with completely randomized chunk sizes (1 B to 8 KB)."""
        payload_size = 512 * 1024  # 512 KB
        synthetic_payload = os.urandom(payload_size)
        expected_sha = hashlib.sha256(synthetic_payload).hexdigest()
        packet = struct.pack(">I", payload_size) + synthetic_payload

        rng = random.Random(42)
        oracle = FramingDecoderOracle()
        offset = 0
        while offset < len(packet):
            chunk_size = rng.randint(1, 8192)
            chunk = packet[offset : offset + chunk_size]
            oracle.feed(chunk)
            offset += chunk_size

        self.assertFalse(oracle.connection_dropped)
        self.assertEqual(len(oracle.delivered_payloads), 1)
        self.assertEqual(hashlib.sha256(oracle.delivered_payloads[0]).hexdigest(), expected_sha)


class TestLiveTCPNetworkFramingHarness(unittest.TestCase):
    """Adversarial stress testing against a live TCP socket loopback server."""

    @classmethod
    def setUpClass(cls):
        # We start a dynamic loopback TCP server implementing the framing receiver
        pass

    def _run_server(self, server_sock, max_payload, out_results):
        try:
            conn, _ = server_sock.accept()
            oracle = FramingDecoderOracle(max_payload_length=max_payload)
            while not oracle.connection_dropped:
                data = conn.recv(65536)
                if not data:
                    break
                oracle.feed(data)
            out_results["oracle"] = oracle
            conn.close()
        except Exception as e:
            out_results["error"] = e
        finally:
            server_sock.close()

    def test_live_tcp_back_to_back_packets(self):
        """Send 50 back-to-back packets rapidly over live TCP loopback."""
        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(1)
        port = server_sock.getsockname()[1]

        results = {}
        t = threading.Thread(target=self._run_server, args=(server_sock, ONE_HUNDRED_FIFTY_MB, results))
        t.start()

        client_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        client_sock.connect(("127.0.0.1", port))

        expected = []
        stream = bytearray()
        for i in range(50):
            payload = f'{{"seq": {i}, "content": "msg_{i}"}}'.encode("utf-8")
            expected.append(payload)
            stream.extend(struct.pack(">I", len(payload)) + payload)

        client_sock.sendall(stream)
        client_sock.close()
        t.join(timeout=5)

        oracle = results.get("oracle")
        self.assertIsNotNone(oracle)
        self.assertFalse(oracle.connection_dropped)
        self.assertEqual(len(oracle.delivered_payloads), 50)
        self.assertEqual(oracle.delivered_payloads, expected)

    def test_live_tcp_fragmented_delivery(self):
        """Send packet in 1-byte TCP segments with sleep intervals."""
        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(1)
        port = server_sock.getsockname()[1]

        results = {}
        t = threading.Thread(target=self._run_server, args=(server_sock, ONE_HUNDRED_FIFTY_MB, results))
        t.start()

        client_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        client_sock.connect(("127.0.0.1", port))

        payload = b'{"live": "tcp_fragmented_test"}'
        frame = struct.pack(">I", len(payload)) + payload

        for b in frame:
            client_sock.sendall(bytes([b]))
            time.sleep(0.001)

        client_sock.close()
        t.join(timeout=5)

        oracle = results.get("oracle")
        self.assertIsNotNone(oracle)
        self.assertFalse(oracle.connection_dropped)
        self.assertEqual(len(oracle.delivered_payloads), 1)
        self.assertEqual(oracle.delivered_payloads[0], payload)

    def test_live_tcp_oversized_payload_rejection(self):
        """Client sends 200 MB header over live TCP socket; server terminates connection cleanly."""
        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(1)
        port = server_sock.getsockname()[1]

        results = {}
        t = threading.Thread(target=self._run_server, args=(server_sock, ONE_HUNDRED_FIFTY_MB, results))
        t.start()

        client_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        client_sock.connect(("127.0.0.1", port))

        # Send 200 MB length header (209,715,200 bytes)
        client_sock.sendall(struct.pack(">I", 200 * 1024 * 1024))
        # Send 1024 bytes of dummy payload
        try:
            client_sock.sendall(b"A" * 1024)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

        client_sock.close()
        t.join(timeout=5)

        oracle = results.get("oracle")
        self.assertIsNotNone(oracle)
        self.assertTrue(oracle.connection_dropped)
        self.assertIn("Oversized", oracle.drop_reason)

    def test_live_tcp_simulated_large_file_streaming(self):
        """Transfer 10 MB payload over live TCP loopback in 64 KB chunks, verifying SHA256 integrity."""
        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(1)
        port = server_sock.getsockname()[1]

        results = {}
        t = threading.Thread(target=self._run_server, args=(server_sock, ONE_HUNDRED_FIFTY_MB, results))
        t.start()

        client_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        client_sock.connect(("127.0.0.1", port))

        payload_size = 10 * 1024 * 1024  # 10 MB
        chunk_pattern = b"SECURECHAT_TEST_PATTERN_" * 256  # 6144 bytes
        repetitions = payload_size // len(chunk_pattern)
        remainder = payload_size % len(chunk_pattern)

        hasher = hashlib.sha256()
        client_sock.sendall(struct.pack(">I", payload_size))

        for _ in range(repetitions):
            client_sock.sendall(chunk_pattern)
            hasher.update(chunk_pattern)
        if remainder:
            client_sock.sendall(chunk_pattern[:remainder])
            hasher.update(chunk_pattern[:remainder])

        client_sock.close()
        t.join(timeout=10)

        oracle = results.get("oracle")
        self.assertIsNotNone(oracle)
        self.assertFalse(oracle.connection_dropped)
        self.assertEqual(len(oracle.delivered_payloads), 1)
        self.assertEqual(len(oracle.delivered_payloads[0]), payload_size)
        self.assertEqual(hashlib.sha256(oracle.delivered_payloads[0]).hexdigest(), hasher.hexdigest())


if __name__ == "__main__":
    unittest.main(verbosity=2)
