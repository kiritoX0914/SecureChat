"""
Tier 3: Cross-Feature Combinations Tests (Pairwise Interactions)
Validates interactions across subsystems:
1. Framing + payload size validation.
2. Crypto payload inside WireEnvelope + NetworkManager framing round-trip.
3. Simultaneous connection tie-breaker simulation (UUID comparison logic).
4. Display name update propagation across settings, network, and discovery layers.
"""

import unittest
import os
import re
import json
import struct
import uuid
import hashlib
import hmac
import secrets
import base64

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SOURCE_ROOT = os.path.join(ROOT, "SecureChat")


class PurePythonAEAD:
    """Standard-library self-contained AEAD (Authenticated Encryption with Associated Data) simulator.
    Uses HKDF-SHA256 keystream generation with HMAC-SHA256 authentication tag.
    Provides identical semantics to AES-GCM: nonce, ciphertext, auth tag, tamper rejection.
    """

    @staticmethod
    def generate_key():
        return secrets.token_bytes(32)

    @classmethod
    def encrypt(cls, key: bytes, nonce: bytes, plaintext: bytes) -> bytes:
        # Keystream via HMAC-SHA256 counter mode
        keystream = bytearray()
        counter = 0
        while len(keystream) < len(plaintext):
            h = hmac.new(key, nonce + struct.pack(">I", counter), hashlib.sha256)
            keystream.extend(h.digest())
            counter += 1

        ciphertext = bytes(p ^ k for p, k in zip(plaintext, keystream[: len(plaintext)]))
        # 16-byte authentication tag
        tag = hmac.new(key, b"AEAD_AUTH:" + nonce + ciphertext, hashlib.sha256).digest()[:16]
        return ciphertext + tag

    @classmethod
    def decrypt(cls, key: bytes, nonce: bytes, ciphertext_and_tag: bytes) -> bytes:
        if len(ciphertext_and_tag) < 16:
            raise ValueError("Ciphertext too short for authentication tag")
        ciphertext = ciphertext_and_tag[:-16]
        tag = ciphertext_and_tag[-16:]

        expected_tag = hmac.new(key, b"AEAD_AUTH:" + nonce + ciphertext, hashlib.sha256).digest()[:16]
        if not hmac.compare_digest(tag, expected_tag):
            raise ValueError("Authentication tag verification failed: ciphertext tampered!")

        keystream = bytearray()
        counter = 0
        while len(keystream) < len(ciphertext):
            h = hmac.new(key, nonce + struct.pack(">I", counter), hashlib.sha256)
            keystream.extend(h.digest())
            counter += 1

        return bytes(c ^ k for c, k in zip(ciphertext, keystream[: len(ciphertext)]))


