// CryptoEngine.swift
// SecureChat – High-level cryptographic API for ChatManager
//
// Wraps SignalCrypto primitives (X3DH, Double Ratchet) in a convenient
// ObservableObject that manages identity keys, pre-keys, and per-peer
// sessions.  Persistence uses UserDefaults (demo only – production apps
// should store key material in the Keychain).
//
// Dependencies: CryptoKit, Foundation only.  Target: iOS 16.5+

import CryptoKit
import Foundation
import Combine

/// High-level encryption engine used by the chat manager to establish
/// sessions and encrypt / decrypt messages.
final class CryptoEngine: ObservableObject {

    // MARK: - Concurrency Lock

    private let lock = NSRecursiveLock()

    // MARK: - Public identity

    /// Stable device identifier (UUID string).
    let localDeviceId: String

    /// Our Curve25519 key-agreement public key (32 bytes) for identity.
    var identityDHPublicKeyData: Data { identityKeyPair.dhPublicKeyData }

    /// Our Ed25519 signing public key (32 bytes) for identity.
    var identitySigningPublicKeyData: Data { identityKeyPair.signingPublicKeyData }

    // MARK: - Internal key material

    private var identityKeyPair: IdentityKeyPair
    private var signedPreKey: SignedPreKey
    private var oneTimePreKeys: [UInt32: OneTimePreKey]      // keyed by OPK id

    /// Active Double Ratchet sessions keyed by peer device id.
    private var sessions: [String: DoubleRatchetSession] = [:]

    /// Tracks which sessions are still in the "pre-key" state (initiator side,
    /// before the first response from the peer).
    private var preKeySessions: Set<String> = []

    /// The ephemeral public key used during X3DH for each initiator session,
    /// needed to construct the first `PreKeyMessagePayload`.
    private var ephemeralKeys: [String: Data] = [:]

    /// The signed-pre-key id we selected for each initiator session.
    private var usedSignedPreKeyIds: [String: UInt32] = [:]

    /// The one-time pre-key id we selected for each initiator session (if any).
    private var usedOneTimePreKeyIds: [String: UInt32?] = [:]

    // MARK: - UserDefaults keys

    private enum UDKey {
        static let identityDH          = "sc.identity.dh"
        static let identitySigning     = "sc.identity.signing"
        static let signedPreKey         = "sc.signedPreKey"
        static let oneTimePreKeys       = "sc.oneTimePreKeys"
        static let sessions             = "sc.sessions"
        static let preKeySessions       = "sc.preKeySessions"
        static let ephemeralKeys        = "sc.ephemeralKeys"
        static let usedSPKIds           = "sc.usedSPKIds"
        static let usedOTPKIds          = "sc.usedOTPKIds"
    }

    // MARK: - Init

    /// Create or restore a `CryptoEngine` for the given device id.
    ///
    /// Loads existing keys from UserDefaults if present; otherwise generates
    /// a fresh identity key pair, one signed pre-key, and 10 one-time pre-keys.
    init(deviceId: String) {
        self.localDeviceId = deviceId

        let defaults = UserDefaults.standard

        // --- Identity key pair ---
        if let dhData = defaults.data(forKey: UDKey.identityDH),
           let sigData = defaults.data(forKey: UDKey.identitySigning) {
            self.identityKeyPair = IdentityKeyPair(
                dhPrivateKeyData: dhData,
                signingPrivateKeyData: sigData
            )
        } else {
            self.identityKeyPair = IdentityKeyPair()
            defaults.set(identityKeyPair.dhPrivateKey.rawRepresentation, forKey: UDKey.identityDH)
            defaults.set(identityKeyPair.signingPrivateKey.rawRepresentation, forKey: UDKey.identitySigning)
        }

        // --- Signed pre-key ---
        if let spkData = defaults.data(forKey: UDKey.signedPreKey),
           let spk = try? JSONDecoder().decode(SignedPreKey.self, from: spkData) {
            self.signedPreKey = spk
        } else {
            // Generate fresh signed pre-key (id = 1 for first generation)
            self.signedPreKey = try! SignedPreKey(id: 1, signingKey: identityKeyPair.signingPrivateKey)
            let encoded = try! JSONEncoder().encode(self.signedPreKey)
            defaults.set(encoded, forKey: UDKey.signedPreKey)
        }

        // --- One-time pre-keys ---
        if let otpkData = defaults.data(forKey: UDKey.oneTimePreKeys),
           let otpks = try? JSONDecoder().decode([UInt32: OneTimePreKey].self, from: otpkData) {
            self.oneTimePreKeys = otpks
        } else {
            var keys = [UInt32: OneTimePreKey]()
            for i: UInt32 in 1...10 {
                keys[i] = OneTimePreKey(id: i)
            }
            self.oneTimePreKeys = keys
            Self.saveOneTimePreKeys(keys)
        }

        // --- Sessions ---
        if let sessData = defaults.data(forKey: UDKey.sessions),
           let sess = try? JSONDecoder().decode([String: DoubleRatchetSession].self, from: sessData) {
            self.sessions = sess
        }

        // --- Pre-key session tracking ---
        if let pkData = defaults.data(forKey: UDKey.preKeySessions),
           let pk = try? JSONDecoder().decode(Set<String>.self, from: pkData) {
            self.preKeySessions = pk
        }

        // --- Ephemeral keys ---
        if let ekData = defaults.data(forKey: UDKey.ephemeralKeys),
           let ek = try? JSONDecoder().decode([String: Data].self, from: ekData) {
            self.ephemeralKeys = ek
        }

        // --- Used pre-key ids ---
        if let spkIds = defaults.data(forKey: UDKey.usedSPKIds),
           let ids = try? JSONDecoder().decode([String: UInt32].self, from: spkIds) {
            self.usedSignedPreKeyIds = ids
        }
        if let otpkIds = defaults.data(forKey: UDKey.usedOTPKIds),
           let ids = try? JSONDecoder().decode([String: UInt32?].self, from: otpkIds) {
            self.usedOneTimePreKeyIds = ids
        }
    }

