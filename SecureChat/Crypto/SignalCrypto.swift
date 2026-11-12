// SignalCrypto.swift
// SecureChat – Signal Protocol primitives using Apple CryptoKit
//
// Implements:
//   • IdentityKeyPair   – long-lived DH + signing keys
//   • SignedPreKey       – medium-term DH key signed by identity
//   • OneTimePreKey      – one-shot DH key
//   • X3DH               – Extended Triple Diffie-Hellman key agreement
//   • DoubleRatchetSession – Double Ratchet Algorithm (symmetric + DH ratchets)
//
// Dependencies: CryptoKit, Foundation only.  Target: iOS 16.5+

import CryptoKit
import Foundation

// MARK: - IdentityKeyPair

/// Long-lived identity key pair containing both a Curve25519 key-agreement key
/// (used for X3DH DH operations) and an Ed25519 signing key (used to sign
/// pre-keys and for identity verification).
struct IdentityKeyPair: Codable, Sendable {

    // MARK: Internal storage (raw representations for Codable)

    private let dhPrivateKeyData: Data
    private let signingPrivateKeyData: Data

    // MARK: Computed CryptoKit keys

    var dhPrivateKey: Curve25519.KeyAgreement.PrivateKey {
        try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: dhPrivateKeyData)
    }

    var signingPrivateKey: Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivateKeyData)
    }

    var dhPublicKey: Curve25519.KeyAgreement.PublicKey { dhPrivateKey.publicKey }
    var signingPublicKey: Curve25519.Signing.PublicKey { signingPrivateKey.publicKey }

    var dhPublicKeyData: Data { dhPublicKey.rawRepresentation }
    var signingPublicKeyData: Data { signingPublicKey.rawRepresentation }

    // MARK: Init

    /// Generate a fresh identity key pair.
    init() {
        let dh = Curve25519.KeyAgreement.PrivateKey()
        let signing = Curve25519.Signing.PrivateKey()
        self.dhPrivateKeyData = dh.rawRepresentation
        self.signingPrivateKeyData = signing.rawRepresentation
    }

    /// Restore from persisted raw representations.
    init(dhPrivateKeyData: Data, signingPrivateKeyData: Data) {
        self.dhPrivateKeyData = dhPrivateKeyData
        self.signingPrivateKeyData = signingPrivateKeyData
    }
}

// MARK: - SignedPreKey

/// Medium-term pre-key whose public component is signed by the identity
/// signing key so peers can verify authenticity.
struct SignedPreKey: Codable, Sendable {
    let id: UInt32
    private let keyPairData: Data   // raw representation of the private key
    let signature: Data             // Ed25519 signature of the DH public key bytes

    var keyPair: Curve25519.KeyAgreement.PrivateKey {
        try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyPairData)
    }

    var publicKeyData: Data { keyPair.publicKey.rawRepresentation }

    /// Generate a new signed pre-key.
    /// - Parameters:
    ///   - id: Monotonically-increasing key identifier.
    ///   - signingKey: Identity Ed25519 private key used to produce the signature.
    init(id: UInt32, signingKey: Curve25519.Signing.PrivateKey) throws {
        self.id = id
        let kp = Curve25519.KeyAgreement.PrivateKey()
        self.keyPairData = kp.rawRepresentation
        self.signature = try signingKey.signature(for: kp.publicKey.rawRepresentation)
    }

    /// Restore from persisted data.
    init(id: UInt32, keyPairData: Data, signature: Data) {
        self.id = id
        self.keyPairData = keyPairData
        self.signature = signature
    }
}

// MARK: - OneTimePreKey

/// Single-use pre-key consumed during X3DH to provide forward secrecy even if
/// the signed pre-key is later compromised.
struct OneTimePreKey: Codable, Sendable {
    let id: UInt32
    private let keyPairData: Data

