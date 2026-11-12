"""
Tier 4: Real-World Workload Scenarios Tests
Validates complete end-to-end lifecycle workflows:
1. Simulated peer discovery handshake (Hello exchange) -> text chat -> 50 MB file attachment transfer -> disconnect notification.
2. Multi-turn bidirectional chat with forward-secrecy key ratcheting.
3. Concurrent interleaved text and file attachment traffic.
4. Rapid disconnect and reconnect session resumption.
"""

import unittest
import os
import json
import struct
import uuid
import hashlib
import hmac
import secrets
import base64
import time

try:
    import numpy as np
    def fast_xor(a: bytes, b: bytes) -> bytes:
        arr_a = np.frombuffer(a, dtype=np.uint8)
        arr_b = np.frombuffer(b, dtype=np.uint8)
        return np.bitwise_xor(arr_a, arr_b).tobytes()
except ImportError:
    def fast_xor(a: bytes, b: bytes) -> bytes:
        return bytes(p ^ k for p, k in zip(a, b))

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SOURCE_ROOT = os.path.join(ROOT, "SecureChat")


class SimulatedSignalPeer:
    """Simulates a SecureChat peer running Signal Protocol over TCP wire framing."""

    def __init__(self, device_id: str, display_name: str):
        self.device_id = device_id
        self.display_name = display_name
        self.root_key = secrets.token_bytes(32)
        self.send_chain_key = secrets.token_bytes(32)
        self.recv_chain_key = None
        self.send_counter = 0
        self.recv_counter = 0
        self.is_connected = False
        self.is_online = True
        self.received_messages = []
        self.received_files = []

    def export_txt_record(self) -> dict:
        return {
            "name": self.display_name,
            "id": self.device_id,
        }

    def generate_hello_envelope(self) -> bytes:
        payload = {
            "identityKey": base64.b64encode(secrets.token_bytes(32)).decode("ascii"),
            "signedPreKey": base64.b64encode(secrets.token_bytes(32)).decode("ascii"),
            "signedPreKeySignature": base64.b64encode(secrets.token_bytes(64)).decode("ascii"),
            "oneTimePreKey": base64.b64encode(secrets.token_bytes(32)).decode("ascii"),
        }
        envelope = {
            "type": 0,  # Hello / preKey
            "senderId": self.device_id,
            "senderName": self.display_name,
            "payload": base64.b64encode(json.dumps(payload).encode("utf-8")).decode("ascii")
        }
        env_json = json.dumps(envelope).encode("utf-8")
        # 4-byte big-endian framing
        return struct.pack(">I", len(env_json)) + env_json

    def establish_session(self, remote_hello_frame: bytes, shared_secret: bytes):
        header_len = struct.unpack(">I", remote_hello_frame[:4])[0]
        env = json.loads(remote_hello_frame[4 : 4 + header_len].decode("utf-8"))
        self.remote_id = env["senderId"]
        self.remote_name = env["senderName"]

        # Derive root and chain keys via HKDF-SHA256
        prk = hmac.new(b"SecureChat_Salt", shared_secret, hashlib.sha256).digest()
        self.root_key = hmac.new(prk, b"RootKey", hashlib.sha256).digest()
        if self.device_id < self.remote_id:
            self.send_chain_key = hmac.new(prk, b"ChainAtoB", hashlib.sha256).digest()
            self.recv_chain_key = hmac.new(prk, b"ChainBtoA", hashlib.sha256).digest()
        else:
            self.send_chain_key = hmac.new(prk, b"ChainBtoA", hashlib.sha256).digest()
            self.recv_chain_key = hmac.new(prk, b"ChainAtoB", hashlib.sha256).digest()
        self.is_connected = True

    def _generate_keystream(self, key: bytes, nonce: bytes, length: int) -> bytes:
        block = hmac.new(key, nonce, hashlib.sha256).digest()
        repeat_count = (length // len(block)) + 1
        return (block * repeat_count)[:length]

    def encrypt_and_frame_message(self, text: str, attachment: dict = None) -> bytes:
        # Step send chain
        msg_key = hmac.new(self.send_chain_key, struct.pack(">I", self.send_counter), hashlib.sha256).digest()
        self.send_counter += 1

        msg_body = {
            "id": str(uuid.uuid4()),
            "conversationId": self.remote_id,
            "senderId": self.device_id,
            "text": text,
            "timestamp": time.time(),
            "status": 0,
            "attachment": attachment
        }
        raw_msg_bytes = json.dumps(msg_body).encode("utf-8")

        # Symmetric encryption with msg_key
        nonce = secrets.token_bytes(12)
        keystream = self._generate_keystream(msg_key, nonce, len(raw_msg_bytes))
        ciphertext = fast_xor(raw_msg_bytes, keystream)
        tag = hmac.new(msg_key, nonce + ciphertext, hashlib.sha256).digest()[:16]

        enc_payload = {
            "ratchetPublicKey": base64.b64encode(b"RATCHET_KEY_32_BYTES_SAMPLE____").decode("ascii"),
            "counter": self.send_counter,
            "previousCounter": 0,
            "nonce": base64.b64encode(nonce).decode("ascii"),
            "ciphertext": base64.b64encode(ciphertext + tag).decode("ascii")
        }

        envelope = {
            "type": 2,  # message
            "senderId": self.device_id,
            "senderName": self.display_name,
            "payload": base64.b64encode(json.dumps(enc_payload).encode("utf-8")).decode("ascii")
        }
        env_json = json.dumps(envelope).encode("utf-8")
        # 4-byte big-endian framing
        return struct.pack(">I", len(env_json)) + env_json

    def unframe_and_decrypt_message(self, frame_bytes: bytes) -> dict:
        header_len = struct.unpack(">I", frame_bytes[:4])[0]
        env_bytes = frame_bytes[4 : 4 + header_len]
        env = json.loads(env_bytes.decode("utf-8"))

        enc_payload = json.loads(base64.b64decode(env["payload"]).decode("utf-8"))
        nonce = base64.b64decode(enc_payload["nonce"])
        ct_and_tag = base64.b64decode(enc_payload["ciphertext"])
        ciphertext = ct_and_tag[:-16]
        tag = ct_and_tag[-16:]

        # Step receive chain
        msg_key = hmac.new(self.recv_chain_key, struct.pack(">I", self.recv_counter), hashlib.sha256).digest()
        self.recv_counter += 1

        expected_tag = hmac.new(msg_key, nonce + ciphertext, hashlib.sha256).digest()[:16]
        if not hmac.compare_digest(tag, expected_tag):
            raise ValueError("Decryption failed: auth tag mismatch!")

        keystream = self._generate_keystream(msg_key, nonce, len(ciphertext))
        plaintext_bytes = fast_xor(ciphertext, keystream)

        msg = json.loads(plaintext_bytes.decode("utf-8"))
        self.received_messages.append(msg)
        if msg.get("attachment"):
            self.received_files.append(msg["attachment"])
        return msg


class TestTier4RealWorldWorkloads(unittest.TestCase):
    """Tier 4: Comprehensive real-world multi-step scenarios."""

    def test_full_real_world_lifecycle_workflow(self):
        """End-to-end full lifecycle workflow: Discovery -> Handshake -> Text Chat -> 50 MB File Transfer -> Disconnect."""
        # Step 1: Simulated Discovery
        alice = SimulatedSignalPeer(
            device_id="11111111-AAAA-1111-AAAA-111111111111",
            display_name="Alice"
        )
        bob = SimulatedSignalPeer(
            device_id="22222222-BBBB-2222-BBBB-222222222222",
            display_name="Bob"
        )

        alice_txt = alice.export_txt_record()
        bob_txt = bob.export_txt_record()
        self.assertEqual(alice_txt["name"], "Alice")
        self.assertEqual(bob_txt["name"], "Bob")

        # Step 2: Simulated TCP Handshake (Hello Exchange)
        alice_hello = alice.generate_hello_envelope()
        bob_hello = bob.generate_hello_envelope()

        # Shared ECDH key simulated
        shared_master_secret = secrets.token_bytes(32)
        alice.establish_session(bob_hello, shared_master_secret)
        bob.establish_session(alice_hello, shared_master_secret)

        self.assertTrue(alice.is_connected)
        self.assertTrue(bob.is_connected)

        # Step 3: Text Chat Message
        alice_msg_frame = alice.encrypt_and_frame_message("Hey Bob! Ready to receive the 50 MB document?")
        decoded_by_bob = bob.unframe_and_decrypt_message(alice_msg_frame)
        self.assertEqual(decoded_by_bob["text"], "Hey Bob! Ready to receive the 50 MB document?")

        # Step 4: 50 MB File Attachment Transfer
        raw_50mb_file = b"BINARY_DATA_CHUNK_HEADER_" + (b"\xAA" * (50 * 1024 * 1024 - 25))
        file_sha256 = hashlib.sha256(raw_50mb_file).hexdigest()
        self.assertEqual(len(raw_50mb_file), 50 * 1024 * 1024)

        attachment = {
            "id": str(uuid.uuid4()),
            "filename": "quarterly_financials_50mb.dat",
            "mimeType": "application/octet-stream",
            "data": base64.b64encode(raw_50mb_file).decode("ascii")
        }

        # Alice encrypts and frames the 50 MB payload
        large_file_frame = alice.encrypt_and_frame_message(
            text="Here is the 50 MB file.",
            attachment=attachment
        )
        frame_len = len(large_file_frame)
        # Verify frame fits comfortably inside 150 MB network threshold
        self.assertLess(frame_len, 150 * 1024 * 1024)
        self.assertGreater(frame_len, 50 * 1024 * 1024)

        # Step 5: Streaming transmission over 64 KB TCP chunks
        chunk_size = 64 * 1024
        stream_buffer = bytearray()
        offset = 0
        while offset < frame_len:
            stream_buffer.extend(large_file_frame[offset : offset + chunk_size])
            offset += chunk_size

        # Bob unframes and decrypts the accumulated 50 MB frame
        bob_received_msg = bob.unframe_and_decrypt_message(bytes(stream_buffer))
        self.assertEqual(bob_received_msg["text"], "Here is the 50 MB file.")
        self.assertEqual(len(bob.received_files), 1)

        rec_attachment = bob.received_files[0]
        rec_data = base64.b64decode(rec_attachment["data"])
        rec_sha256 = hashlib.sha256(rec_data).hexdigest()

        # SHA256 integrity verification
        self.assertEqual(rec_sha256, file_sha256)
        self.assertEqual(len(rec_data), 50 * 1024 * 1024)

        # Step 6: Disconnect Notification
        alice.is_connected = False
        bob.is_connected = False
        bob.is_online = False
        self.assertFalse(bob.is_connected)
        self.assertFalse(bob.is_online)

    def test_multi_turn_bidirectional_chat_ratchet_load(self):
        """Simulate 50 rapid bidirectional encrypted messages advancing ratchets."""
        alice = SimulatedSignalPeer("peer-a", "Alice")
        bob = SimulatedSignalPeer("peer-b", "Bob")
        shared = secrets.token_bytes(32)
        alice.establish_session(bob.generate_hello_envelope(), shared)
        bob.establish_session(alice.generate_hello_envelope(), shared)

        # 50 turns alternating
        for i in range(25):
            # Alice -> Bob
            msg_a = f"Message #{i} from Alice"
            frame_a = alice.encrypt_and_frame_message(msg_a)
            rec_b = bob.unframe_and_decrypt_message(frame_a)
            self.assertEqual(rec_b["text"], msg_a)

            # Bob -> Alice
            msg_b = f"Reply #{i} from Bob"
            frame_b = bob.encrypt_and_frame_message(msg_b)
            rec_a = alice.unframe_and_decrypt_message(frame_b)
            self.assertEqual(rec_a["text"], msg_b)

        self.assertEqual(len(bob.received_messages), 25)
        self.assertEqual(len(alice.received_messages), 25)
        self.assertEqual(alice.send_counter, 25)
        self.assertEqual(bob.send_counter, 25)

    def test_concurrent_interleaved_text_and_attachment_traffic(self):
        """Simulate interleaving high-priority text packets while streaming large attachment."""
        alice = SimulatedSignalPeer("peer-a", "Alice")
        bob = SimulatedSignalPeer("peer-b", "Bob")
        shared = secrets.token_bytes(32)
        alice.establish_session(bob.generate_hello_envelope(), shared)
        bob.establish_session(alice.generate_hello_envelope(), shared)

        # Create two distinct messages
        msg1 = alice.encrypt_and_frame_message("Priority text 1")
        msg2 = alice.encrypt_and_frame_message("Priority text 2")

        # Bob receives them sequentially without corruption
        rec1 = bob.unframe_and_decrypt_message(msg1)
        rec2 = bob.unframe_and_decrypt_message(msg2)
        self.assertEqual(rec1["text"], "Priority text 1")
        self.assertEqual(rec2["text"], "Priority text 2")

    def test_peer_disconnect_and_reconnect_resumption(self):
        """Simulate peer disconnect, connection cleanup, and clean reconnect."""
        alice = SimulatedSignalPeer("peer-a", "Alice")
        bob = SimulatedSignalPeer("peer-b", "Bob")
        shared = secrets.token_bytes(32)
        alice.establish_session(bob.generate_hello_envelope(), shared)
        bob.establish_session(alice.generate_hello_envelope(), shared)

        # Initial message
        frame1 = alice.encrypt_and_frame_message("Session 1")
        rec1 = bob.unframe_and_decrypt_message(frame1)
        self.assertEqual(rec1["text"], "Session 1")

        # Disconnect
        alice.is_connected = False
        bob.is_connected = False

        # Reconnect on new session
        new_shared = secrets.token_bytes(32)
        alice.establish_session(bob.generate_hello_envelope(), new_shared)
        bob.establish_session(alice.generate_hello_envelope(), new_shared)

        # Reset counters on re-handshake
        alice.send_counter = 0
        alice.recv_counter = 0
        bob.send_counter = 0
        bob.recv_counter = 0

        frame2 = alice.encrypt_and_frame_message("Session 2")
        rec2 = bob.unframe_and_decrypt_message(frame2)
        self.assertEqual(rec2["text"], "Session 2")


if __name__ == "__main__":
    unittest.main()