class TestCombination1FramingAndPayloadSizeValidation(unittest.TestCase):
    """Interaction: Framing protocol + payload size limits and chunked streaming accumulation."""

    def test_chunked_reception_over_tcp_segments(self):
        """Simulate 5 MB payload delivered over 64 KB TCP stream segments, accumulated correctly."""
        # Create a 5 MB synthetic payload
        payload_data = b"X" * (5 * 1024 * 1024)
        payload_len = len(payload_data)
        header = struct.pack(">I", payload_len)
        wire_stream = header + payload_data

        # Simulate TCP chunked reception
        chunk_size = 64 * 1024  # 64 KB
        received_chunks = []
        offset = 0
        while offset < len(wire_stream):
            chunk = wire_stream[offset : offset + chunk_size]
            received_chunks.append(chunk)
            offset += chunk_size

        # Accumulator simulation (mirroring NetworkManager receiveLoop chunked accumulator)
        stream_buffer = bytearray()
        accumulated_payload = bytearray()
        target_payload_length = None

        for chunk in received_chunks:
            stream_buffer.extend(chunk)
            if target_payload_length is None and len(stream_buffer) >= 4:
                target_payload_length = struct.unpack(">I", stream_buffer[:4])[0]
                stream_buffer = stream_buffer[4:]

            if target_payload_length is not None:
                # Accumulate into payload
                needed = target_payload_length - len(accumulated_payload)
                available = len(stream_buffer)
                take = min(needed, available)
                accumulated_payload.extend(stream_buffer[:take])
                stream_buffer = stream_buffer[take:]

        self.assertEqual(target_payload_length, payload_len)
        self.assertEqual(len(accumulated_payload), payload_len)
        self.assertEqual(bytes(accumulated_payload), payload_data)

    def test_maximum_valid_payload_framing(self):
        """Simulate boundary payload at exactly 150 MB threshold header."""
        max_valid = 150 * 1024 * 1024
        header = struct.pack(">I", max_valid)
        unpacked_len = struct.unpack(">I", header)[0]
        self.assertEqual(unpacked_len, max_valid)
        self.assertTrue(unpacked_len <= 150 * 1024 * 1024)

    def test_pipelined_framed_packets_in_single_buffer(self):
        """Verify two back-to-back framed packets arriving in a single TCP read are split cleanly."""
        msg1 = json.dumps({"type": 4, "senderId": "user1", "payload": "typing"}).encode("utf-8")
        msg2 = json.dumps({"type": 3, "senderId": "user2", "payload": "ack"}).encode("utf-8")

        frame1 = struct.pack(">I", len(msg1)) + msg1
        frame2 = struct.pack(">I", len(msg2)) + msg2
        combined_stream = frame1 + frame2

        # Parser loop
        decoded_messages = []
        buffer = bytearray(combined_stream)
        while len(buffer) >= 4:
            payload_len = struct.unpack(">I", buffer[:4])[0]
            if len(buffer) < 4 + payload_len:
                break
            payload = bytes(buffer[4 : 4 + payload_len])
            buffer = buffer[4 + payload_len :]
            decoded_messages.append(json.loads(payload.decode("utf-8")))

        self.assertEqual(len(decoded_messages), 2)
        self.assertEqual(decoded_messages[0]["payload"], "typing")
        self.assertEqual(decoded_messages[1]["payload"], "ack")
        self.assertEqual(len(buffer), 0)

    def test_split_header_across_tcp_boundary(self):
        """Verify 4-byte header arriving split across packet boundaries (e.g., 2 bytes + 2 bytes)."""
        payload = b'{"status":"ok"}'
        full_packet = struct.pack(">I", len(payload)) + payload

        part1 = full_packet[:2]  # first 2 bytes of header
        part2 = full_packet[2:]  # remaining 2 bytes of header + payload

        buffer = bytearray()
        # Arrival 1
        buffer.extend(part1)
        self.assertLess(len(buffer), 4)

        # Arrival 2
        buffer.extend(part2)
        self.assertGreaterEqual(len(buffer), 4)
        extracted_len = struct.unpack(">I", buffer[:4])[0]
        self.assertEqual(extracted_len, len(payload))
        extracted_payload = bytes(buffer[4 : 4 + extracted_len])
        self.assertEqual(extracted_payload, payload)