    var keyPair: Curve25519.KeyAgreement.PrivateKey {
        try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyPairData)
    }

    var publicKeyData: Data { keyPair.publicKey.rawRepresentation }

    init(id: UInt32) {
        self.id = id
        self.keyPairData = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
    }

    init(id: UInt32, keyPairData: Data) {
        self.id = id
        self.keyPairData = keyPairData
    }
}

// MARK: - X3DH (Extended Triple Diffie-Hellman)

/// Result of the initiator side of X3DH, providing everything needed to
/// construct a `PreKeyMessagePayload` and initialize a `DoubleRatchetSession`.
struct X3DHInitiatorResult: Sendable {
    let sharedSecret: Data              // 32 bytes derived via HKDF
    let ephemeralPublicKey: Data        // 32 bytes
    let associatedData: Data            // initiator IK‖responder IK
}

/// Result of the responder side of X3DH.
struct X3DHResponderResult: Sendable {
    let sharedSecret: Data              // 32 bytes
    let associatedData: Data            // initiator IK‖responder IK
}

enum X3DH {

    /// 32 zero bytes used as HKDF salt throughout the X3DH derivation.
    private static let zeroSalt = Data(count: 32)

    // MARK: Initiator

    /// Perform the initiator side of the X3DH key agreement.
    ///
    /// - Parameters:
    ///   - ourIdentity: Our long-lived identity key pair.
    ///   - theirIdentityDHKey: Peer's Curve25519 DH public key.
    ///   - theirSigningKey: Peer's Ed25519 public key (to verify pre-key signature).
    ///   - theirSignedPreKey: Peer's signed pre-key public key.
    ///   - theirSignedPreKeySignature: Ed25519 signature over `theirSignedPreKey`.
    ///   - theirOneTimePreKey: Optional one-time pre-key public key.
    /// - Returns: `X3DHInitiatorResult` containing the shared secret and metadata.
    static func initiateKeyAgreement(
        ourIdentity: IdentityKeyPair,
        theirIdentityDHKey: Data,
        theirSigningKey: Data,
        theirSignedPreKey: Data,
        theirSignedPreKeySignature: Data,
        theirOneTimePreKey: Data?
    ) throws -> X3DHInitiatorResult {

        // 1. Verify signed pre-key signature
        let signingPub = try Curve25519.Signing.PublicKey(rawRepresentation: theirSigningKey)
        guard signingPub.isValidSignature(theirSignedPreKeySignature, for: theirSignedPreKey) else {
            throw CryptoError.invalidSignature
        }

        // 2. Parse peer DH public keys
        let theirIdentityDH = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirIdentityDHKey)
        let theirSPK = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirSignedPreKey)

        // 3. Generate ephemeral key pair
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()

        // 4. Compute DH shared secrets
        let dh1 = try ourIdentity.dhPrivateKey.sharedSecretFromKeyAgreement(with: theirSPK)
        let dh2 = try ephemeral.sharedSecretFromKeyAgreement(with: theirIdentityDH)
        let dh3 = try ephemeral.sharedSecretFromKeyAgreement(with: theirSPK)

        var dhConcat = Data()
        dh1.withUnsafeBytes { dhConcat.append(contentsOf: $0) }
        dh2.withUnsafeBytes { dhConcat.append(contentsOf: $0) }
        dh3.withUnsafeBytes { dhConcat.append(contentsOf: $0) }

        if let otpkData = theirOneTimePreKey {
            let theirOTPK = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: otpkData)
            let dh4 = try ephemeral.sharedSecretFromKeyAgreement(with: theirOTPK)
            dh4.withUnsafeBytes { dhConcat.append(contentsOf: $0) }
        }

        // 5. HKDF derivation
        let sharedSecret = deriveSecret(ikm: dhConcat, salt: zeroSalt, info: "X3DH", outputByteCount: 32)

        // 6. Associated data = initiator identity DH key ‖ responder identity DH key
        var ad = Data()
        ad.append(ourIdentity.dhPublicKeyData)
        ad.append(theirIdentityDHKey)

        return X3DHInitiatorResult(
            sharedSecret: sharedSecret,
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            associatedData: ad
        )
    }

    // MARK: Responder

    /// Perform the responder side of the X3DH key agreement.
    ///
    /// - Parameters:
    ///   - ourIdentity: Our long-lived identity key pair.
    ///   - ourSignedPreKey: The signed pre-key that the initiator chose.
    ///   - ourOneTimePreKey: The optional one-time pre-key the initiator chose.
    ///   - theirIdentityDHKey: Initiator's Curve25519 DH public key.
    ///   - theirEphemeralKey: Initiator's ephemeral DH public key.
    static func respondToKeyAgreement(
        ourIdentity: IdentityKeyPair,
        ourSignedPreKey: Curve25519.KeyAgreement.PrivateKey,
        ourOneTimePreKey: Curve25519.KeyAgreement.PrivateKey?,
        theirIdentityDHKey: Data,
        theirEphemeralKey: Data
    ) throws -> X3DHResponderResult {

        let theirIdentityDH = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirIdentityDHKey)
        let theirEph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirEphemeralKey)

        // DH computations – mirror of the initiator, with our/their reversed
        let dh1 = try ourSignedPreKey.sharedSecretFromKeyAgreement(with: theirIdentityDH)
        let dh2 = try ourIdentity.dhPrivateKey.sharedSecretFromKeyAgreement(with: theirEph)
        let dh3 = try ourSignedPreKey.sharedSecretFromKeyAgreement(with: theirEph)

        var dhConcat = Data()
        dh1.withUnsafeBytes { dhConcat.append(contentsOf: $0) }
        dh2.withUnsafeBytes { dhConcat.append(contentsOf: $0) }
        dh3.withUnsafeBytes { dhConcat.append(contentsOf: $0) }

        if let otpk = ourOneTimePreKey {
            let dh4 = try otpk.sharedSecretFromKeyAgreement(with: theirEph)
            dh4.withUnsafeBytes { dhConcat.append(contentsOf: $0) }
        }

        let sharedSecret = deriveSecret(ikm: dhConcat, salt: zeroSalt, info: "X3DH", outputByteCount: 32)

        // AD = initiator identity key ‖ responder identity key
        var ad = Data()
        ad.append(theirIdentityDHKey)
        ad.append(ourIdentity.dhPublicKeyData)

        return X3DHResponderResult(sharedSecret: sharedSecret, associatedData: ad)
    }

    // MARK: Internal HKDF helper

    /// Derive keying material using HKDF-SHA256.
    fileprivate static func deriveSecret(
        ikm: Data,
        salt: Data,
        info: String,
        outputByteCount: Int
    ) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: outputByteCount
        )
        return key.withUnsafeBytes { Data($0) }
    }
}