    // MARK: - Pre-Key Bundle

    /// Build a `PreKeyBundlePayload` that can be sent to peers so they can
    /// initiate an X3DH session with us.
    func generatePreKeyBundle() -> PreKeyBundlePayload {
        lock.lock()
        defer { lock.unlock() }

        // v1.2: bundles no longer advertise one-time pre-keys. With automatic
        // reconnects and group chats several peers could race for the same
        // OPK, and a consumed OPK makes the X3DH handshake fail permanently.
        // The signed pre-key alone still gives an authenticated X3DH (3-DH).
        // Incoming pre-key messages that reference an existing OPK are still
        // accepted for compatibility with v1.1 peers.
        return PreKeyBundlePayload(
            identityDHKey: identityKeyPair.dhPublicKeyData,
            identitySigningKey: identityKeyPair.signingPublicKeyData,
            signedPreKeyId: signedPreKey.id,
            signedPreKey: signedPreKey.publicKeyData,
            signedPreKeySignature: signedPreKey.signature,
            oneTimePreKeyId: nil,
            oneTimePreKey: nil
        )
    }

    // MARK: - Session reset

    /// Forget any ratchet state for a peer (used when sessions get out of sync).
    func resetSession(for peerId: String) {
        lock.lock()
        defer { lock.unlock() }
        sessions.removeValue(forKey: peerId)
        preKeySessions.remove(peerId)
        ephemeralKeys.removeValue(forKey: peerId)
        usedSignedPreKeyIds.removeValue(forKey: peerId)
        usedOneTimePreKeyIds.removeValue(forKey: peerId)
        saveSessions()
    }

    // MARK: - Session establishment (initiator)

    /// Process a received pre-key bundle from a peer and establish the
    /// initiator side of the X3DH key agreement plus a fresh Double Ratchet
    /// session.
    func processReceivedBundle(_ bundle: PreKeyBundlePayload, from peerId: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let result = try X3DH.initiateKeyAgreement(
            ourIdentity: identityKeyPair,
            theirIdentityDHKey: bundle.identityDHKey,
            theirSigningKey: bundle.identitySigningKey,
            theirSignedPreKey: bundle.signedPreKey,
            theirSignedPreKeySignature: bundle.signedPreKeySignature,
            theirOneTimePreKey: bundle.oneTimePreKey
        )

        let session = try DoubleRatchetSession(
            asInitiator: result.sharedSecret,
            theirSignedPreKey: bundle.signedPreKey
        )

        sessions[peerId] = session
        preKeySessions.insert(peerId)
        ephemeralKeys[peerId] = result.ephemeralPublicKey
        usedSignedPreKeyIds[peerId] = bundle.signedPreKeyId
        usedOneTimePreKeyIds[peerId] = bundle.oneTimePreKeyId

        saveSessions()
    }

    // MARK: - Session query

    /// Whether we have an established Double Ratchet session with the given peer.
    func hasSession(for peerId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessions[peerId] != nil
    }

    // MARK: - Encrypt

