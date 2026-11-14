// Models.swift
// SecureChat – LAN End-to-End Encrypted Messenger
// Shared data types used across Crypto, Network, and UI layers

import Foundation

// MARK: - Peer

/// A discovered peer on the local network
struct Peer: Identifiable, Codable, Hashable, Sendable {
    let id: String                    // Unique device UUID (or group id for group conversations)
    var displayName: String
    var isOnline: Bool = false
    var lastSeen: Date = Date()

    // Crypto identity (populated after hello exchange)
    var identityDHKeyData: Data?      // Curve25519 DH public key
    var identitySigningKeyData: Data? // Ed25519 signing public key

    /// Avatar chosen by the peer themselves (broadcast via encrypted profile update).
    var avatarData: Data?
    /// Last IPv4 address we reached this peer at (used for auto-reconnect).
    var lastAddress: String?

    var hasIdentity: Bool {
        identityDHKeyData != nil && identitySigningKeyData != nil
    }

    /// Short hex fingerprint for out-of-band identity verification
    var fingerprint: String {
        guard let key = identityDHKeyData else { return "Unknown" }
        return key.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    init(id: String, displayName: String, isOnline: Bool = false, lastSeen: Date = Date(),
         identityDHKeyData: Data? = nil, identitySigningKeyData: Data? = nil,
         avatarData: Data? = nil, lastAddress: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.isOnline = isOnline
        self.lastSeen = lastSeen
        self.identityDHKeyData = identityDHKeyData
        self.identitySigningKeyData = identitySigningKeyData
        self.avatarData = avatarData
        self.lastAddress = lastAddress
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, isOnline, lastSeen, identityDHKeyData, identitySigningKeyData, avatarData, lastAddress
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "Unknown"
        isOnline = try c.decodeIfPresent(Bool.self, forKey: .isOnline) ?? false
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen) ?? Date()
        identityDHKeyData = try c.decodeIfPresent(Data.self, forKey: .identityDHKeyData)
        identitySigningKeyData = try c.decodeIfPresent(Data.self, forKey: .identitySigningKeyData)
        avatarData = try c.decodeIfPresent(Data.self, forKey: .avatarData)
        lastAddress = try c.decodeIfPresent(String.self, forKey: .lastAddress)
    }