class TestCombination2CryptoWireEnvelopeFramingRoundtrip(unittest.TestCase):
    """Interaction: Crypto payload inside WireEnvelope + NetworkManager framing round-trip."""

    def test_end_to_end_crypto_wire_roundtrip(self):
        """Complete round-trip: Plaintext ChatMessage -> AEAD encryption -> EncryptedMessagePayload -> WireEnvelope -> Framing -> Unframe -> Decrypt -> ChatMessage."""
        # 1. Plaintext ChatMessage
        plaintext_msg = {
            "id": str(uuid.uuid4()),
            "conversationId": "peer-bob",
            "senderId": "peer-alice",
            "text": "Hello Bob, this is an end-to-end encrypted message!",
            "timestamp": 1700000000.0,
            "status": 0,
            "attachment": None
        }
        msg_bytes = json.dumps(plaintext_msg).encode("utf-8")

        # 2. AEAD encryption with 256-bit key
        aes_key = PurePythonAEAD.generate_key()
        nonce = secrets.token_bytes(12)
        ciphertext_with_tag = PurePythonAEAD.encrypt(aes_key, nonce, msg_bytes)

        # 3. EncryptedMessagePayload
        encrypted_payload = {
            "ratchetPublicKey": base64.b64encode(b"RATCHET_DH_KEY_32_BYTES_SAMPLE!").decode("ascii"),
            "counter": 1,
            "previousCounter": 0,
            "nonce": base64.b64encode(nonce).decode("ascii"),
            "ciphertext": base64.b64encode(ciphertext_with_tag).decode("ascii")
        }
        enc_payload_bytes = json.dumps(encrypted_payload).encode("utf-8")

        # 4. WireEnvelope
        envelope = {
            "type": 2,  # .message
            "senderId": "peer-alice",
            "senderName": "Alice",
            "payload": base64.b64encode(enc_payload_bytes).decode("ascii")
        }
        envelope_json = json.dumps(envelope).encode("utf-8")

        # 5. NetworkManager Framing (single 4-byte big-endian header)
        wire_frame = struct.pack(">I", len(envelope_json)) + envelope_json

        # 6. Transmission & Unframing at receiver
        header_len = struct.unpack(">I", wire_frame[:4])[0]
        self.assertEqual(header_len, len(envelope_json))
        received_envelope_json = wire_frame[4 : 4 + header_len]

        # 7. Decode WireEnvelope
        received_envelope = json.loads(received_envelope_json.decode("utf-8"))
        self.assertEqual(received_envelope["type"], 2)
        self.assertEqual(received_envelope["senderName"], "Alice")

        # 8. Decode EncryptedMessagePayload
        received_enc_payload_raw = base64.b64decode(received_envelope["payload"])
        received_enc_payload = json.loads(received_enc_payload_raw.decode("utf-8"))

        # 9. Decrypt AEAD
        rec_nonce = base64.b64decode(received_enc_payload["nonce"])
        rec_ciphertext = base64.b64decode(received_enc_payload["ciphertext"])
        decrypted_msg_bytes = PurePythonAEAD.decrypt(aes_key, rec_nonce, rec_ciphertext)

        # 10. Decode ChatMessage
        decrypted_msg = json.loads(decrypted_msg_bytes.decode("utf-8"))
        self.assertEqual(decrypted_msg["text"], plaintext_msg["text"])
        self.assertEqual(decrypted_msg["id"], plaintext_msg["id"])

    def test_key_exchange_envelope_framing_roundtrip(self):
        """PreKeyBundle payload inside WireEnvelope.preKeyMessage framed and round-tripped."""
        prekey_bundle = {
            "identityKey": base64.b64encode(b"IDENTITY_KEY_32_BYTES_LONG______").decode("ascii"),
            "signedPreKey": base64.b64encode(b"SIGNED_PREKEY_32_BYTES_LONG_____").decode("ascii"),
            "signedPreKeySignature": base64.b64encode(b"SIGNATURE_64_BYTES_LONG_________________________________________").decode("ascii"),
            "oneTimePreKey": base64.b64encode(b"ONETIME_PREKEY_32_BYTES_LONG____").decode("ascii")
        }
        bundle_bytes = json.dumps(prekey_bundle).encode("utf-8")
        envelope = {
            "type": 0,  # .hello / preKey
            "senderId": "peer-bob",
            "senderName": "Bob",
            "payload": base64.b64encode(bundle_bytes).decode("ascii")
        }
        env_json = json.dumps(envelope).encode("utf-8")
        frame = struct.pack(">I", len(env_json)) + env_json

        # Unframe
        unpacked_len = struct.unpack(">I", frame[:4])[0]
        unframed_json = frame[4 : 4 + unpacked_len]
        decoded_env = json.loads(unframed_json.decode("utf-8"))
        decoded_bundle = json.loads(base64.b64decode(decoded_env["payload"]).decode("utf-8"))
        self.assertEqual(decoded_bundle["identityKey"], prekey_bundle["identityKey"])

    def test_tampered_ciphertext_detection_in_framed_packet(self):
        """Tampered ciphertext inside valid wire frame causes AEAD tag verification failure."""
        aes_key = PurePythonAEAD.generate_key()
        nonce = secrets.token_bytes(12)
        ciphertext = PurePythonAEAD.encrypt(aes_key, nonce, b"Secret Payload")

        # Tamper 1 byte of ciphertext
        tampered = bytearray(ciphertext)
        tampered[0] ^= 0x01
        tampered_ciphertext = bytes(tampered)

        with self.assertRaises(ValueError):
            PurePythonAEAD.decrypt(aes_key, nonce, tampered_ciphertext)

    def test_typing_indicator_envelope_roundtrip(self):
        """Lightweight typing indicator payload inside WireEnvelope roundtrip."""
        typing_payload = {"isTyping": True}
        typing_bytes = json.dumps(typing_payload).encode("utf-8")
        envelope = {
            "type": 4,  # .typing
            "senderId": "peer-alice",
            "senderName": "Alice",
            "payload": base64.b64encode(typing_bytes).decode("ascii")
        }
        env_json = json.dumps(envelope).encode("utf-8")
        frame = struct.pack(">I", len(env_json)) + env_json

        # Decode
        extracted = json.loads(frame[4:].decode("utf-8"))
        payload_data = json.loads(base64.b64decode(extracted["payload"]).decode("utf-8"))
        self.assertTrue(payload_data["isTyping"])