// MARK: - DoubleRatchetSession

/// Full Double Ratchet session state implementing the Symmetric-key ratchet and
/// Diffie-Hellman ratchet as described in the Signal specification.
///
/// Fully `Codable` so the entire session state can be serialized to disk for
/// persistence across app launches.
struct DoubleRatchetSession: Codable, Sendable {

    // MARK: State

    /// Our current ratchet DH key pair (private key raw bytes, nil until first ratchet step).
    private var dhSendingKeyPairData: Data?

    /// Their current ratchet DH public key (raw bytes).
    private var dhReceivingKeyData: Data?

    /// Root key – 32 bytes, updated with every DH ratchet step.
    private var rootKey: Data

    /// Current sending chain key – 32 bytes, advanced for every sent message.
    private var sendingChainKey: Data?

    /// Current receiving chain key – 32 bytes, advanced for every received message.
    private var receivingChainKey: Data?

    /// Number of messages sent in the current sending chain.
    private(set) var sendMessageNumber: UInt32 = 0

    /// Number of messages received in the current receiving chain.
    private(set) var recvMessageNumber: UInt32 = 0

    /// Length of the previous sending chain, sent in message headers so the
    /// receiver can store skipped keys from the old chain.
    private(set) var previousSendingChainLength: UInt32 = 0

