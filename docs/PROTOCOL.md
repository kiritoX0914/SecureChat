# SecureChat LAN Protocol — v2 (app versions 1.2 – 1.4)

This document describes the wire protocol exactly as implemented by the iOS / Mac Catalyst
app (Swift sources: `Models/Models.swift`, `Crypto/SignalCrypto.swift`, `Crypto/CryptoEngine.swift`,
`Network/NetworkManager.swift`, `Network/LANDiscovery.swift`, `Core/ChatManager.swift`).
A third-party client (e.g. Windows) that follows it can chat, exchange files and join groups
with the Apple clients. Where the Swift code has a quirk, the quirk is documented — implement
the quirk, not the "textbook" algorithm.

Conventions: `||` = byte concatenation, `BE` = big-endian, all keys are raw 32-byte
Curve25519 / Ed25519 encodings, "hex" is lowercase.

---------------------------------------------------------------------------------------------

## 1. Transport

| Item | Value |
|---|---|
| Transport | plain TCP (no TLS — all confidentiality comes from the E2E layer) |
| Listener port | **47823** (if busy the app falls back to a random port; such a peer is only reachable via Bonjour / manual connect) |
| UDP beacon port | **47824** |
| Bonjour type | `_securechat._tcp` (optional; TrollStore iOS builds can't use it) |
| Address family | IPv4 (IPv4-mapped IPv6 is accepted) |
| Recommended socket opts | `TCP_NODELAY`; keep-alive idle 10 s, interval 5 s, count 3 |

Exactly **one TCP connection per peer pair** is used for everything (both directions).
Either side may dial.

### 1.1 Framing

Every frame is

```
[4-byte BE uint32 length N][N bytes payload]
```

* `N` must be `1 … 157 286 400` (150 MiB). `N == 0` or larger ⇒ receiver closes the link.
* Payload kind is decided by its first byte:
  * `0x7B` (`{`) → UTF-8 JSON **WireEnvelope** (§2)
  * `0x01` → binary **file chunk** frame (§8)
  * anything else → ignored (after identification) / link closed (before identification).

### 1.2 JSON encoding rules (Swift `JSONEncoder` defaults — must match for decoding on Apple side)

| Swift type | JSON representation |
|---|---|
| `Data` | standard **Base64 with padding** string (Swift escapes `/` as `\/`; any JSON parser handles it) |
| `Date` | **number = seconds since 2001-01-01T00:00:00Z** (Apple reference date). `unix = value + 978307200` |
| `UUID` | string `XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`; Apple emits **uppercase**, accepts either case |
| enums with Int raw value | JSON integer |
| `ControlMessage.Kind` | JSON string |
| Optionals | key **omitted** when nil (sending `null` is also accepted) |
| Integers | must be JSON integers (don't send `1.0`) |

Unknown keys are ignored by the Apple decoder, so you may add your own fields.

---------------------------------------------------------------------------------------------

## 2. WireEnvelope (outer, unencrypted JSON)

```json
{ "type": 2, "senderId": "B0F1…-UUID", "senderName": "Alice", "payload": "<base64 of inner JSON>" }
```

| field | type | meaning |
|---|---|---|
| `type` | int | see table |
| `senderId` | string | sender's **deviceId** (uppercase UUID string, generated once and persisted) |
| `senderName` | string | sender's current display name (receiver updates the contact name from every envelope) |
| `payload` | base64 | **bytes of a JSON document** whose schema depends on `type` |

| type | name | payload JSON | encrypted? |
|---|---|---|---|
| 0 | hello | `PreKeyBundlePayload` (§4.1) | no |
| 1 | preKeyMessage | `PreKeyMessagePayload` (§5.3) | yes (X3DH + ratchet) |
| 2 | message | `EncryptedMessagePayload` (§5.2) | yes (ratchet) |
| 3 | ack | `AckPayload` (§7.2) | **no** |
| 4 | typing | `{"isTyping": true}` | **no** |
| 7 | ping | `{"t": <unix seconds double>}` (content ignored) | no |

Types 5 and 6 are unused. Unknown types: ignore the frame.

**Heartbeat detection quirk:** the receiver marks a link as "ping capable" when a frame shorter
than 512 bytes starts with `{` and contains the exact substring `"type":7` (no space). Emit
compact JSON so your pings are recognised (otherwise your link is just never timed out — harmless).

---------------------------------------------------------------------------------------------

## 3. Link life-cycle

1. **Connect** (either side). As soon as the TCP connection is up, **both** sides immediately send an
   *identification hello*: a type-0 envelope whose bundle has `protocolVersion: 2` and **no
   `hasSession` key**.
2. **Identification.** The first frame received on a fresh link **must** be a JSON envelope; its
   `senderId` identifies the link. A non-JSON first frame ⇒ link closed.
   * `senderId == own id` (dialed yourself) ⇒ close.
   * Incoming links that don't identify within **15 s** are closed; outgoing probe links that
     don't receive a hello within **6 s** of connecting are closed.
3. **Duplicate links.** If a link for that peer already exists:
   * if the existing one became active **< 3 s** ago (simultaneous dial) and the two links were
     initiated by different sides, keep the link **initiated by the smaller deviceId**
     (`min(idA, idB)` by ordinal string compare) and close the other;
   * otherwise keep the **new** link and close the old one.
4. Once a link is the active link for a peer, send the **full hello** (type 0 with
   `hasSession: true|false`, §4.2). Processing of the identification hello by the receiver only
   stores the bundle; the session logic runs on the full hello.
5. **Heartbeat.** Every **5 s** send a type-7 ping on every identified link. A ping-capable link
   with nothing received for **25 s** is closed (peer shown offline).
6. On close, the peer is offline; queued messages are kept and retransmitted on the next session
   (§7.3).

---------------------------------------------------------------------------------------------

## 4. Hello & session negotiation

### 4.1 PreKeyBundlePayload (type 0 payload)

```json
{
  "identityDHKey":         "<b64 32B X25519 public>",
  "identitySigningKey":    "<b64 32B Ed25519 public>",
  "signedPreKeyId":        1,
  "signedPreKey":          "<b64 32B X25519 public>",
  "signedPreKeySignature": "<b64 64B Ed25519 signature over the 32 raw signedPreKey bytes>",
  "protocolVersion":       2,
  "hasSession":            true            // omitted in the identification hello
}
```

* `oneTimePreKeyId` / `oneTimePreKey` exist in the schema but v2 clients **never send them**
  (omit them). If you ever receive one, you may ignore it.
* The signed pre-key id is always **1** and the key is never rotated (generated once, persisted).
* `protocolVersion` missing or < 2 ⇒ legacy v1.1 peer (lazy sessions, no control messages, no
  chunked files). New clients should only support v2.

### 4.2 Who initiates

Deterministic: **the side whose deviceId is smaller (ordinal string comparison) is the X3DH
initiator.** On receiving a **full** hello (`hasSession` present) from peer P:

*Smaller side (initiator)*
* if it has **no** ratchet session for P, **or** P says `hasSession: false` ⇒ discard any old
  session, run X3DH with P's bundle (§5.1) and immediately send a **type-1 preKeyMessage** whose
  plaintext is the control message `{"v":2,"control":{"kind":"sessionInit"}}`. The session is now
  ready.
* else ⇒ session ready.

*Larger side (responder)*
* if P says `hasSession: false` ⇒ discard any old session and wait for P's preKeyMessage.
* if it has a session (and isn't waiting) ⇒ ready; else wait for the preKeyMessage.
* when a type-1 message arrives and decrypts ⇒ ready.

`hasSession` you send = "I hold a ratchet session for you and I am not waiting for your
sessionInit".

**When a session becomes ready** the app sends, in order: its `profile` control (§7.5);
`groupInfoRequest` for every group placeholder (version 0) the peer is in; queued control
messages; then all chat messages still pending for that peer.

### 4.3 Decryption failure recovery

If a type-1/2 message fails to decrypt (at most once per **8 s** per peer):
* discard the session;
* smaller side: re-run X3DH with the last stored bundle of P and send a new sessionInit;
* larger side: send a full hello with `hasSession: false` and wait.

---------------------------------------------------------------------------------------------

## 5. Cryptography

Primitives: X25519, Ed25519 (pure, RFC 8032 — CryptoKit signatures are randomized but verify
with any standard verifier), HKDF-SHA256 (RFC 5869, extract+expand), HMAC-SHA256,
AES-256-GCM (12-byte nonce, 16-byte tag).

Long-term keys per device (persist them!): identity X25519 key `IK`, identity Ed25519 key `IKsig`,
signed pre-key X25519 `SPK` (id 1) with `sig = Ed25519_sign(IKsig, SPK_pub_raw32)`.

### 5.1 X3DH (no one-time pre-key in v2)

Initiator A with responder B's bundle:

```
verify Ed25519(B.identitySigningKey, B.signedPreKey, B.signedPreKeySignature)  else abort
EK = new X25519 keypair
DH1 = X25519(IK_A.priv, SPK_B)
DH2 = X25519(EK.priv,   IK_B)
DH3 = X25519(EK.priv,   SPK_B)
[DH4 = X25519(EK.priv, OPK_B)  only if a one-time pre-key was used — never in v2]
SK  = HKDF-SHA256(IKM = DH1||DH2||DH3[||DH4], salt = 32 zero bytes, info = "X3DH", L = 32)
```

Responder B mirrors: `DH1 = X25519(SPK_B.priv, IK_A)`, `DH2 = X25519(IK_B.priv, EK_A)`,
`DH3 = X25519(SPK_B.priv, EK_A)`.

* **No** 0xFF×32 prefix (unlike Signal). The X3DH "associated data" is computed but **not used**
  anywhere (AES-GCM below has no AAD).

### 5.2 Double Ratchet

KDFs:
```
KDF_RK(rk, dh)  = HKDF-SHA256(IKM = dh, salt = rk, info = "DoubleRatchet", L = 64) → (rk' = [0..32), ck = [32..64))
KDF_CK(ck)      = mk = HMAC-SHA256(key = ck, msg = 0x01) ; ck' = HMAC-SHA256(key = ck, msg = 0x02)
MSG_KEYS(mk)    = HKDF-SHA256(IKM = mk, salt = 32 zero bytes, info = "MessageKeys", L = 44)
                  → aesKey = [0..32), nonce = [32..44)
```

State: `DHs` (own ratchet keypair), `DHr` (their ratchet pub), `RK`, `CKs`, `CKr`, `Ns`, `Nr`, `PN`,
`skipped` map keyed `"<hex(ratchetPub)>:<n>"` → mk (max **100** entries in total).

*Init initiator (A):* `RK = SK; DHr = SPK_B; DHs = new; (RK, CKs) = KDF_RK(RK, X25519(DHs, DHr))`;
`CKr = nil; Ns = Nr = PN = 0`.

*Init responder (B):* `RK = SK; DHs = SPK_B keypair (the signed pre-key itself!); DHr = CKs = CKr = nil`.
B can't send until it has decrypted A's first message.

*Encrypt(plaintext):*
```
require CKs
(mk, CKs) = KDF_CK(CKs)
(key, nonce) = MSG_KEYS(mk)
ct||tag = AES-256-GCM-Seal(key, nonce, plaintext, aad = none)
header: ratchetPublicKey = DHs.pub, previousChainLength = PN, messageNumber = Ns ; Ns += 1
```
`EncryptedMessagePayload` (type 2 payload):
```json
{ "messageId": "<random UUID, unused>", "ciphertext": "<b64 ct||16B tag>", "nonce": "<b64 12B>",
  "ratchetPublicKey": "<b64 32B>", "previousChainLength": 0, "messageNumber": 0 }
```
The receiver **re-derives** the nonce from the message key and ignores the `nonce` field (send it
anyway; it is required by the decoder).

*Decrypt(msg):* (transactional — on any error, the state must be left unchanged)
```
1. if skipped["hex(msg.ratchetPublicKey):msg.messageNumber"] exists → use & delete it, decrypt, done
2. if DHr == nil or msg.ratchetPublicKey != DHr:           # DH ratchet step
       if CKr != nil: skip(until = msg.previousChainLength)   # stores keys under the OLD DHr
       PN = Ns ; Ns = 0 ; Nr = 0
       DHr = msg.ratchetPublicKey
       if DHs != nil: (RK, CKr) = KDF_RK(RK, X25519(DHs.priv, DHr))
       DHs = new keypair
       (RK, CKs) = KDF_RK(RK, X25519(DHs.priv, DHr))
3. skip(until = msg.messageNumber)
4. require CKr ; (mk, CKr) = KDF_CK(CKr) ; Nr += 1 ; decrypt with MSG_KEYS(mk)

skip(until): if DHr == nil → return; if until < Nr → return
             if len(skipped) + (until - Nr) > 100 → error
             if CKr == nil → return
             for n in Nr ..< until: (mk, CKr) = KDF_CK(CKr); skipped["hex(DHr):n"] = mk
             Nr = until
```

### 5.3 PreKeyMessage (type 1 payload)

Only the **first** message encrypted after X3DH by the initiator is wrapped like this; **every
later message is a plain type 2**, even if the responder hasn't answered yet.

```json
{ "signedPreKeyId": 1,
  "senderIdentityDHKey":      "<b64 IK_A pub>",
  "senderIdentitySigningKey": "<b64 IKsig_A pub>",
  "ephemeralKey":             "<b64 EK pub>",
  "encryptedMessage":         { …EncryptedMessagePayload… } }
```
(`oneTimePreKeyId` omitted in v2.) Responder: require `signedPreKeyId == own SPK id (1)`, run
responder X3DH, init responder ratchet, decrypt `encryptedMessage`, **replace** any existing session
with the new one.

### 5.4 Plaintext inside the ratchet

The decrypted bytes are UTF-8 JSON, one of:
* a **ChatMessage** (§6) — recognised because it decodes as ChatMessage (has `id`, `senderId`,
  `recipientId`, `timestamp`);
* an **InnerEnvelope** `{"v": 2, "control": ControlMessage}` (§7).

---------------------------------------------------------------------------------------------

## 6. ChatMessage (encrypted)

```json
{
  "id": "UUID",                 // message id, used for acks / delete / reply / dedupe
  "senderId": "<own deviceId>", // MUST equal the link's peer id or the receiver drops it
  "recipientId": "<peer deviceId, or groupId for group messages>",
  "text": "hello",              // for media: "📷 Photo", "🎬 Video", "📎 <filename>"
  "timestamp": 784000000.0,     // Apple reference-date seconds
  "status": 1,                  // send 1 (sent); 0 sending,1 sent,2 delivered,3 read,4 failed
  "contentType": 0,             // 0 text, 1 image (inline), 2 file (incl. video)
  "attachment": { … },          // optional, §6.1
  "replyToId": "UUID",          // optional – message being replied to
  "replyToText": "≤140 chars",  // optional – preview of replied message
  "replyToSender": "Bob",       // optional – display name of replied message's sender
  "groupId": "group-UUID",      // optional – present for group messages
  "senderName": "Alice"         // sender display name (always sent by Apple clients)
}
```
Do not send `pendingRecipients`.

The receiver de-duplicates by `id` (a retransmission is just acked again — or, for an
unfinished file, restarts the transfer with the new key).

### 6.1 Attachment

| field | type | notes |
|---|---|---|
| `filename` | string | |
| `mimeType` | string | `video/*` ⇒ shown as video |
| `fileSize` | int64 | bytes |
| `data` | base64? | **inline bytes — images only** (contentType 1) |
| `width`,`height` | int? | images/videos |
| `thumbnailData` | base64? | small JPEG preview (images ≤120 px, videos ≤480 px) |
| `duration` | double? | video seconds |
| `transferId` | UUID? | chunked files: **equals the message `id`** |
| `fileKey` | base64? | chunked files: 32-byte AES-256-GCM key (fresh random per transmission) |
| `chunkSize` | int? | **65536** |
| `chunkCount` | int? | `ceil(fileSize / 65536)` (0 for an empty file) |

Local-only fields `localFile`, `isComplete` must not be sent.

* **Images (contentType 1):** Apple clients resize to ≤2048 px longest side, JPEG quality 0.75,
  mime `image/jpeg`, and send the bytes inline in `data`. Max frame size (150 MiB) bounds inline data.
* **Files & videos (contentType 2):** `data` omitted; `transferId`, `fileKey`, `chunkSize`,
  `chunkCount` set; bytes follow as chunk frames (§8). Max 4 GiB.

---------------------------------------------------------------------------------------------

## 7. Control messages, acks, typing

### 7.1 ControlMessage (inside `{"v":2,"control":…}`, encrypted)

```json
{ "kind": "delete", "ids": ["UUID",…], "groupId": "group-…", "name": "…", "avatar": "<b64>",
  "group": { GroupInfo }, "version": 3 }
```
Only the fields relevant for the kind are present.

| kind | fields | receiver behaviour |
|---|---|---|
| `sessionInit` | – | none (the pre-key message itself creates the session) |
| `profile` | `name`, `avatar?`, `version` | set contact display name (if non-empty) and avatar (**absent avatar clears it**); `version` is informational |
| `delete` | `ids`, `groupId?` | delete those message ids in the 1:1 chat with the sender, or in group `groupId` (only if the sender is a member) — "delete for both / everyone" |
| `clear` | `groupId?` | delete all messages of that chat |
| `groupUpdate` | `groupId`, `group` | §9 |
| `groupLeave` | `groupId` | remove sender from the group's member list |
| `groupInfoRequest` | `groupId` | if requester is a member and local version > 0, reply with `groupUpdate` |

"Delete for me" is local only (nothing on the wire).

### 7.2 Ack (type 3, **plaintext** envelope)

```json
{ "messageId": "UUID", "status": 2, "groupId": "group-…" }
```
* `status 2` (delivered) — sent when a message is received (for chunked files: **after the last
  chunk** is written). Also re-sent for duplicates.
* `status 3` (read) — sent when the user opens the chat.
* `groupId` set for group messages. Acks are sent to the message's original sender only.

### 7.3 Outbox / retransmission

The sender keeps, per message, the list of recipients that haven't acked. Whenever a session
with such a recipient becomes ready (§4.2), every pending message is re-encrypted and re-sent
(files: with a fresh `fileKey`, chunks re-sent from 0). Receivers must therefore be idempotent on
`id`.

### 7.4 Typing (type 4, plaintext)

`{"isTyping": true}` while typing, `{"isTyping": false}` after 3 s idle or on send. 1:1 only.

### 7.5 Profile

Sent when a session becomes ready and whenever the user changes name/avatar. Avatar = JPEG,
≤256 px, quality 0.75. There are no per-contact nicknames.

---------------------------------------------------------------------------------------------

## 8. Chunked file transfer

Immediately after the encrypted ChatMessage that announces the file is sent **on the same
link**, the sender streams the chunks (the receiver registers the transfer when it decrypts the
message, so chunks for unknown transfers are dropped — order matters).

Chunk frame payload (inside normal length-prefixed framing):

```
0x01 || transferId (16 raw UUID bytes, RFC 4122 byte order) || index (uint32 BE) || total (uint32 BE) || box
box  = AES-256-GCM "combined" = nonce(12, random) || ciphertext || tag(16)
key  = attachment.fileKey (32 bytes)
AAD  = transferId(16) || index(uint32 BE) || total(uint32 BE)
plaintext = bytes [index*65536, min(fileSize, (index+1)*65536))
```

* **UUID bytes:** the 16 bytes are the UUID in string order (`B2222222-…` → `b2 22 22 22 …`).
  On .NET use `Guid.ToByteArray(bigEndian: true)` (.NET 8+) — the classic `ToByteArray()` is
  mixed-endian and will break the AAD. Rust `uuid::Uuid::as_bytes()` is correct.
* `total == chunkCount`; chunks may arrive in any order; duplicates ignored; receiver writes at
  offset `index * chunkSize`. Bad tag ⇒ chunk dropped.
* Apple sender keeps ≤8 chunks in flight. When all `total` indexes are received, the receiver
  marks the file complete and sends the delivered ack.
* An empty file has `chunkCount 0` and no chunk frames.

---------------------------------------------------------------------------------------------

## 9. Groups

* Group id: `"group-" + UUID` (uppercase). No group key — **every group message is sent
  pairwise** through each member's 1:1 ratchet (normal type-2 ChatMessage with `groupId` set and
  `recipientId = groupId`). No relaying: a member only gets messages from members it is
  connected to.

GroupInfo:
```json
{ "id": "group-…", "name": "Team", "members": ["deviceId",…], "memberNames": {"deviceId": "Name"},
  "createdBy": "deviceId", "version": 1, "updatedAt": 784000000.0, "avatarData": "<b64>?" }
```
* Creating: members include the creator, `version 1`; send `groupUpdate` to every other member.
* Any member may rename / add / remove: apply change, set own `memberNames` entry,
  `version += 1`, `updatedAt = now`, send `groupUpdate` to all members (a removed member also gets
  the update).
* Receiving `groupUpdate`: accept only if the sender is in `group.members` or is `createdBy`.
  If the group is known, replace it when `incoming.version > local.version` or (equal version and
  later `updatedAt`). If unknown, create it only if it lists you as a member.
* A group message for an unknown group creates a placeholder (name "Group", members
  {sender, me}, version 0) and sends `groupInfoRequest` to the sender.
* Leaving: send `groupLeave` to all other members, remove yourself locally.
* Group acks carry `groupId`; delete/clear controls carry `groupId`.

---------------------------------------------------------------------------------------------

## 10. Discovery

All are optional ways to *find* a peer's IP; the conversation always happens over TCP 47823.

1. **Remembered hosts** — store the IPv4 of every peer you connected to; re-dial each one that is
   not connected every ~5 s (with 0–1.5 s jitter) and on app start / resume.
2. **Subnet sweep** — for every up, non-loopback IPv4 interface (`en*`, `bridge*`, `ap*`, `eth*`
   on Apple), take its subnet (capped to the /24 containing the address), and try TCP 47823 on
   every host except own address and already connected ones. Apple: 24 concurrent connects, 2 s
   connect timeout, sweep every 15 s while nobody is online, 60 s otherwise, and immediately on
   resume / "Scan" button. A host that accepts but doesn't send a hello within 6 s is dropped.
   *The Mac Catalyst build (1.3+) never sweeps or re-dials automatically — it only listens and
   scans when the user presses Scan. Phones connect to it.*
3. **UDP beacon** — every 5 s send the ASCII datagram `SCv2|<deviceId>` to UDP 47824 at
   `255.255.255.255` and at each interface's directed broadcast address. Listen on UDP 47824
   (`SO_REUSEADDR`+`SO_REUSEPORT`+`SO_BROADCAST`); on hearing a beacon from another id that isn't
   connected, dial TCP 47823 at the datagram's source IP. (The Mac build ignores beacons.)
4. **Bonjour/mDNS** — service `_securechat._tcp`, instance name
   `SecureChat-<first 12 hex chars of deviceId without dashes>`, TXT keys `deviceId` and
   `displayName`. On Windows you can skip this.
5. **Manual** — connect to a user-typed `IP[:port]`.

Windows notes: allow the app through Windows Defender Firewall for inbound TCP 47823 and UDP
47824 on Private networks, otherwise phones can't reach it.

---------------------------------------------------------------------------------------------

## 11. Persisted client state (needed for interop across restarts)

* deviceId (UUID string) — never changes.
* IK (X25519 private), IKsig (Ed25519 private), SPK private + signature (id 1).
* Per-peer ratchet session state (§5.2), saved after every encrypt/decrypt. If you lose it, send
  your full hello with `hasSession: false` and the pair re-handshakes automatically (§4.2).
* Known peer IPs.

---------------------------------------------------------------------------------------------

## 12. Minimal interop checklist for a new client

1. TCP listener on 47823, length-prefixed framing.
2. On connect send identification hello; on first received envelope identify the peer; then send
   full hello.
3. Implement §4.2 role logic; X3DH + Double Ratchet exactly as §5 (note the zero-salt HKDFs, the
   responder using SPK as its first ratchet key, nonce derived from the message key, no AAD).
4. Text: encrypt ChatMessage JSON, send type 2; ack received messages with type 3 status 2.
5. Pings every 5 s with compact JSON (`"type":7`).
6. Files: §6.1 + §8. Images inline JPEG.
7. Controls: profile, delete, clear, groups.
8. Discovery: remembered hosts + /24 sweep + UDP beacon.

Interop test vectors generated from the Swift implementation, plus a Python reference check,
are in `PROTOCOL-vectors.json` / `protocol_check.py` next to this file (if present).