    /// Encrypt plaintext for a peer.
    ///
    /// - If this is the **first message** (session created via
    ///   `processReceivedBundle`), the returned payload is a JSON-encoded
    ///   `PreKeyMessagePayload` and `isPreKey` is `true`.
    /// - For subsequent messages the payload is a JSON-encoded
    ///   `EncryptedMessagePayload` and `isPreKey` is `false`.
    func encrypt(_ plaintext: Data, for peerId: String) throws -> (isPreKey: Bool, payload: Data) {
        lock.lock()
        defer { lock.unlock() }

        guard var session = sessions[peerId] else {
            throw CryptoError.noSession
        }

        let encrypted = try session.encrypt(plaintext: plaintext)

        // Persist mutated session
        sessions[peerId] = session

        let isPreKey = preKeySessions.contains(peerId)

        if isPreKey {
            // Build the pre-key message wrapping the encrypted payload
            let preKeyMsg = PreKeyMessagePayload(
                oneTimePreKeyId: usedOneTimePreKeyIds[peerId] ?? nil,
                signedPreKeyId: usedSignedPreKeyIds[peerId] ?? signedPreKey.id,
                senderIdentityDHKey: identityKeyPair.dhPublicKeyData,
                senderIdentitySigningKey: identityKeyPair.signingPublicKeyData,
                ephemeralKey: ephemeralKeys[peerId] ?? Data(),
                encryptedMessage: encrypted
            )

            // Mark session as no longer pre-key after first message
            preKeySessions.remove(peerId)
            ephemeralKeys.removeValue(forKey: peerId)
            usedSignedPreKeyIds.removeValue(forKey: peerId)
            usedOneTimePreKeyIds.removeValue(forKey: peerId)

            let payload = try JSONEncoder().encode(preKeyMsg)
            saveSessions()
            return (isPreKey: true, payload: payload)
        } else {
            let payload = try JSONEncoder().encode(encrypted)
            saveSessions()
            return (isPreKey: false, payload: payload)
        }
    }

    // MARK: - Decrypt pre-key message

    /// Decrypt an initial pre-key message from a peer, establishing the
    /// responder side of the session.
    func decryptPreKeyMessage(_ message: PreKeyMessagePayload, from peerId: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        // Look up our signed pre-key by id
        guard signedPreKey.id == message.signedPreKeyId else {
            throw CryptoError.preKeyNotFound
        }

        // Look up (and consume) the one-time pre-key, if any
        var otpkPrivate: Curve25519.KeyAgreement.PrivateKey? = nil
        if let otpkId = message.oneTimePreKeyId {
            guard let otpk = oneTimePreKeys[otpkId] else {
                throw CryptoError.preKeyNotFound
            }
            otpkPrivate = otpk.keyPair
            oneTimePreKeys.removeValue(forKey: otpkId)
            Self.saveOneTimePreKeys(oneTimePreKeys)
        }

        // Perform responder-side X3DH
        let result = try X3DH.respondToKeyAgreement(
            ourIdentity: identityKeyPair,
            ourSignedPreKey: signedPreKey.keyPair,
            ourOneTimePreKey: otpkPrivate,
            theirIdentityDHKey: message.senderIdentityDHKey,
            theirEphemeralKey: message.ephemeralKey
        )

        // Initialize Double Ratchet as responder
        var session = DoubleRatchetSession(
            asResponder: result.sharedSecret,
            ourSignedPreKey: signedPreKey.keyPair
        )

        // Decrypt the embedded encrypted message
        let plaintext = try session.decrypt(message: message.encryptedMessage)

        // Store session
        sessions[peerId] = session
        saveSessions()

        return plaintext
    }

    // MARK: - Decrypt regular message

    /// Decrypt a regular Double Ratchet message from an established session.
    func decryptMessage(_ message: EncryptedMessagePayload, from peerId: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard var session = sessions[peerId] else {
            throw CryptoError.sessionNotFound
        }

        let plaintext = try session.decrypt(message: message)

        sessions[peerId] = session
        saveSessions()

        return plaintext
    }

    // MARK: - Persistence helpers

    /// Save all mutable session state to UserDefaults.
    private func saveSessions() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(sessions) {
            defaults.set(data, forKey: UDKey.sessions)
        }
        if let data = try? JSONEncoder().encode(preKeySessions) {
            defaults.set(data, forKey: UDKey.preKeySessions)
        }
        if let data = try? JSONEncoder().encode(ephemeralKeys) {
            defaults.set(data, forKey: UDKey.ephemeralKeys)
        }
        if let data = try? JSONEncoder().encode(usedSignedPreKeyIds) {
            defaults.set(data, forKey: UDKey.usedSPKIds)
        }
        if let data = try? JSONEncoder().encode(usedOneTimePreKeyIds) {
            defaults.set(data, forKey: UDKey.usedOTPKIds)
        }
    }

    /// Save one-time pre-keys separately (they change when consumed).
    private static func saveOneTimePreKeys(_ keys: [UInt32: OneTimePreKey]) {
        if let data = try? JSONEncoder().encode(keys) {
            UserDefaults.standard.set(data, forKey: UDKey.oneTimePreKeys)
        }
    }
}