    static func == (lhs: Peer, rhs: Peer) -> Bool {
        lhs.id == rhs.id && lhs.displayName == rhs.displayName && lhs.isOnline == rhs.isOnline
            && lhs.avatarData == rhs.avatarData && lhs.identityDHKeyData == rhs.identityDHKeyData
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Chat Message

struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let senderId: String
    let recipientId: String
    let text: String
    let timestamp: Date
    var status: Status
    let contentType: ContentType
    var attachment: Attachment?

    // v1.2 additions (all optional so older peers stay compatible)
    /// Message this one replies to.
    var replyToId: UUID?
    /// Short snippet of the replied message (so the quote renders even if the original was deleted).
    var replyToText: String?
    /// Sender display name of the replied message.
    var replyToSender: String?
    /// Group id if this is a group message.
    var groupId: String?
    /// Sender display name (used in group chats).
    var senderName: String?
    /// Local only: recipients that have not acknowledged this outgoing message yet.
    var pendingRecipients: [String]?

    enum Status: Int, Codable, Equatable, Comparable, Sendable {
        case sending  = 0
        case sent     = 1
        case delivered = 2
        case read     = 3
        case failed   = 4

        static func < (lhs: Status, rhs: Status) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    enum ContentType: Int, Codable, Equatable, Sendable {
        case text  = 0
        case image = 1
        case file  = 2   // includes video (mimeType video/*)
    }

    var isVideo: Bool {
        contentType == .file && (attachment?.isVideo ?? false)
    }

    // MARK: Init helpers

    /// Create a text-only message
    init(id: UUID, senderId: String, recipientId: String, text: String,
         timestamp: Date, status: Status) {
        self.id = id; self.senderId = senderId; self.recipientId = recipientId
        self.text = text; self.timestamp = timestamp; self.status = status
        self.contentType = .text; self.attachment = nil
    }

    /// Create a message with an attachment
    init(id: UUID, senderId: String, recipientId: String, text: String,
         timestamp: Date, status: Status,
         contentType: ContentType, attachment: Attachment?) {
        self.id = id; self.senderId = senderId; self.recipientId = recipientId
        self.text = text; self.timestamp = timestamp; self.status = status
        self.contentType = contentType; self.attachment = attachment
    }

    // MARK: Backward-compatible Codable

    enum CodingKeys: String, CodingKey {
        case id, senderId, recipientId, text, timestamp, status, contentType, attachment
        case replyToId, replyToText, replyToSender, groupId, senderName, pendingRecipients
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(UUID.self, forKey: .id)
        senderId    = try c.decode(String.self, forKey: .senderId)
        recipientId = try c.decode(String.self, forKey: .recipientId)
        text        = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        timestamp   = try c.decode(Date.self, forKey: .timestamp)
        status      = try c.decodeIfPresent(Status.self, forKey: .status) ?? .sent
        contentType = try c.decodeIfPresent(ContentType.self, forKey: .contentType) ?? .text
        attachment  = try c.decodeIfPresent(Attachment.self, forKey: .attachment)
        replyToId   = try c.decodeIfPresent(UUID.self, forKey: .replyToId)
        replyToText = try c.decodeIfPresent(String.self, forKey: .replyToText)
        replyToSender = try c.decodeIfPresent(String.self, forKey: .replyToSender)
        groupId     = try c.decodeIfPresent(String.self, forKey: .groupId)
        senderName  = try c.decodeIfPresent(String.self, forKey: .senderName)
        pendingRecipients = try c.decodeIfPresent([String].self, forKey: .pendingRecipients)
    }

    /// Text used for previews / reply quotes.
    var previewText: String {
        switch contentType {
        case .text: return text
        case .image: return "📷 Photo"
        case .file:
            if isVideo { return "🎬 Video" }
            return "📎 " + (attachment?.filename ?? "File")
        }
    }
}

// MARK: - Attachment

struct Attachment: Codable, Equatable, Sendable {
    var filename: String
    var mimeType: String
    /// Inline bytes. Only used on the wire for small images (and by v1.1 peers).
    /// Locally we keep bytes on disk (see `localFile`) and drop this.
    var data: Data?
    var fileSize: Int64

    // Image / video specific
    var width: Int?
    var height: Int?
    var thumbnailData: Data?   // Small JPEG preview
    var duration: Double?      // Video duration in seconds

    // v1.2 chunked transfer
    /// Path relative to the attachments directory, e.g. "<messageId>/file.pdf".
    var localFile: String?
    /// Chunked transfer id (== message id).
    var transferId: UUID?
    /// Per-file AES-256-GCM key, delivered inside the E2E-encrypted message. Never persisted.
    var fileKey: Data?
    var chunkSize: Int?
    var chunkCount: Int?
    /// Local only: true once the bytes are fully on disk.
    var isComplete: Bool?

    init(filename: String, mimeType: String, data: Data?, fileSize: Int64,
         width: Int? = nil, height: Int? = nil, thumbnailData: Data? = nil) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.fileSize = fileSize
        self.width = width
        self.height = height
        self.thumbnailData = thumbnailData
    }

    enum CodingKeys: String, CodingKey {
        case filename, mimeType, data, fileSize, width, height, thumbnailData, duration
        case localFile, transferId, fileKey, chunkSize, chunkCount, isComplete
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filename = try c.decodeIfPresent(String.self, forKey: .filename) ?? "file"
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? "application/octet-stream"
        data = try c.decodeIfPresent(Data.self, forKey: .data)
        fileSize = try c.decodeIfPresent(Int64.self, forKey: .fileSize) ?? Int64(data?.count ?? 0)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        thumbnailData = try c.decodeIfPresent(Data.self, forKey: .thumbnailData)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        localFile = try c.decodeIfPresent(String.self, forKey: .localFile)
        transferId = try c.decodeIfPresent(UUID.self, forKey: .transferId)
        fileKey = try c.decodeIfPresent(Data.self, forKey: .fileKey)
        chunkSize = try c.decodeIfPresent(Int.self, forKey: .chunkSize)
        chunkCount = try c.decodeIfPresent(Int.self, forKey: .chunkCount)
        isComplete = try c.decodeIfPresent(Bool.self, forKey: .isComplete)
    }

    var isVideo: Bool { mimeType.lowercased().hasPrefix("video/") }
    var isImage: Bool { mimeType.lowercased().hasPrefix("image/") }

    /// Bytes available locally (inline or completed file).
    var isAvailable: Bool {
        if data != nil { return true }
        if localFile != nil && (isComplete ?? true) { return true }
        return false
    }

    /// Human-readable file size string
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    /// System icon name for the file type
    var fileIcon: String {
        switch mimeType.lowercased() {
        case let m where m.hasPrefix("image/"): return "photo.fill"
        case let m where m.hasPrefix("video/"): return "film.fill"
        case let m where m.hasPrefix("audio/"): return "music.note"
        case let m where m.contains("pdf"):     return "doc.richtext"
        case let m where m.contains("zip") || m.contains("archive"): return "doc.zipper"
        default: return "doc.fill"
        }
    }
}

// MARK: - Group

struct GroupInfo: Codable, Equatable, Sendable {
    let id: String               // "group-<UUID>"
    var name: String
    var members: [String]        // device ids, including the creator
    var memberNames: [String: String]
    var createdBy: String
    var version: Int
    var updatedAt: Date
    var avatarData: Data?
}

// MARK: - Conversation

struct Conversation: Identifiable, Equatable, Sendable {
    let id: String                // == peer.id, or group id
    var peer: Peer
    var messages: [ChatMessage] = []
    var unreadCount: Int = 0
    var isTyping: Bool = false
    var preKeyBundle: PreKeyBundlePayload?
    var group: GroupInfo?