    /// Skipped message keys indexed by `"<dhPubKeyHex>:<messageNumber>"`.
    /// Capped at `maxSkippedKeys` entries to prevent denial-of-service via
    /// excessively-gapped message numbers.
    private var skippedMessageKeys: [String: Data] = [:]

    /// Maximum number of skipped message keys we will store.
    private static let maxSkippedKeys = 100

    // MARK: Convenience accessors

    var dhSendingKeyPair: Curve25519.KeyAgreement.PrivateKey? {
        guard let data = dhSendingKeyPairData else { return nil }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    var dhSendingPublicKeyData: Data? {
        dhSendingKeyPair?.publicKey.rawRepresentation
    }

    var dhReceivingKey: Curve25519.KeyAgreement.PublicKey? {
        guard let data = dhReceivingKeyData else { return nil }
        return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
    }

    // MARK: Initialization – Initiator

    /// Initialize a session as the **initiator** (Alice).
    ///
    /// The initiator's first `dhReceivingKey` is the responder's signed pre-key
    /// (because the responder will use that same key pair for their first
    /// sending chain). Immediately perform a DH ratchet step to create the
    /// first sending chain.
    ///
    /// - Parameters:
    ///   - sharedSecret: The 32-byte shared secret from X3DH.
    ///   - theirSignedPreKey: Responder's signed pre-key public key bytes.
    init(asInitiator sharedSecret: Data, theirSignedPreKey: Data) throws {
        self.rootKey = sharedSecret
        self.dhReceivingKeyData = theirSignedPreKey

        // Perform the first DH ratchet step to obtain a sending chain
        let newDH = Curve25519.KeyAgreement.PrivateKey()
        self.dhSendingKeyPairData = newDH.rawRepresentation

        let theirKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirSignedPreKey)
        let dhOutput = try newDH.sharedSecretFromKeyAgreement(with: theirKey)
        var dhData = Data()
        dhOutput.withUnsafeBytes { dhData.append(contentsOf: $0) }

        let derived = rootKDF(rootKey: self.rootKey, dhOutput: dhData)
        self.rootKey = derived.newRootKey
        self.sendingChainKey = derived.newChainKey
    }

    // MARK: Initialization – Responder

    /// Initialize a session as the **responder** (Bob).
    ///
    /// The responder's `dhSendingKeyPair` is their signed pre-key (since the
    /// initiator used that public key as their first `dhReceivingKey`).
    ///
    /// - Parameters:
    ///   - sharedSecret: The 32-byte shared secret from X3DH.
    ///   - ourSignedPreKey: Our signed pre-key private key.
    init(asResponder sharedSecret: Data, ourSignedPreKey: Curve25519.KeyAgreement.PrivateKey) {
        self.rootKey = sharedSecret
        self.dhSendingKeyPairData = ourSignedPreKey.rawRepresentation
        // dhReceivingKey and chains are nil until the first message arrives
    }

    // MARK: Encrypt