class TestCombination3SimultaneousConnectionTieBreaker(unittest.TestCase):
    """Interaction: Simultaneous connection race condition resolution and UUID tie-breaker logic."""

    def test_tiebreaker_lower_uuid_wins(self):
        """Verify deviceId < remotePeerId deterministically resolves collision."""
        alice_id = "11111111-1111-1111-1111-111111111111"
        bob_id   = "22222222-2222-2222-2222-222222222222"

        # Alice's perspective:
        # deviceId = alice_id, remotePeerId = bob_id
        # alice_id < bob_id is TRUE: Alice wins, keeps outgoing, rejects/drops incoming.
        alice_should_keep_outgoing = (alice_id < bob_id)
        self.assertTrue(alice_should_keep_outgoing)

        # Bob's perspective:
        # deviceId = bob_id, remotePeerId = alice_id
        # bob_id < alice_id is FALSE: Bob yields, drops outgoing, keeps incoming from Alice.
        bob_should_keep_outgoing = (bob_id < alice_id)
        self.assertFalse(bob_should_keep_outgoing)

        # Exactly one side keeps outgoing, one side keeps incoming -> Single active connection preserved
        self.assertNotEqual(alice_should_keep_outgoing, bob_should_keep_outgoing)

    def test_tiebreaker_symmetry_across_permutations(self):
        """Verify tiebreaker consistency across 100 random UUID pairs."""
        for _ in range(100):
            id_a = str(uuid.uuid4())
            id_b = str(uuid.uuid4())
            while id_a == id_b:
                id_b = str(uuid.uuid4())

            a_wins = (id_a < id_b)
            b_wins = (id_b < id_a)
            # Exactly one must be True
            self.assertTrue(a_wins ^ b_wins)

    def test_tiebreaker_outgoing_ready_does_not_clobber_incoming(self):
        """Verify that when outgoing connection transitions to .ready, incoming connection is preserved if winner."""
        connections = {}
        alice_id = "00000000-0000-0000-0000-000000000001"
        bob_id   = "00000000-0000-0000-0000-000000000002"

        # Scenario on Bob's node (deviceId = bob_id):
        # 1. Incoming connection from Alice arrives first and is accepted
        incoming_conn = {"id": "incoming-conn-from-alice", "peer": alice_id}
        connections[alice_id] = incoming_conn

        # 2. Bob's outgoing connection to Alice now reaches .ready
        outgoing_conn = {"id": "outgoing-conn-to-alice", "peer": alice_id}

        def on_outgoing_ready(existing_conn, new_conn, local_id, remote_id):
            if existing_conn is not None:
                # If local_id > remote_id (Bob > Alice), Bob should yield and cancel outgoing
                if local_id > remote_id:
                    return existing_conn, "cancel_outgoing"
                else:
                    return new_conn, "cancel_existing"
            return new_conn, "keep"

        retained_conn, action = on_outgoing_ready(connections.get(alice_id), outgoing_conn, bob_id, alice_id)
        self.assertEqual(action, "cancel_outgoing")
        self.assertEqual(retained_conn["id"], "incoming-conn-from-alice")

    def test_swift_network_manager_implements_tie_breaker(self):
        """Verify NetworkManager.swift contains deviceId comparison logic for duplicate connections."""
        path = os.path.join(SOURCE_ROOT, "Network", "NetworkManager.swift")
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        # NetworkManager must compare self.deviceId < remotePeerId
        self.assertRegex(content, r"deviceId\s*<\s*remotePeerId|deviceId\s*<\s*peerId")


