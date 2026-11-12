// ChatManager.swift
// SecureChat – LAN End-to-End Encrypted Messenger
// Central coordinator binding Crypto, Network, Persistence, and UI

import Foundation
import Combine
import UIKit

@MainActor
final class ChatManager: ObservableObject {

    // MARK: - Published state

    @Published var conversations: [String: Conversation] = [:]
    @Published var sortedConversations: [Conversation] = []

    // MARK: - Dependencies

    let cryptoEngine: CryptoEngine
    let networkManager: NetworkManager
    let persistence: PersistenceManager
    let localDeviceId: String
    var displayName: String

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(deviceId: String, displayName: String, persistence: PersistenceManager) {
        self.localDeviceId = deviceId
        self.displayName = displayName
        self.persistence = persistence
        self.cryptoEngine = CryptoEngine(deviceId: deviceId)
        self.networkManager = NetworkManager()

        // Load persisted conversations
        self.conversations = persistence.loadConversations()
        rebuildSorted()

        // Keep sortedConversations in sync
        $conversations
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildSorted() }
            .store(in: &cancellables)

        // Wire network callbacks
        wireCallbacks()

        // Auto-start
        start(displayName: displayName)
    }

    // MARK: - Lifecycle

    func start(displayName: String) {
        self.displayName = displayName
        networkManager.start(deviceId: localDeviceId, displayName: displayName)
    }

    func stop() {
        networkManager.stop()
    }

    /// Update the display name and propagate to Bonjour advertisement
    func updateDisplayName(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        displayName = trimmed
        persistence.saveDisplayName(trimmed)
        networkManager.updateDisplayName(trimmed)
    }

    // MARK: - Network Callbacks

    private func wireCallbacks() {

        networkManager.onPeerFound = { [weak self] peerId, peerName in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if var conv = self.conversations[peerId] {
                    conv.peer.displayName = peerName
                    conv.peer.isOnline = true
                    conv.peer.lastSeen = Date()
                    self.conversations[peerId] = conv
                } else {
                    let peer = Peer(id: peerId, displayName: peerName, isOnline: true, lastSeen: Date())
                    self.conversations[peerId] = Conversation(id: peerId, peer: peer)
                }
                self.persist()
            }
        }

        networkManager.onPeerLost = { [weak self] peerId in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if var conv = self.conversations[peerId] {
                    conv.peer.isOnline = false
                    conv.peer.lastSeen = Date()
                    conv.isTyping = false
                    self.conversations[peerId] = conv
                    self.persist()
                }
            }
        }

        networkManager.onPeerDisconnected = { [weak self] peerId in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if var conv = self.conversations[peerId] {
                    conv.peer.isOnline = false
                    conv.peer.lastSeen = Date()
                    conv.isTyping = false
                    self.conversations[peerId] = conv
                    self.persist()
                }
            }
        }

        networkManager.onPeerConnected = { [weak self] peerId in
            guard let self = self else { return }
            self.sendHello(to: peerId)
        }

        networkManager.onDataReceived = { [weak self] data, peerId in
            guard let self = self else { return }
            self.handleReceivedData(data, from: peerId)
        }
    }

    // MARK: - Sending Hello (PreKeyBundle exchange)

    private func sendHello(to peerId: String) {
        do {
            let bundle = cryptoEngine.generatePreKeyBundle()
            let envelope = try WireEnvelope.make(
                type: .hello,
                senderId: localDeviceId,
                senderName: displayName,
                payload: bundle
            )
            let wireData = try envelope.wireData()
            networkManager.send(wireData, to: peerId)
        } catch {
            print("[ChatManager] Failed to send hello to \(peerId): \(error)")
        }
    }

    // MARK: - Receiving Data

    private func handleReceivedData(_ data: Data, from peerId: String) {
        do {
            let envelope = try JSONDecoder().decode(WireEnvelope.self, from: data)
            DispatchQueue.main.async {
                self.dispatch(envelope: envelope, from: peerId)
            }
        } catch {
            print("[ChatManager] Failed to decode envelope from \(peerId): \(error)")
        }
    }

    private func dispatch(envelope: WireEnvelope, from peerId: String) {
        // Ensure conversation exists
        ensureConversation(for: peerId, displayName: envelope.senderName)

        switch envelope.type {
        case .hello:
            handleHello(envelope: envelope, from: peerId)
        case .preKeyMessage:
            handlePreKeyMessage(envelope: envelope, from: peerId)
        case .message:
            handleEncryptedMessage(envelope: envelope, from: peerId)
        case .ack:
            handleAck(envelope: envelope, from: peerId)
        case .typing:
            handleTyping(envelope: envelope, from: peerId)
        }
    }

    // MARK: - Hello

    private func handleHello(envelope: WireEnvelope, from peerId: String) {
        do {
            let bundle = try envelope.decodePayload(PreKeyBundlePayload.self)

            // Store bundle and identity keys
            if var conv = conversations[peerId] {
                conv.preKeyBundle = bundle
                conv.peer.identityDHKeyData = bundle.identityDHKey
                conv.peer.identitySigningKeyData = bundle.identitySigningKey
                conv.peer.displayName = envelope.senderName
                conv.peer.isOnline = true
                conversations[peerId] = conv
                persist()
            }

            // Send our hello back if peer doesn't have our session yet
            if !cryptoEngine.hasSession(for: peerId) {
                sendHello(to: peerId)
            }
        } catch {
            print("[ChatManager] Failed to handle hello from \(peerId): \(error)")
        }
    }

    // MARK: - PreKeyMessage

    private func handlePreKeyMessage(envelope: WireEnvelope, from peerId: String) {
        do {
            let preKeyMsg = try envelope.decodePayload(PreKeyMessagePayload.self)
            let plaintext = try cryptoEngine.decryptPreKeyMessage(preKeyMsg, from: peerId)

            if let chatMessage = decodeChatMessage(from: plaintext) {
                addIncomingMessage(chatMessage, to: peerId)
                sendAck(for: chatMessage.id, status: .delivered, to: peerId)
            }
        } catch {
            print("[ChatManager] Failed to decrypt pre-key message from \(peerId): \(error)")
        }
    }

    // MARK: - Encrypted Message

    private func handleEncryptedMessage(envelope: WireEnvelope, from peerId: String) {
        do {
            let encMsg = try envelope.decodePayload(EncryptedMessagePayload.self)
            let plaintext = try cryptoEngine.decryptMessage(encMsg, from: peerId)

            if let chatMessage = decodeChatMessage(from: plaintext) {
                addIncomingMessage(chatMessage, to: peerId)
                sendAck(for: chatMessage.id, status: .delivered, to: peerId)
            }
        } catch {
            print("[ChatManager] Failed to decrypt message from \(peerId): \(error)")
        }
    }

    // MARK: - Ack

    private func handleAck(envelope: WireEnvelope, from peerId: String) {
        do {
            let ack = try envelope.decodePayload(AckPayload.self)
            if var conv = conversations[peerId] {
                if let idx = conv.messages.firstIndex(where: { $0.id == ack.messageId }) {
                    // Only upgrade status (don't downgrade, e.g. read → delivered)
                    if ack.status > conv.messages[idx].status || conv.messages[idx].status == .sending {
                        conv.messages[idx].status = ack.status
                        conversations[peerId] = conv
                        persist()
                    }
                }
            }
        } catch {
            print("[ChatManager] Failed to handle ack from \(peerId): \(error)")
        }
    }

    // MARK: - Typing

    private func handleTyping(envelope: WireEnvelope, from peerId: String) {
        do {
            let typing = try envelope.decodePayload(TypingPayload.self)
            if var conv = conversations[peerId] {
                conv.isTyping = typing.isTyping
                conversations[peerId] = conv
            }
        } catch {
            print("[ChatManager] Failed to handle typing from \(peerId): \(error)")
        }
    }

    // MARK: - Send Message

    func sendMessage(_ text: String, to peerId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let chatMessage = ChatMessage(
            id: UUID(),
            senderId: localDeviceId,
            recipientId: peerId,
            text: trimmed,
            timestamp: Date(),
            status: .sending
        )

        sendChatMessage(chatMessage, to: peerId)
    }

    // MARK: - Send Image

    /// Send an image to a peer. Compresses to JPEG, generates thumbnail.
    func sendImage(_ imageData: Data, filename: String, to peerId: String) {
        #if canImport(UIKit)
        guard let uiImage = UIImage(data: imageData) else { return }

        // Resize if too large (max 2048px on longest edge)
        let maxDim: CGFloat = 2048
        let resized: UIImage
        if max(uiImage.size.width, uiImage.size.height) > maxDim {
            let scale = maxDim / max(uiImage.size.width, uiImage.size.height)
            let newSize = CGSize(width: uiImage.size.width * scale, height: uiImage.size.height * scale)
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            uiImage.draw(in: CGRect(origin: .zero, size: newSize))
            resized = UIGraphicsGetImageFromCurrentImageContext() ?? uiImage
            UIGraphicsEndImageContext()
        } else {
            resized = uiImage
        }

        guard let compressed = resized.jpegData(compressionQuality: 0.7) else { return }

        // Generate thumbnail (100px)
        let thumbSize: CGFloat = 100
        let thumbScale = thumbSize / max(resized.size.width, resized.size.height)
        let thumbDim = CGSize(width: resized.size.width * thumbScale, height: resized.size.height * thumbScale)
        UIGraphicsBeginImageContextWithOptions(thumbDim, false, 1.0)
        resized.draw(in: CGRect(origin: .zero, size: thumbDim))
        let thumbImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        let thumbData = thumbImage?.jpegData(compressionQuality: 0.5) ?? Data()

        let attachment = Attachment(
            filename: filename,
            mimeType: "image/jpeg",
            data: compressed,
            fileSize: Int64(compressed.count),
            width: Int(resized.size.width),
            height: Int(resized.size.height),
            thumbnailData: thumbData
        )

        let chatMessage = ChatMessage(
            id: UUID(),
            senderId: localDeviceId,
            recipientId: peerId,
            text: "📷 Photo",
            timestamp: Date(),
            status: .sending,
            contentType: .image,
            attachment: attachment
        )

        sendChatMessage(chatMessage, to: peerId)
        #endif
    }

    // MARK: - Send File

    /// Send a file (document, video, etc.) to a peer.
    func sendFile(_ fileData: Data, filename: String, mimeType: String, to peerId: String) {
        // Limit file size to 50 MB for LAN transfer
        guard fileData.count <= 50 * 1024 * 1024 else {
            print("[ChatManager] File too large: \(fileData.count) bytes")
            return
        }

        let attachment = Attachment(
            filename: filename,
            mimeType: mimeType,
            data: fileData,
            fileSize: Int64(fileData.count),
            width: nil,
            height: nil,
            thumbnailData: nil
        )

        let chatMessage = ChatMessage(
            id: UUID(),
            senderId: localDeviceId,
            recipientId: peerId,
            text: "📎 \(filename)",
            timestamp: Date(),
            status: .sending,
            contentType: .file,
            attachment: attachment
        )

        sendChatMessage(chatMessage, to: peerId)
    }

    // MARK: - Unified Send

    /// Core send logic shared by text, image, and file sends.
    private func sendChatMessage(_ chatMessage: ChatMessage, to peerId: String) {
        addOutgoingMessage(chatMessage, to: peerId)
        let bundle = conversations[peerId]?.preKeyBundle
        let localDeviceId = self.localDeviceId
        let displayName = self.displayName

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                if !self.cryptoEngine.hasSession(for: peerId),
                   let bundle = bundle {
                    try self.cryptoEngine.processReceivedBundle(bundle, from: peerId)
                }

                let plaintext = try JSONEncoder().encode(chatMessage)
                let (isPreKey, payload) = try self.cryptoEngine.encrypt(plaintext, for: peerId)

                let envelopeType: WireEnvelope.MessageType = isPreKey ? .preKeyMessage : .message
                let envelope = WireEnvelope(
                    type: envelopeType,
                    senderId: localDeviceId,
                    senderName: displayName,
                    payload: payload
                )
                let wireData = try envelope.wireData()
                self.networkManager.send(wireData, to: peerId)

                DispatchQueue.main.async {
                    self.updateMessageStatus(chatMessage.id, in: peerId, to: .sent)
                }
            } catch {
                print("[ChatManager] Failed to send to \(peerId): \(error)")
                DispatchQueue.main.async {
                    self.updateMessageStatus(chatMessage.id, in: peerId, to: .failed)
                }
            }
        }
    }

    // MARK: - Typing Indicator

    func sendTypingIndicator(to peerId: String, isTyping: Bool) {
        do {
            let payload = TypingPayload(isTyping: isTyping)
            let envelope = try WireEnvelope.make(
                type: .typing,
                senderId: localDeviceId,
                senderName: displayName,
                payload: payload
            )
            let wireData = try envelope.wireData()
            networkManager.send(wireData, to: peerId)
        } catch {
            print("[ChatManager] Failed to send typing indicator: \(error)")
        }
    }

    // MARK: - Read Receipts

    func markAsRead(peerId: String) {
        guard var conv = conversations[peerId] else { return }
        guard conv.unreadCount > 0 else { return }

        conv.unreadCount = 0

        // Send read acks for all unread incoming messages
        let incomingUnread = conv.messages.filter {
            $0.senderId == peerId && $0.status < .read
        }
        conversations[peerId] = conv
        persist()

        for msg in incomingUnread {
            sendAck(for: msg.id, status: .read, to: peerId)
        }
    }

    // MARK: - Delete Conversation

    func deleteConversation(peerId: String) {
        conversations.removeValue(forKey: peerId)
        persist()
    }

    // MARK: - Helpers

    private func ensureConversation(for peerId: String, displayName: String) {
        if conversations[peerId] == nil {
            let peer = Peer(id: peerId, displayName: displayName, isOnline: true, lastSeen: Date())
            conversations[peerId] = Conversation(id: peerId, peer: peer)
        }
    }

    private func addIncomingMessage(_ message: ChatMessage, to peerId: String) {
        guard var conv = conversations[peerId] else { return }
        // Avoid duplicates
        guard !conv.messages.contains(where: { $0.id == message.id }) else { return }
        conv.messages.append(message)
        conv.unreadCount += 1
        conv.isTyping = false
        conversations[peerId] = conv
        persist()
    }

    private func addOutgoingMessage(_ message: ChatMessage, to peerId: String) {
        guard var conv = conversations[peerId] else { return }
        conv.messages.append(message)
        conversations[peerId] = conv
        persist()
    }

    private func updateMessageStatus(_ messageId: UUID, in peerId: String, to status: ChatMessage.Status) {
        guard var conv = conversations[peerId] else { return }
        if let idx = conv.messages.firstIndex(where: { $0.id == messageId }) {
            conv.messages[idx].status = status
            conversations[peerId] = conv
            persist()
        }
    }

    private func sendAck(for messageId: UUID, status: ChatMessage.Status, to peerId: String) {
        do {
            let ack = AckPayload(messageId: messageId, status: status)
            let envelope = try WireEnvelope.make(
                type: .ack,
                senderId: localDeviceId,
                senderName: displayName,
                payload: ack
            )
            let wireData = try envelope.wireData()
            networkManager.send(wireData, to: peerId)
        } catch {
            print("[ChatManager] Failed to send ack: \(error)")
        }
    }

    private func decodeChatMessage(from data: Data) -> ChatMessage? {
        try? JSONDecoder().decode(ChatMessage.self, from: data)
    }

    private func rebuildSorted() {
        sortedConversations = conversations.values
            .sorted { lhs, rhs in
                let lDate = lhs.lastMessage?.timestamp ?? lhs.peer.lastSeen
                let rDate = rhs.lastMessage?.timestamp ?? rhs.peer.lastSeen
                return lDate > rDate
            }
    }

    private func persist() {
        persistence.saveConversations(conversations)
    }
}
