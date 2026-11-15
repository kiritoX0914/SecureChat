#!/usr/bin/env python3
"""Independent reference implementation of PROTOCOL.md §5/§8 (Python + cryptography).
Plays device B: decrypts Swift A's vectors, then produces replies for Swift to decrypt."""
import base64, json, sys, os, uuid, hashlib, hmac, struct
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey, Ed25519PrivateKey
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

b64d = base64.b64decode
def b64e(b): return base64.b64encode(b).decode()
RAW = dict(encoding=serialization.Encoding.Raw, format=serialization.PublicFormat.Raw)
def pub(k): return k.public_key().public_bytes(**RAW)
def hkdf(ikm, salt, info, n): return HKDF(hashes.SHA256(), n, salt, info.encode()).derive(ikm)
def dh(priv, pubbytes): return priv.exchange(X25519PublicKey.from_public_bytes(pubbytes))
def kdf_rk(rk, d): o = hkdf(d, rk, "DoubleRatchet", 64); return o[:32], o[32:]
def kdf_ck(ck): return hmac.new(ck, b"\x01", hashlib.sha256).digest(), hmac.new(ck, b"\x02", hashlib.sha256).digest()
def msg_keys(mk): o = hkdf(mk, bytes(32), "MessageKeys", 44); return o[:32], o[32:]
APPLE_EPOCH = 978307200

class Ratchet:
    def __init__(s): s.DHs=None; s.DHr=None; s.RK=None; s.CKs=None; s.CKr=None; s.Ns=s.Nr=s.PN=0; s.skipped={}
    @classmethod
    def responder(cls, sk, spk_priv):
        r = cls(); r.RK = sk; r.DHs = spk_priv; return r
    def skip(s, until):
        if s.DHr is None or until < s.Nr: return
        if len(s.skipped) + (until - s.Nr) > 100: raise ValueError("too many skipped")
        if s.CKr is None: return
        for n in range(s.Nr, until):
            mk, s.CKr = kdf_ck(s.CKr); s.skipped[f"{s.DHr.hex()}:{n}"] = mk
        s.Nr = until
    def decrypt(s, m):
        rp = b64d(m["ratchetPublicKey"]); n = m["messageNumber"]
        k = f"{rp.hex()}:{n}"
        if k in s.skipped: return s._open(s.skipped.pop(k), m)
        if s.DHr is None or rp != s.DHr:
            if s.CKr is not None: s.skip(m["previousChainLength"])
            s.PN = s.Ns; s.Ns = 0; s.Nr = 0; s.DHr = rp
            if s.DHs is not None: s.RK, s.CKr = kdf_rk(s.RK, dh(s.DHs, s.DHr))
            s.DHs = X25519PrivateKey.generate(); s.RK, s.CKs = kdf_rk(s.RK, dh(s.DHs, s.DHr))
        s.skip(n)
        mk, s.CKr = kdf_ck(s.CKr); s.Nr += 1
        return s._open(mk, m)
    def _open(s, mk, m):
        key, nonce = msg_keys(mk)
        return AESGCM(key).decrypt(nonce, b64d(m["ciphertext"]), None)
    def encrypt(s, pt):
        mk, s.CKs = kdf_ck(s.CKs); key, nonce = msg_keys(mk)
        ct = AESGCM(key).encrypt(nonce, pt, None)
        m = {"messageId": str(uuid.uuid4()).upper(), "ciphertext": b64e(ct), "nonce": b64e(nonce),
             "ratchetPublicKey": b64e(pub(s.DHs)), "previousChainLength": s.PN, "messageNumber": s.Ns}
        s.Ns += 1; return m

def envelope(t, sender, name, payload_obj):
    return {"type": t, "senderId": sender, "senderName": name,
            "payload": b64e(json.dumps(payload_obj, separators=(",", ":")).encode())}

def chunk_frames(data, key, tid):
    total = (len(data) + 65535) // 65536; out = []
    for i in range(total):
        aad = tid.bytes + struct.pack(">II", i, total)
        nonce = os.urandom(12)
        box = nonce + AESGCM(key).encrypt(nonce, data[i*65536:(i+1)*65536], aad)
        out.append(b"\x01" + tid.bytes + struct.pack(">II", i, total) + box)
    return out