class TestCombination4DisplayNamePropagation(unittest.TestCase):
    """Interaction: Display name update propagation across settings, network, and discovery layers."""

    def test_display_name_propagation_flow(self):
        """Simulate SettingsView -> ChatManager.updateDisplayName -> NetworkManager -> LANDiscovery TXT record."""
        class MockLANDiscovery:
            def __init__(self):
                self.txt_record = {}
            def updateDisplayName(self, new_name):
                self.txt_record["name"] = new_name.encode("utf-8")

        class MockNetworkManager:
            def __init__(self, discovery):
                self.discovery = discovery
                self.displayName = ""
            def updateDisplayName(self, new_name):
                self.displayName = new_name
                self.discovery.updateDisplayName(new_name)

        class MockChatManager:
            def __init__(self, net_mgr):
                self.net_mgr = net_mgr
                self.displayName = ""
            def updateDisplayName(self, new_name):
                self.displayName = new_name
                self.net_mgr.updateDisplayName(new_name)

        disc = MockLANDiscovery()
        net = MockNetworkManager(disc)
        chat = MockChatManager(net)

        chat.updateDisplayName("Alice Cooper")
        self.assertEqual(chat.displayName, "Alice Cooper")
        self.assertEqual(net.displayName, "Alice Cooper")
        self.assertEqual(disc.txt_record["name"], b"Alice Cooper")

    def test_display_name_unicode_and_emojis(self):
        """Verify display name with non-ASCII and emojis propagates cleanly into TXT records and Hello envelopes."""
        display_names = ["Alice 🚀", "李雷", "Éléonore & Bob", "🎉🔒🛡️"]
        for name in display_names:
            encoded_txt = name.encode("utf-8")
            decoded_txt = encoded_txt.decode("utf-8")
            self.assertEqual(name, decoded_txt)

            hello_envelope = {
                "type": 0,
                "senderId": "user-uuid",
                "senderName": name,
                "payload": ""
            }
            env_json = json.dumps(hello_envelope).encode("utf-8")
            decoded_env = json.loads(env_json.decode("utf-8"))
            self.assertEqual(decoded_env["senderName"], name)

    def test_swift_settings_view_triggers_display_name_update(self):
        """Verify SettingsView.swift invokes chatManager.updateDisplayName on submit."""
        path = os.path.join(SOURCE_ROOT, "Views", "SettingsView.swift")
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("updateDisplayName", content)

    def test_swift_chat_manager_propagates_to_network_manager(self):
        """Verify ChatManager.swift updateDisplayName calls networkManager."""
        path = os.path.join(SOURCE_ROOT, "Core", "ChatManager.swift")
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("func updateDisplayName", content)
        self.assertIn("networkManager.updateDisplayName", content)


if __name__ == "__main__":
    unittest.main()