    var isGroup: Bool { group != nil }
    var lastMessage: ChatMessage? { messages.last }

    static func == (lhs: Conversation, rhs: Conversation) -> Bool {
        lhs.id == rhs.id &&
        lhs.peer == rhs.peer &&
        lhs.messages == rhs.messages &&
        lhs.unreadCount == rhs.unreadCount &&
        lhs.isTyping == rhs.isTyping &&
        lhs.group == rhs.group
    }
}

// MARK: - Wire Protocol
// Framing: [4-byte big-endian UInt32 length][JSON-encoded WireEnvelope]
// v1.2 also uses binary frames for file chunks: payload starts with 0x01 (see FileChunkFrame).

struct WireEnvelope: Codable, Sendable {
    let type: MessageType
    let senderId: String
    let senderName: String
    let payload: Data           // JSON of the specific payload type below

    enum MessageType: Int, Codable, Sendable {
        case hello          = 0  // payload → PreKeyBundlePayload
        case preKeyMessage  = 1  // payload → PreKeyMessagePayload
        case message        = 2  // payload → EncryptedMessagePayload
        case ack            = 3  // payload → AckPayload
        case typing         = 4  // payload → TypingPayload
        case ping           = 7  // payload → empty JSON object (keep-alive)
    }

    // MARK: Convenience

    /// Encode the envelope to JSON bytes for network transport
    func wireData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Build an envelope from a typed payload
    static func make<T: Encodable>(
        type: MessageType,
        senderId: String,
        senderName: String,
        payload: T
    ) throws -> WireEnvelope {
        let data = try JSONEncoder().encode(payload)
        return WireEnvelope(type: type, senderId: senderId, senderName: senderName, payload: data)
    }

    /// Decode the payload to a concrete type
    func decodePayload<T: Decodable>(_ t: T.Type) throws -> T {
        try JSONDecoder().decode(t, from: payload)
    }
}

/// Binary frame for one encrypted file chunk:
/// [0x01][16 B transferId][4 B index BE][4 B total BE][AES-GCM combined box]
enum FileChunkFrame {
    static let magic: UInt8 = 0x01
    static let headerLength = 1 + 16 + 4 + 4

    static func encode(transferId: UUID, index: UInt32, total: UInt32, box: Data) -> Data {
        var out = Data(capacity: headerLength + box.count)
        out.append(magic)
        var u = transferId.uuid
        withUnsafeBytes(of: &u) { out.append(contentsOf: $0) }
        var i = index.bigEndian
        withUnsafeBytes(of: &i) { out.append(contentsOf: $0) }
        var t = total.bigEndian
        withUnsafeBytes(of: &t) { out.append(contentsOf: $0) }
        out.append(box)
        return out
    }

    static func decode(_ data: Data) -> (transferId: UUID, index: UInt32, total: UInt32, box: Data)? {
        guard data.count > headerLength, data[data.startIndex] == magic else { return nil }
        let bytes = [UInt8](data.prefix(headerLength))
        let uuid = UUID(uuid: (bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
                               bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15], bytes[16]))
        let index = (UInt32(bytes[17]) << 24) | (UInt32(bytes[18]) << 16) | (UInt32(bytes[19]) << 8) | UInt32(bytes[20])
        let total = (UInt32(bytes[21]) << 24) | (UInt32(bytes[22]) << 16) | (UInt32(bytes[23]) << 8) | UInt32(bytes[24])
        let box = data.subdata(in: (data.startIndex + headerLength)..<data.endIndex)
        return (uuid, index, total, box)
    }

