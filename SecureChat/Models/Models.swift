// Models.swift
// SecureChat – LAN End-to-End Encrypted Messenger
// Shared data types used across Crypto, Network, and UI layers

import Foundation

// MARK: - Peer

/// A discovered peer on the local network
struct Peer: Identifiable, Codable, Hashable, Sendable {
    let id: String                    // Unique device UUID
    var displayName: String
    var isOnline: Bool = false
    var lastSeen: Date = Date()

    // Crypto identity (populated after hello exchange)
    var identityDHKeyData: Data?      // Curve25519 DH public key
    var identitySigningKeyData: Data? // Ed25519 signing public key

    var hasIdentity: Bool {
        identityDHKeyData != nil && identitySigningKeyData != nil
    }

    /// Short hex fingerprint for out-of-band identity verification
    var fingerprint: String {
        guard let key = identityDHKeyData else { return "Unknown" }
        return key.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    static func == (lhs: Peer, rhs: Peer) -> Bool { lhs.id == rhs.id }
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
    let attachment: Attachment?

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
        case file  = 2
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
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(UUID.self, forKey: .id)
        senderId    = try c.decode(String.self, forKey: .senderId)
        recipientId = try c.decode(String.self, forKey: .recipientId)
        text        = try c.decode(String.self, forKey: .text)
        timestamp   = try c.decode(Date.self, forKey: .timestamp)
        status      = try c.decode(Status.self, forKey: .status)
        contentType = try c.decodeIfPresent(ContentType.self, forKey: .contentType) ?? .text
        attachment  = try c.decodeIfPresent(Attachment.self, forKey: .attachment)
    }
}

// MARK: - Attachment

struct Attachment: Codable, Equatable, Sendable {
    let filename: String
    let mimeType: String
    let data: Data             // Binary content (compressed image or file bytes)
    let fileSize: Int64

    // Image-specific (nil for files)
    let width: Int?
    let height: Int?
    let thumbnailData: Data?   // Small JPEG preview (~100px)

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

// MARK: - Conversation

struct Conversation: Identifiable, Equatable, Sendable {
    let id: String                // == peer.id
    var peer: Peer
    var messages: [ChatMessage] = []
    var unreadCount: Int = 0
    var isTyping: Bool = false
    var preKeyBundle: PreKeyBundlePayload?

    var lastMessage: ChatMessage? { messages.last }

    static func == (lhs: Conversation, rhs: Conversation) -> Bool {
        lhs.id == rhs.id &&
        lhs.peer == rhs.peer &&
        lhs.messages == rhs.messages &&
        lhs.unreadCount == rhs.unreadCount &&
        lhs.isTyping == rhs.isTyping
    }
}

// MARK: - Wire Protocol
// Framing: [4-byte big-endian UInt32 length][JSON-encoded WireEnvelope]

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

// MARK: - Crypto Payload Types

struct PreKeyBundlePayload: Codable, Equatable, Sendable {
    let identityDHKey: Data           // 32 B – Curve25519 DH public
    let identitySigningKey: Data      // 32 B – Ed25519 signing public
    let signedPreKeyId: UInt32
    let signedPreKey: Data            // 32 B – Curve25519 DH public
    let signedPreKeySignature: Data   // 64 B – Ed25519 signature over signedPreKey
    let oneTimePreKeyId: UInt32?
    let oneTimePreKey: Data?          // 32 B – Curve25519 DH public (optional)
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
}

struct TypingPayload: Codable, Sendable {
    let isTyping: Bool
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