    /// Encrypt plaintext data producing an `EncryptedMessagePayload`.
    ///
    /// Advances the sending chain by one step, derives a message key, then
    /// encrypts with AES-256-GCM.
    mutating func encrypt(plaintext: Data) throws -> EncryptedMessagePayload {
        guard let chainKey = sendingChainKey,
              let sendingPubData = dhSendingPublicKeyData else {
            throw CryptoError.noSession
        }

        // Advance sending chain
        let (messageKey, nextChainKey) = symmetricChainStep(chainKey: chainKey)
        self.sendingChainKey = nextChainKey

        // Derive encryption key (32 B) + nonce (12 B)
        let (encKey, nonce) = deriveMessageEncryptionMaterial(from: messageKey)

        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: encKey),
            nonce: try AES.GCM.Nonce(data: nonce)
        )

        // combined = nonce ‖ ciphertext ‖ tag  – we store ciphertext+tag only
        let ciphertextAndTag = sealedBox.ciphertext + sealedBox.tag

        let messageNumber = sendMessageNumber
        sendMessageNumber += 1

        return EncryptedMessagePayload(
            messageId: UUID(),
            ciphertext: ciphertextAndTag,
            nonce: nonce,
            ratchetPublicKey: sendingPubData,
            previousChainLength: previousSendingChainLength,
            messageNumber: messageNumber
        )
    }

    // MARK: Decrypt

    /// Decrypt an `EncryptedMessagePayload` received from the peer.
    ///
    /// Handles:
    /// 1. Retrieval from skipped message keys.
    /// 2. DH ratchet step if the sender's ratchet key has changed.
    /// 3. Symmetric ratchet to reach the correct message number.
    mutating func decrypt(message: EncryptedMessagePayload) throws -> Data {

        // 1. Try skipped message keys
        if let plaintext = try decryptFromSkipped(message: message) {
            return plaintext
        }

        // 2. DH ratchet if the sender's ratchet public key differs
        if dhReceivingKeyData == nil || message.ratchetPublicKey != dhReceivingKeyData {
            try performDHRatchet(
                newReceiverKey: message.ratchetPublicKey,
                previousChainLength: message.previousChainLength
            )
        }

        // 3. Advance receiving chain to the message number
        try skipReceivedKeys(until: message.messageNumber)

        guard let chainKey = receivingChainKey else {
            throw CryptoError.decryptionFailed
        }

        let (messageKey, nextChainKey) = symmetricChainStep(chainKey: chainKey)
        self.receivingChainKey = nextChainKey
        self.recvMessageNumber += 1

        return try decryptWithMessageKey(message: message, messageKey: messageKey)
    }

    // MARK: - Private helpers

    // MARK: Root KDF

    /// Perform a root-chain KDF step: HKDF with the DH output and current root
    /// key, producing a new root key and a new chain key.
    private func rootKDF(rootKey: Data, dhOutput: Data) -> (newRootKey: Data, newChainKey: Data) {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: dhOutput),
            salt: rootKey,
            info: Data("DoubleRatchet".utf8),
            outputByteCount: 64
        )
        let bytes = derived.withUnsafeBytes { Data($0) }
        return (bytes.prefix(32), bytes.suffix(32))
    }

    // MARK: Symmetric chain step

    /// Advance a symmetric chain key by one step.
    /// Returns `(messageKey, nextChainKey)`.
    ///
    /// - messageKey  = HMAC-SHA256(chainKey, 0x01)
    /// - nextChainKey = HMAC-SHA256(chainKey, 0x02)
    private func symmetricChainStep(chainKey: Data) -> (messageKey: Data, nextChainKey: Data) {
        let hmacKey = SymmetricKey(data: chainKey)
        let mk = Data(HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: hmacKey))
        let ck = Data(HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: hmacKey))
        return (mk, ck)
    }

    // MARK: Message key → AES key + nonce

    /// Derive a 32-byte AES-256-GCM encryption key and a 12-byte nonce from a
    /// 32-byte message key using HKDF-SHA256.
    private func deriveMessageEncryptionMaterial(from messageKey: Data) -> (key: Data, nonce: Data) {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: messageKey),
            salt: Data(count: 32),
            info: Data("MessageKeys".utf8),
            outputByteCount: 44  // 32 (key) + 12 (nonce)
        )
        let bytes = derived.withUnsafeBytes { Data($0) }
        return (bytes.prefix(32), bytes.suffix(12))
    }

    // MARK: DH Ratchet

    /// Perform a full DH ratchet step when we receive a new ratchet public key
    /// from the peer.
    private mutating func performDHRatchet(
        newReceiverKey: Data,
        previousChainLength: UInt32
    ) throws {
        // Store any skipped keys in the current receiving chain
        if receivingChainKey != nil {
            try skipReceivedKeys(until: previousChainLength)
        }

        // Save previous sending chain length
        self.previousSendingChainLength = sendMessageNumber
        self.sendMessageNumber = 0
        self.recvMessageNumber = 0

        // Update receiving key
        self.dhReceivingKeyData = newReceiverKey
        let theirNewKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: newReceiverKey)

        // Derive new receiving chain from current sending key pair + new receiver key
        if let sendKP = dhSendingKeyPair {
            let dhOut = try sendKP.sharedSecretFromKeyAgreement(with: theirNewKey)
            var dhData = Data()
            dhOut.withUnsafeBytes { dhData.append(contentsOf: $0) }
            let recv = rootKDF(rootKey: rootKey, dhOutput: dhData)
            self.rootKey = recv.newRootKey
            self.receivingChainKey = recv.newChainKey
        }

        // Generate new sending key pair and derive new sending chain
        let newDH = Curve25519.KeyAgreement.PrivateKey()
        self.dhSendingKeyPairData = newDH.rawRepresentation

        let dhOut2 = try newDH.sharedSecretFromKeyAgreement(with: theirNewKey)
        var dhData2 = Data()
        dhOut2.withUnsafeBytes { dhData2.append(contentsOf: $0) }
        let send = rootKDF(rootKey: rootKey, dhOutput: dhData2)
        self.rootKey = send.newRootKey
        self.sendingChainKey = send.newChainKey
    }

    // MARK: Skipped keys

    /// Advance the receiving chain, storing skipped message keys for
    /// out-of-order delivery.
    private mutating func skipReceivedKeys(until target: UInt32) throws {
        guard let recvKeyData = dhReceivingKeyData else { return }

        if target < recvMessageNumber {
            // We've already advanced past this; the key should be in skipped
            return
        }

        let toSkip = Int(target) - Int(recvMessageNumber)
        guard skippedMessageKeys.count + toSkip <= Self.maxSkippedKeys else {
            throw CryptoError.decryptionFailed // would exceed DoS limit
        }

        guard var chainKey = receivingChainKey else { return }

        let keyHex = recvKeyData.map { String(format: "%02x", $0) }.joined()

        for n in recvMessageNumber ..< target {
            let (mk, nextCK) = symmetricChainStep(chainKey: chainKey)
            skippedMessageKeys["\(keyHex):\(n)"] = mk
            chainKey = nextCK
        }
        self.receivingChainKey = chainKey
        self.recvMessageNumber = target
    }

    /// Attempt to decrypt using a previously-stored skipped message key.
    private mutating func decryptFromSkipped(message: EncryptedMessagePayload) throws -> Data? {
        let keyHex = message.ratchetPublicKey.map { String(format: "%02x", $0) }.joined()
        let index = "\(keyHex):\(message.messageNumber)"
        guard let mk = skippedMessageKeys[index] else { return nil }
        skippedMessageKeys.removeValue(forKey: index)
        return try decryptWithMessageKey(message: message, messageKey: mk)
    }

    // MARK: AES-GCM decrypt helper

    /// Decrypt ciphertext using a derived message key.
    private func decryptWithMessageKey(
        message: EncryptedMessagePayload,
        messageKey: Data
    ) throws -> Data {
        let (encKey, nonce) = deriveMessageEncryptionMaterial(from: messageKey)

        // ciphertext contains ciphertext + 16-byte GCM tag
        let ct = message.ciphertext
        guard ct.count >= 16 else { throw CryptoError.decryptionFailed }

        let ciphertextOnly = ct.prefix(ct.count - 16)
        let tag = ct.suffix(16)

        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertextOnly,
                tag: tag
            )
            return try AES.GCM.open(sealedBox, using: SymmetricKey(data: encKey))
        } catch {
            throw CryptoError.decryptionFailed
        }
    }
}