    /// Additional authenticated data binding a chunk to its transfer and position.
    static func aad(transferId: UUID, index: UInt32, total: UInt32) -> Data {
        var d = Data()
        var u = transferId.uuid
        withUnsafeBytes(of: &u) { d.append(contentsOf: $0) }
        var i = index.bigEndian
        withUnsafeBytes(of: &i) { d.append(contentsOf: $0) }
        var t = total.bigEndian
        withUnsafeBytes(of: &t) { d.append(contentsOf: $0) }
        return d
    }
}

// MARK: - Encrypted inner payloads (v1.2 control messages)

/// Control messages travel inside the Double Ratchet like chat messages.
/// Plain `ChatMessage` JSON is still used for chat content so v1.1 peers can read texts.
struct ControlMessage: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case sessionInit
        case delete
        case clear
        case profile
        case groupUpdate
        case groupLeave
        case groupInfoRequest
    }
    let kind: Kind
    var ids: [UUID]? = nil
    var groupId: String? = nil
    var name: String? = nil
    var avatar: Data? = nil
    var group: GroupInfo? = nil
    var version: Int? = nil
}

struct InnerEnvelope: Codable, Sendable {
    let v: Int
    let control: ControlMessage
}

// MARK: - Crypto Payload Types

struct PreKeyBundlePayload: Codable, Equatable, Sendable {
    let identityDHKey: Data           // 32 B – Curve25519 DH public
    let identitySigningKey: Data      // 32 B – Ed25519 signing public
    let signedPreKeyId: UInt32
    let signedPreKey: Data            // 32 B – Curve25519 DH public
    let signedPreKeySignature: Data   // 64 B – Ed25519 signature over signedPreKey
    let oneTimePreKeyId: UInt32?
    let oneTimePreKey: Data?          // 32 B – Curve25519 DH public (optional)
    // v1.2: whether the sender currently holds a ratchet session for the receiver.
    var hasSession: Bool? = nil
    var protocolVersion: Int? = nil
}

struct EncryptedMessagePayload: Codable, Equatable, Sendable {
    let messageId: UUID
    let ciphertext: Data              // AES-256-GCM ciphertext + 16-byte tag
    let nonce: Data                   // 12 B
    let ratchetPublicKey: Data        // 32 B – sender's current DH ratchet public key
    let previousChainLength: UInt32   // # messages sent under previous sending chain
    let messageNumber: UInt32         // message index in current sending chain
}

struct PreKeyMessagePayload: Codable, Equatable, Sendable {
    let oneTimePreKeyId: UInt32?
    let signedPreKeyId: UInt32
    let senderIdentityDHKey: Data     // 32 B
    let senderIdentitySigningKey: Data // 32 B
    let ephemeralKey: Data            // 32 B – X3DH ephemeral key
    let encryptedMessage: EncryptedMessagePayload
}

struct AckPayload: Codable, Sendable {
    let messageId: UUID
    let status: ChatMessage.Status
    var groupId: String? = nil
}

struct TypingPayload: Codable, Sendable {
    let isTyping: Bool
}

struct PingPayload: Codable, Sendable {
    var t: Double = Date().timeIntervalSince1970
}

// MARK: - Error Types

enum CryptoError: Error, LocalizedError, Sendable {
    case noSession
    case invalidPreKeyBundle
    case invalidSignature
    case decryptionFailed
    case invalidKey
    case sessionNotFound
    case preKeyNotFound
    case keyDerivationFailed

    var errorDescription: String? {
        switch self {
        case .noSession:            return "No encryption session established"
        case .invalidPreKeyBundle:  return "Invalid pre-key bundle"
        case .invalidSignature:     return "Pre-key signature verification failed"
        case .decryptionFailed:     return "Message decryption failed"
        case .invalidKey:           return "Invalid cryptographic key"
        case .sessionNotFound:      return "Session not found for peer"
        case .preKeyNotFound:       return "Pre-key not found"
        case .keyDerivationFailed:  return "Key derivation failed"
        }
    }
}

enum NetworkError: Error, LocalizedError, Sendable {
    case peerNotFound
    case notConnected
    case connectionFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .peerNotFound:      return "Peer not found on the network"
        case .notConnected:      return "Not connected to peer"
        case .connectionFailed:  return "Connection to peer failed"
        case .encodingFailed:    return "Message encoding failed"
        }
    }
}