def main(vec_path, out_path):
    v = json.load(open(vec_path)); B = v["B"]
    ik = X25519PrivateKey.from_private_bytes(b64d(B["identityDHPrivate"]))
    spk = X25519PrivateKey.from_private_bytes(b64d(B["signedPreKeyPrivate"]))
    sig = Ed25519PrivateKey.from_private_bytes(b64d(B["identitySigningPrivate"]))
    hello = json.loads(b64d(B["helloFrame"])); bundle = json.loads(b64d(hello["payload"]))
    assert hello["type"] == 0 and bundle["protocolVersion"] == 2
    assert b64d(bundle["identityDHKey"]) == pub(ik) and b64d(bundle["signedPreKey"]) == pub(spk)
    Ed25519PublicKey.from_public_bytes(b64d(bundle["identitySigningKey"])).verify(
        b64d(bundle["signedPreKeySignature"]), b64d(bundle["signedPreKey"]))
    assert b64d(bundle["identitySigningKey"]) == sig.public_key().public_bytes(**RAW)
    print("bundle + Ed25519 signature ok")

    r = None
    for i, f in enumerate(v["aToB"]):
        env = json.loads(b64d(f)); p = json.loads(b64d(env["payload"]))
        if env["type"] == 1:
            assert r is None and p["signedPreKeyId"] == B["signedPreKeyId"] == 1
            ikA, ek = b64d(p["senderIdentityDHKey"]), b64d(p["ephemeralKey"])
            sk = hkdf(dh(spk, ikA) + dh(ik, ek) + dh(spk, ek), bytes(32), "X3DH", 32)
            r = Ratchet.responder(sk, spk); m = p["encryptedMessage"]
        else:
            assert env["type"] == 2; m = p
        pt = r.decrypt(m)
        assert pt.decode() == v["aToBPlaintexts"][i], (i, pt)
        print(f"python decrypted swift frame {i} (type {env['type']}): {pt[:70].decode(errors='replace')}")
    f = v["file"]; key = b64d(f["key"]); tid = uuid.UUID(f["transferId"]); data = bytearray(f["size"])
    for c in f["chunkFrames"]:
        c = b64d(c); assert c[0] == 1 and uuid.UUID(bytes=c[1:17]) == tid
        idx, total = struct.unpack(">II", c[17:25]); box = c[25:]
        data[idx*65536: idx*65536 + len(box) - 28] = AESGCM(key).decrypt(box[:12], box[12:], c[1:25])
    assert hashlib.sha256(data).hexdigest() == f["sha256"]; print("python decrypted swift file chunks ok")

    A_ID, B_ID = v["A"]["deviceId"], B["deviceId"]
    texts, frames = [], []
    msgs = [
        {"id": str(uuid.uuid4()).upper(), "senderId": B_ID, "recipientId": A_ID, "text": "reply from python B",
         "timestamp": 1784000000.25 - APPLE_EPOCH, "status": 1, "contentType": 0, "senderName": "Bob"},
        {"v": 2, "control": {"kind": "profile", "name": "Bob (python)", "version": 2}},
        {"id": str(uuid.uuid4()).upper(), "senderId": B_ID, "recipientId": A_ID, "text": "多语言 ✓ second reply",
         "timestamp": 1784000001 - APPLE_EPOCH, "status": 1, "contentType": 0, "senderName": "Bob",
         "replyToId": str(uuid.uuid4()), "replyToText": "hello from swift A", "replyToSender": "Alice"},
    ]
    for m in msgs:
        frames.append(b64e(json.dumps(envelope(2, B_ID, "Bob", r.encrypt(json.dumps(m, ensure_ascii=False).encode()))).encode()))
        texts.append(m.get("text") or m["control"]["kind"])
    fdata = bytes((i * 17 + 3) & 0xFF for i in range(70000)); fkey = os.urandom(32)
    json.dump({"bToA": frames, "bToAText": texts,
               "file": {"key": b64e(fkey), "sha256": hashlib.sha256(fdata).hexdigest(),
                        "chunkFrames": [b64e(c) for c in chunk_frames(fdata, fkey, uuid.uuid4())]}},
              open(out_path, "w"), indent=1, ensure_ascii=False)
    print("PYTHON OK")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
