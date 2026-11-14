// ChatManager.swift
// SecureChat – LAN End-to-End Encrypted Messenger
// Central coordinator binding Crypto, Network, Persistence, and UI

import Foundation
import Combine
import UIKit
import CryptoKit
import AVFoundation
import UniformTypeIdentifiers

@MainActor
final class ChatManager: ObservableObject {

    // MARK: - Published state

    @Published var conversations: [String: Conversation] = [:]
    @Published var sortedConversations: [Conversation] = []
    @Published var displayName: String
    @Published var avatarData: Data?
    /// Transfer progress (0…1) by message id, for both directions.
    @Published var transferProgress: [UUID: Double] = [:]
    /// Last user-facing error (shown as a toast / alert).
    @Published var lastError: String?

    // MARK: - Dependencies

    let cryptoEngine: CryptoEngine
    let networkManager: NetworkManager
    let persistence: PersistenceManager
    let localDeviceId: String

    private var cancellables = Set<AnyCancellable>()
    private let transfers = FileTransferEngine()

    // MARK: - Session / outbox state

    private var profileVersion: Int
    private var knownHosts: Set<String>
    /// Peers that speak protocol v2 (v1.2+).
    private var v2Peers: Set<String> = []
    /// Peers we can encrypt to right now.
    private var sessionReady: Set<String> = []
    /// Peers whose new session we are waiting for (they initiate).
    private var awaitingInit: Set<String> = []
    private var lastReset: [String: Date] = [:]
    /// Control messages waiting for a session with a peer.
    private var controlQueue: [String: [ControlMessage]] = [:]
    /// "<messageId>|<peerId>" currently being transmitted.
    private var inFlight: Set<String> = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    static let maxFileSize: Int64 = 4 * 1024 * 1024 * 1024 // 4 GB

    // MARK: - Init

    init(deviceId: String, displayName: String, persistence: PersistenceManager) {
        self.localDeviceId = deviceId
        self.displayName = displayName
        self.persistence = persistence
        self.cryptoEngine = CryptoEngine(deviceId: deviceId)
        self.networkManager = NetworkManager()
        self.profileVersion = persistence.loadProfileVersion()

        // Load persisted conversations and remembered peer addresses
        let loaded = persistence.loadConversations()
        var hosts = Set(persistence.loadKnownHosts())
        for conv in loaded.values where !conv.isGroup {
            if let a = conv.peer.lastAddress { hosts.insert(a) }
        }
        self.knownHosts = hosts
        self.avatarData = persistence.loadAvatar()
        self.conversations = loaded
        rebuildSorted()

        // Keep sortedConversations in sync
        $conversations
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildSorted() }
            .store(in: &cancellables)

        wireCallbacks()
        refreshIdentityFrames()
        networkManager.setKnownHosts(knownHosts)
        start(displayName: displayName)
    }

    // MARK: - Lifecycle

    func start(displayName: String) {
        self.displayName = displayName
        networkManager.start(deviceId: localDeviceId, displayName: displayName)
    }

    /// Connect to a peer by IPv4 address and port (manual fallback).
    func connectByIP(_ host: String, port: UInt16) {
        networkManager.connectToAddress(host: host, port: port)
    }

    func stop() {
        networkManager.stop()
    }

    /// App came to the foreground: reconnect everything right away.
    func appDidBecomeActive() {
        endBackgroundTask()
        networkManager.wake()
    }

    /// App is going to the background: save, and ask iOS for extra time so a
    /// quick app switch does not kill the session.
    func appDidEnterBackground() {
        persistence.saveConversations(conversations)
        persistence.flushNow()
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SecureChat.keepalive") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    // MARK: - Profile

    /// Update own display name (visible to everyone; there is no per-contact remark).
    func updateDisplayName(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != displayName else { return }
        displayName = trimmed
        persistence.saveDisplayName(trimmed)
        networkManager.updateDisplayName(trimmed)
        refreshIdentityFrames()
        bumpProfileAndBroadcast()
    }

    /// Set (or clear) own avatar. Image is downscaled to 256 px JPEG.
    func updateAvatar(_ imageData: Data?) {
        if let imageData, let image = UIImage(data: imageData) {
            let small = MediaHelper.resize(image, maxDimension: 256)
            avatarData = small.jpegData(compressionQuality: 0.75)
        } else {
            avatarData = nil
        }
        persistence.saveAvatar(avatarData)
        bumpProfileAndBroadcast()
    }

    private func bumpProfileAndBroadcast() {
        profileVersion += 1
        persistence.saveProfileVersion(profileVersion)
        for peerId in networkManager.connectedPeerIds {
            sendControl(profileControl(), to: peerId)
        }
    }

    private func profileControl() -> ControlMessage {
        ControlMessage(kind: .profile, name: displayName, avatar: avatarData, version: profileVersion)
    }

    // MARK: - Identity frames

    private func refreshIdentityFrames() {
        networkManager.setIdentity(helloFrame: helloFrame(hasSession: nil),
                                   pingFrame: envelopeData(type: .ping, payload: PingPayload()))
    }

    private func helloFrame(hasSession: Bool?) -> Data? {
        var bundle = cryptoEngine.generatePreKeyBundle()
        bundle.hasSession = hasSession
        bundle.protocolVersion = 2
        return envelopeData(type: .hello, payload: bundle)
    }

    private func envelopeData<T: Encodable>(type: WireEnvelope.MessageType, payload: T) -> Data? {
        do {
            let envelope = try WireEnvelope.make(type: type, senderId: localDeviceId,
                                                 senderName: displayName, payload: payload)
            return try envelope.wireData()
        } catch {
            print("[ChatManager] encode failed: \(error)")
            return nil
        }
    }

    // MARK: - Network Callbacks

    private func wireCallbacks() {
        networkManager.onPeerFound = { [weak self] peerId, peerName in
            guard let self else { return }
            guard peerId != self.localDeviceId, !peerId.hasPrefix("group-") else { return }
            if var conv = self.conversations[peerId] {
                if !peerName.isEmpty { conv.peer.displayName = peerName }
                conv.peer.lastSeen = Date()
                self.conversations[peerId] = conv
            } else {
                let peer = Peer(id: peerId, displayName: peerName, isOnline: false, lastSeen: Date())
                self.conversations[peerId] = Conversation(id: peerId, peer: peer)
            }
            self.persist()
        }

        networkManager.onPeerLost = { _ in
            // Bonjour loss alone does not mean the TCP link is gone.
        }

        networkManager.onPeerDisconnected = { [weak self] peerId in
            guard let self else { return }
            self.sessionReady.remove(peerId)
            if var conv = self.conversations[peerId] {
                conv.peer.isOnline = false
                conv.peer.lastSeen = Date()
                conv.isTyping = false
                self.conversations[peerId] = conv
                self.persist()
            }
        }

        networkManager.onPeerConnected = { [weak self] peerId in
            guard let self else { return }
            self.setOnline(peerId, true)
            self.sessionReady.remove(peerId)
            let has = self.cryptoEngine.hasSession(for: peerId) && !self.awaitingInit.contains(peerId)
            if let hello = self.helloFrame(hasSession: has) {
                self.networkManager.send(hello, to: peerId)
            }
        }

        networkManager.onPeerAddress = { [weak self] peerId, host in
            guard let self else { return }
            if var conv = self.conversations[peerId], conv.peer.lastAddress != host {
                conv.peer.lastAddress = host
                self.conversations[peerId] = conv
                self.persist()
            }
            if !self.knownHosts.contains(host) {
                self.knownHosts.insert(host)
                self.persistence.saveKnownHosts(Array(self.knownHosts))
                self.networkManager.setKnownHosts(self.knownHosts)
            }
        }

        networkManager.onDataReceived = { [weak self] data, peerId in
            self?.handleReceivedData(data, from: peerId)
        }

        transfers.onProgress = { [weak self] id, progress in
            self?.transferProgress[id] = progress
        }
        transfers.onIncomingFinished = { [weak self] id, peerId, ok in
            self?.incomingTransferFinished(id, from: peerId, ok: ok)
        }
    }

    private func setOnline(_ peerId: String, _ online: Bool) {
        guard var conv = conversations[peerId] else { return }
        if conv.peer.isOnline != online {
            conv.peer.isOnline = online
            conv.peer.lastSeen = Date()
            conversations[peerId] = conv
        }
    }

    // MARK: - Receiving Data

    private func handleReceivedData(_ data: Data, from peerId: String) {
        if data.first == FileChunkFrame.magic {
            transfers.handleChunk(data, from: peerId)
            return
        }
        guard let envelope = try? JSONDecoder().decode(WireEnvelope.self, from: data) else {
            return // unknown frame type from a newer/older peer
        }
        dispatch(envelope: envelope, from: peerId)
    }

    private func dispatch(envelope: WireEnvelope, from peerId: String) {
        if envelope.type == .ping { return }

        ensureConversation(for: peerId, displayName: envelope.senderName)
        if var conv = conversations[peerId], !envelope.senderName.isEmpty,
           conv.peer.displayName != envelope.senderName || !conv.peer.isOnline {
            conv.peer.displayName = envelope.senderName
            conv.peer.isOnline = networkManager.isConnected(to: peerId)
            conversations[peerId] = conv
        }

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
        case .ping:
            break
        }
    }

    // MARK: - Hello / session management

    /// Deterministic role: the smaller device id initiates X3DH.
    private func amSmaller(_ peer: String) -> Bool { localDeviceId < peer }

    private func handleHello(envelope: WireEnvelope, from peerId: String) {
        guard let bundle = try? envelope.decodePayload(PreKeyBundlePayload.self) else { return }

        if var conv = conversations[peerId] {
            conv.preKeyBundle = bundle
            conv.peer.identityDHKeyData = bundle.identityDHKey
            conv.peer.identitySigningKeyData = bundle.identitySigningKey
            conv.peer.isOnline = true
            conversations[peerId] = conv
            persist()
        }

        guard (bundle.protocolVersion ?? 0) >= 2 else {
            // v1.1 peer: legacy lazy session establishment.
            v2Peers.remove(peerId)
            if !cryptoEngine.hasSession(for: peerId), let hello = helloFrame(hasSession: nil) {
                networkManager.send(hello, to: peerId)
            }
            markReady(peerId)
            return
        }
        v2Peers.insert(peerId)

        // Identification-only hello (first frame on a link); the full one follows.
        guard let theirHas = bundle.hasSession else { return }

        if amSmaller(peerId) {
            if !cryptoEngine.hasSession(for: peerId) || theirHas == false {
                cryptoEngine.resetSession(for: peerId)
                initiateSession(with: peerId, bundle: bundle)
            } else {
                markReady(peerId)
            }
        } else {
            if theirHas == false {
                cryptoEngine.resetSession(for: peerId)
                awaitingInit.insert(peerId)
            }
            if cryptoEngine.hasSession(for: peerId) && !awaitingInit.contains(peerId) {
                markReady(peerId)
            } else {
                awaitingInit.insert(peerId)
            }
        }
    }

    /// Smaller device id starts the X3DH handshake with an encrypted sessionInit.
    private func initiateSession(with peerId: String, bundle: PreKeyBundlePayload) {
        do {
            try cryptoEngine.processReceivedBundle(bundle, from: peerId)
            let inner = InnerEnvelope(v: 2, control: ControlMessage(kind: .sessionInit))
            let plaintext = try JSONEncoder().encode(inner)
            let (isPreKey, payload) = try cryptoEngine.encrypt(plaintext, for: peerId)
            let env = WireEnvelope(type: isPreKey ? .preKeyMessage : .message,
                                   senderId: localDeviceId, senderName: displayName, payload: payload)
            networkManager.send(try env.wireData(), to: peerId)
            markReady(peerId)
        } catch {
            print("[ChatManager] initiateSession failed: \(error)")
        }
    }

    private func markReady(_ peerId: String) {
        awaitingInit.remove(peerId)
        let wasReady = sessionReady.contains(peerId)
        sessionReady.insert(peerId)
        if !wasReady {
            // Profile first so names/avatars show up immediately.
            sendControl(profileControl(), to: peerId)
            // Ask for info on groups where we only have a placeholder.
            for conv in conversations.values {
                if let g = conv.group, g.version == 0, g.members.contains(peerId) {
                    sendControl(ControlMessage(kind: .groupInfoRequest, groupId: g.id), to: peerId)
                }
            }
        }
        flushControlQueue(peerId)
        flushOutbox(peerId)
    }

    private func handleDecryptFailure(from peerId: String, error: Error) {
        print("[ChatManager] Decrypt failure from \(peerId): \(error)")
        let now = Date()
        if let last = lastReset[peerId], now.timeIntervalSince(last) < 8 { return }
        lastReset[peerId] = now
        cryptoEngine.resetSession(for: peerId)
        sessionReady.remove(peerId)

        guard v2Peers.contains(peerId) else {
            if let hello = helloFrame(hasSession: nil) { networkManager.send(hello, to: peerId) }
            return
        }
        if amSmaller(peerId), let bundle = conversations[peerId]?.preKeyBundle {
            initiateSession(with: peerId, bundle: bundle)
        } else {
            awaitingInit.insert(peerId)
            if let hello = helloFrame(hasSession: false) { networkManager.send(hello, to: peerId) }
        }
    }

    // MARK: - Decrypt

    private func handlePreKeyMessage(envelope: WireEnvelope, from peerId: String) {
        do {
            let preKeyMsg = try envelope.decodePayload(PreKeyMessagePayload.self)
            let plaintext = try cryptoEngine.decryptPreKeyMessage(preKeyMsg, from: peerId)
            awaitingInit.remove(peerId)
            handlePlaintext(plaintext, from: peerId)
            markReady(peerId)
        } catch {
            handleDecryptFailure(from: peerId, error: error)
        }
    }

    private func handleEncryptedMessage(envelope: WireEnvelope, from peerId: String) {
        do {
            let encMsg = try envelope.decodePayload(EncryptedMessagePayload.self)
            let plaintext = try cryptoEngine.decryptMessage(encMsg, from: peerId)
            handlePlaintext(plaintext, from: peerId)
        } catch {
            handleDecryptFailure(from: peerId, error: error)
        }
    }

    private func handlePlaintext(_ plaintext: Data, from peerId: String) {
        if let message = try? JSONDecoder().decode(ChatMessage.self, from: plaintext) {
            handleIncomingChat(message, from: peerId)
        } else if let inner = try? JSONDecoder().decode(InnerEnvelope.self, from: plaintext) {
            handleControl(inner.control, from: peerId)
        }
    }

    // MARK: - Incoming chat

    private func handleIncomingChat(_ incoming: ChatMessage, from peerId: String) {
        guard incoming.senderId == peerId else { return }
        let convId: String
        if let gid = incoming.groupId {
            convId = gid
            ensureGroupPlaceholder(gid, sender: peerId)
        } else {
            convId = peerId
        }
        guard var conv = conversations[convId] else { return }

        if let idx = conv.messages.firstIndex(where: { $0.id == incoming.id }) {
            // Retransmission. Restart an unfinished incoming transfer if needed.
            let existing = conv.messages[idx]
            if let a = existing.attachment, a.isComplete == false, let wire = incoming.attachment, wire.fileKey != nil {
                var restarted = existing
                restarted.attachment = registerIncomingTransfer(wire, messageId: incoming.id, from: peerId)
                conv.messages[idx] = restarted
                conversations[convId] = conv
                persist()
            } else {
                sendAck(for: incoming.id, status: .delivered, to: peerId, groupId: incoming.groupId)
            }
            return
        }

        var message = incoming
        message.pendingRecipients = nil
        message.status = .delivered
        var needsTransfer = false
        if var a = message.attachment {
            if let data = a.data {
                if let rel = AttachmentStore.write(data, messageId: message.id, filename: a.filename) {
                    a.localFile = rel
                    a.data = nil
                }
                a.isComplete = true
                a.fileKey = nil
                message.attachment = a
            } else if a.transferId != nil, a.fileKey != nil {
                message.attachment = registerIncomingTransfer(a, messageId: message.id, from: peerId)
                needsTransfer = message.attachment?.isComplete == false
            }
        }

        conv.messages.append(message)
        conv.unreadCount += 1
        conv.isTyping = false
        conversations[convId] = conv
        persist()

        if !needsTransfer {
            sendAck(for: message.id, status: .delivered, to: peerId, groupId: message.groupId)
        }
    }

    private func registerIncomingTransfer(_ wire: Attachment, messageId: UUID, from peerId: String) -> Attachment {
        var a = wire
        let (rel, url) = AttachmentStore.prepare(messageId: messageId, filename: a.filename)
        a.localFile = rel
        a.data = nil
        let total = a.chunkCount ?? 0
        if let key = a.fileKey {
            transfers.registerIncoming(transferId: messageId, peerId: peerId, key: key,
                                       total: total, chunkSize: a.chunkSize ?? FileTransferEngine.chunkSize,
                                       fileURL: url)
        }
        a.fileKey = nil
        a.isComplete = (total == 0)
        if total > 0 { transferProgress[messageId] = 0 }
        return a
    }

    private func incomingTransferFinished(_ id: UUID, from peerId: String, ok: Bool) {
        transferProgress.removeValue(forKey: id)
        for (convId, var conv) in conversations {
            guard let idx = conv.messages.firstIndex(where: { $0.id == id }) else { continue }
            if ok {
                conv.messages[idx].attachment?.isComplete = true
                conversations[convId] = conv
                persist()
                sendAck(for: id, status: .delivered, to: peerId, groupId: conv.messages[idx].groupId)
            }
            return
        }
    }

    // MARK: - Control messages

    private func handleControl(_ control: ControlMessage, from peerId: String) {
        switch control.kind {
        case .sessionInit:
            break // session is established by the pre-key message itself

        case .profile:
            guard var conv = conversations[peerId] else { return }
            if let name = control.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                conv.peer.displayName = name
            }
            conv.peer.avatarData = control.avatar
            conversations[peerId] = conv
            // Keep group member names fresh.
            for (gid, var g) in conversations where g.group?.members.contains(peerId) == true {
                g.group?.memberNames[peerId] = conv.peer.displayName
                conversations[gid] = g
            }
            persist()

        case .delete:
            let convId = control.groupId ?? peerId
            guard var conv = conversations[convId] else { return }
            if let g = conv.group, !g.members.contains(peerId) { return }
            let ids = Set(control.ids ?? [])
            removeMessages(ids, from: &conv)
            conversations[convId] = conv
            persist()

        case .clear:
            let convId = control.groupId ?? peerId
            guard var conv = conversations[convId] else { return }
            if let g = conv.group, !g.members.contains(peerId) { return }
            removeMessages(Set(conv.messages.map(\.id)), from: &conv)
            conversations[convId] = conv
            persist()

        case .groupUpdate:
            guard let incoming = control.group, incoming.members.contains(peerId) || incoming.createdBy == peerId else { return }
            applyGroupUpdate(incoming, from: peerId)

        case .groupLeave:
            guard let gid = control.groupId, var conv = conversations[gid], var g = conv.group else { return }
            g.members.removeAll { $0 == peerId }
            conv.group = g
            conversations[gid] = conv
            persist()

        case .groupInfoRequest:
            guard let gid = control.groupId, let g = conversations[gid]?.group,
                  g.members.contains(peerId), g.version > 0 else { return }
            sendControl(ControlMessage(kind: .groupUpdate, groupId: gid, group: g), to: peerId)
        }
    }

    private func removeMessages(_ ids: Set<UUID>, from conv: inout Conversation) {
        guard !ids.isEmpty else { return }
        for m in conv.messages where ids.contains(m.id) {
            if m.attachment != nil {
                transfers.cancel(m.id)
                AttachmentStore.delete(messageId: m.id)
                transferProgress.removeValue(forKey: m.id)
            }
        }
        conv.messages.removeAll { ids.contains($0.id) }
        conv.unreadCount = min(conv.unreadCount, conv.messages.filter { $0.senderId != localDeviceId }.count)
    }

    // MARK: - Ack / Typing

    private func handleAck(envelope: WireEnvelope, from peerId: String) {
        guard let ack = try? envelope.decodePayload(AckPayload.self) else { return }
        var convId = ack.groupId ?? peerId
        if conversations[convId]?.messages.contains(where: { $0.id == ack.messageId }) != true {
            guard let found = conversations.first(where: { $0.value.messages.contains(where: { $0.id == ack.messageId }) })?.key else { return }
            convId = found
        }
        guard var conv = conversations[convId],
              let idx = conv.messages.firstIndex(where: { $0.id == ack.messageId }) else { return }
        var m = conv.messages[idx]
        if var pending = m.pendingRecipients {
            pending.removeAll { $0 == peerId }
            m.pendingRecipients = pending.isEmpty ? nil : pending
        }
        if ack.status > m.status || m.status == .sending || m.status == .failed {
            if ack.status != .failed { m.status = ack.status }
        }
        conv.messages[idx] = m
        conversations[convId] = conv
        persist()
    }

    private func handleTyping(envelope: WireEnvelope, from peerId: String) {
        guard let typing = try? envelope.decodePayload(TypingPayload.self),
              var conv = conversations[peerId] else { return }
        conv.isTyping = typing.isTyping
        conversations[peerId] = conv
    }

    // MARK: - Public send API

    func sendMessage(_ text: String, to convId: String, replyTo: ChatMessage? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var message = ChatMessage(id: UUID(), senderId: localDeviceId, recipientId: convId,
                                  text: trimmed, timestamp: Date(), status: .sending)
        applyReply(&message, replyTo: replyTo, convId: convId)
        deliver(message, in: convId)
    }

    /// Send an image (compressed JPEG, inline – v1.1 peers can still see it).
    func sendImage(_ imageData: Data, filename: String, to convId: String, replyTo: ChatMessage? = nil) {
        guard let uiImage = UIImage(data: imageData) else {
            lastError = "Unsupported image"
            return
        }
        let resized = MediaHelper.resize(uiImage, maxDimension: 2048)
        guard let compressed = resized.jpegData(compressionQuality: 0.75) else { return }
        let thumb = MediaHelper.resize(resized, maxDimension: 120).jpegData(compressionQuality: 0.5)

        let id = UUID()
        var attachment = Attachment(filename: filename, mimeType: "image/jpeg", data: nil,
                                    fileSize: Int64(compressed.count),
                                    width: Int(resized.size.width), height: Int(resized.size.height),
                                    thumbnailData: thumb)
        attachment.localFile = AttachmentStore.write(compressed, messageId: id, filename: filename)
        attachment.isComplete = true
        if attachment.localFile == nil { attachment.data = compressed }

        var message = ChatMessage(id: id, senderId: localDeviceId, recipientId: convId,
                                  text: "📷 Photo", timestamp: Date(), status: .sending,
                                  contentType: .image, attachment: attachment)
        applyReply(&message, replyTo: replyTo, convId: convId)
        deliver(message, in: convId)
    }

    /// Send any file (document, video, …) using encrypted chunked transfer.
    /// The file is copied into the app's attachment store first.
    func sendFile(at url: URL, filename: String? = nil, mimeType: String? = nil,
                  to convId: String, replyTo: ChatMessage? = nil, securityScoped: Bool = false) {
        let name = filename ?? url.lastPathComponent
        let mime = mimeType ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let id = UUID()
        let accessing = securityScoped ? url.startAccessingSecurityScopedResource() : false

        DispatchQueue.global(qos: .userInitiated).async {
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let rel = AttachmentStore.copyIn(url, messageId: id, filename: name)
            var info: MediaHelper.VideoInfo?
            var size: Int64 = 0
            if let rel {
                let local = AttachmentStore.location(rel)
                size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.int64Value ?? 0
                if mime.lowercased().hasPrefix("video/") {
                    info = MediaHelper.videoInfo(for: local)
                }
            }
            let finalSize = size
            let finalInfo = info
            DispatchQueue.main.async {
                self.finishFileSend(id: id, rel: rel, name: name, mime: mime, size: finalSize,
                                    video: finalInfo, convId: convId, replyTo: replyTo)
            }
        }
    }

    private func finishFileSend(id: UUID, rel: String?, name: String, mime: String, size: Int64,
                                video: MediaHelper.VideoInfo?, convId: String, replyTo: ChatMessage?) {
        guard let rel else {
            lastError = "Could not read \(name)"
            return
        }
        guard size <= Self.maxFileSize else {
            AttachmentStore.delete(messageId: id)
            lastError = "\(name) is larger than 4 GB"
            return
        }
        var attachment = Attachment(filename: name, mimeType: mime, data: nil, fileSize: size,
                                    width: video?.width, height: video?.height,
                                    thumbnailData: video?.thumbnail)
        attachment.duration = video?.duration
        attachment.localFile = rel
        attachment.isComplete = true
        attachment.transferId = id
        attachment.chunkSize = FileTransferEngine.chunkSize
        attachment.chunkCount = Int((size + Int64(FileTransferEngine.chunkSize) - 1) / Int64(FileTransferEngine.chunkSize))

        let isVideo = mime.lowercased().hasPrefix("video/")
        var message = ChatMessage(id: id, senderId: localDeviceId, recipientId: convId,
                                  text: isVideo ? "🎬 Video" : "📎 \(name)", timestamp: Date(),
                                  status: .sending, contentType: .file, attachment: attachment)
        applyReply(&message, replyTo: replyTo, convId: convId)
        deliver(message, in: convId)
    }

    /// Retry all pending recipients of a failed message.
    func resend(_ messageId: UUID, in convId: String) {
        guard let conv = conversations[convId],
              let m = conv.messages.first(where: { $0.id == messageId }) else { return }
        let targets = m.pendingRecipients ?? recipients(for: conv)
        for peer in targets {
            transmit(messageId, convId: convId, to: peer)
        }
    }

    private func applyReply(_ message: inout ChatMessage, replyTo: ChatMessage?, convId: String) {
        guard let r = replyTo else { return }
        message.replyToId = r.id
        message.replyToText = String(r.previewText.prefix(140))
        message.replyToSender = senderName(for: r, in: convId)
    }

    // MARK: - Outbox

    private func recipients(for conv: Conversation) -> [String] {
        if let g = conv.group {
            return g.members.filter { $0 != localDeviceId }
        }
        return [conv.id]
    }

    private func deliver(_ original: ChatMessage, in convId: String) {
        guard var conv = conversations[convId] else { return }
        var message = original
        message.senderName = displayName
        if conv.isGroup { message.groupId = convId }
        let targets = recipients(for: conv)
        message.pendingRecipients = targets.isEmpty ? nil : targets
        message.status = targets.isEmpty ? .sent : .sending
        conv.messages.append(message)
        conversations[convId] = conv
        persist()

        for peer in targets {
            transmit(message.id, convId: convId, to: peer)
        }
        refreshStatusAfterAttempt(message.id, convId: convId)
    }

    private func canSend(to peerId: String) -> Bool {
        guard networkManager.isConnected(to: peerId) else { return false }
        if v2Peers.contains(peerId) { return sessionReady.contains(peerId) }
        // Legacy peer: need a session or their bundle.
        return cryptoEngine.hasSession(for: peerId) || conversations[peerId]?.preKeyBundle != nil
    }

    /// Encrypt and send one message to one recipient (plus its file chunks).
    private func transmit(_ messageId: UUID, convId: String, to peerId: String) {
        let key = "\(messageId.uuidString)|\(peerId)"
        guard !inFlight.contains(key) else { return }
        guard canSend(to: peerId) else {
            refreshStatusAfterAttempt(messageId, convId: convId)
            return
        }
        guard let message = conversations[convId]?.messages.first(where: { $0.id == messageId }) else { return }

        var wire = message
        wire.pendingRecipients = nil
        wire.status = .sent
        var chunked: (url: URL, key: SymmetricKey, count: Int)?

        if var a = wire.attachment {
            if message.contentType == .image {
                // Images travel inline.
                if a.data == nil, let rel = a.localFile {
                    a.data = try? Data(contentsOf: AttachmentStore.location(rel))
                }
                a.localFile = nil
                a.isComplete = nil
                a.transferId = nil
                wire.attachment = a
            } else if let rel = a.localFile {
                let fileKey = SymmetricKey(size: .bits256)
                a.fileKey = fileKey.withUnsafeBytes { Data($0) }
                a.transferId = message.id
                a.localFile = nil
                a.isComplete = nil
                a.data = nil
                let count = a.chunkCount ?? Int((a.fileSize + Int64(FileTransferEngine.chunkSize) - 1) / Int64(FileTransferEngine.chunkSize))
                a.chunkCount = count
                a.chunkSize = FileTransferEngine.chunkSize
                wire.attachment = a
                chunked = (AttachmentStore.location(rel), fileKey, count)
            }
        }

        guard let plaintext = try? JSONEncoder().encode(wire) else { return }
        inFlight.insert(key)
        let sent = encryptAndSend(plaintext, to: peerId) { [weak self] ok in
            guard let self else { return }
            if chunked == nil {
                self.inFlight.remove(key)
                if ok { self.markSent(messageId, convId: convId) }
                self.refreshStatusAfterAttempt(messageId, convId: convId)
            }
        }
        guard sent else {
            inFlight.remove(key)
            refreshStatusAfterAttempt(messageId, convId: convId)
            return
        }

        if let chunked {
            transferProgress[messageId] = 0
            transfers.send(fileURL: chunked.url, transferId: messageId, key: chunked.key,
                           chunkCount: chunked.count, to: peerId, network: networkManager) { [weak self] ok in
                guard let self else { return }
                self.inFlight.remove(key)
                self.transferProgress.removeValue(forKey: messageId)
                if ok { self.markSent(messageId, convId: convId) }
                self.refreshStatusAfterAttempt(messageId, convId: convId)
            }
        }
    }

    private func markSent(_ messageId: UUID, convId: String) {
        guard var conv = conversations[convId],
              let idx = conv.messages.firstIndex(where: { $0.id == messageId }) else { return }
        if conv.messages[idx].status == .sending || conv.messages[idx].status == .failed {
            conv.messages[idx].status = .sent
            conversations[convId] = conv
            persist()
        }
    }

    /// Show "failed" (red !) when nothing is in flight and nobody got it yet.
    private func refreshStatusAfterAttempt(_ messageId: UUID, convId: String) {
        guard var conv = conversations[convId],
              let idx = conv.messages.firstIndex(where: { $0.id == messageId }) else { return }
        let m = conv.messages[idx]
        guard m.status == .sending else { return }
        let anyInFlight = inFlight.contains { $0.hasPrefix(messageId.uuidString) }
        if !anyInFlight {
            conv.messages[idx].status = .failed
            conversations[convId] = conv
            persist()
        }
    }

    /// Resend everything still pending for a peer (after reconnect).
    private func flushOutbox(_ peerId: String) {
        for conv in conversations.values {
            for m in conv.messages where m.senderId == localDeviceId && (m.pendingRecipients?.contains(peerId) ?? false) {
                transmit(m.id, convId: conv.id, to: peerId)
            }
        }
    }

    // MARK: - Encryption

    /// Encrypt plaintext for a peer and queue it. Returns false if no session.
    @discardableResult
    private func encryptAndSend(_ plaintext: Data, to peerId: String, completion: ((Bool) -> Void)? = nil) -> Bool {
        do {
            if !cryptoEngine.hasSession(for: peerId) {
                // Only legacy peers establish sessions lazily.
                guard !v2Peers.contains(peerId), let bundle = conversations[peerId]?.preKeyBundle else { return false }
                try cryptoEngine.processReceivedBundle(bundle, from: peerId)
            }
            let (isPreKey, payload) = try cryptoEngine.encrypt(plaintext, for: peerId)
            let envelope = WireEnvelope(type: isPreKey ? .preKeyMessage : .message,
                                        senderId: localDeviceId, senderName: displayName, payload: payload)
            let data = try envelope.wireData()
            networkManager.send(data, to: peerId) { ok in
                DispatchQueue.main.async { completion?(ok) }
            }
            return true
        } catch {
            print("[ChatManager] encrypt failed for \(peerId): \(error)")
            return false
        }
    }

    private func sendControl(_ control: ControlMessage, to peerId: String) {
        guard peerId != localDeviceId else { return }
        if canSend(to: peerId), v2Peers.contains(peerId),
           let plaintext = try? JSONEncoder().encode(InnerEnvelope(v: 2, control: control)),
           encryptAndSend(plaintext, to: peerId) {
            return
        }
        // Queue (de-duplicate profile updates).
        var queue = controlQueue[peerId] ?? []
        if control.kind == .profile { queue.removeAll { $0.kind == .profile } }
        queue.append(control)
        controlQueue[peerId] = Array(queue.suffix(200))
    }

    private func flushControlQueue(_ peerId: String) {
        guard v2Peers.contains(peerId), let queue = controlQueue.removeValue(forKey: peerId) else { return }
        for control in queue { sendControl(control, to: peerId) }
    }

    // MARK: - Typing Indicator

    func sendTypingIndicator(to convId: String, isTyping: Bool) {
        guard conversations[convId]?.isGroup == false, networkManager.isConnected(to: convId),
              let data = envelopeData(type: .typing, payload: TypingPayload(isTyping: isTyping)) else { return }
        networkManager.send(data, to: convId)
    }

    // MARK: - Read Receipts

    func markAsRead(peerId convId: String) {
        guard var conv = conversations[convId] else { return }
        guard conv.unreadCount > 0 else { return }
        conv.unreadCount = 0
        let unread = conv.messages.filter { $0.senderId != localDeviceId && $0.status < .read }
        for i in conv.messages.indices where conv.messages[i].senderId != localDeviceId && conv.messages[i].status < .read {
            conv.messages[i].status = .read
        }
        conversations[convId] = conv
        persist()
        for msg in unread {
            sendAck(for: msg.id, status: .read, to: msg.senderId, groupId: conv.isGroup ? convId : nil)
        }
    }

    private func sendAck(for messageId: UUID, status: ChatMessage.Status, to peerId: String, groupId: String?) {
        guard networkManager.isConnected(to: peerId),
              let data = envelopeData(type: .ack, payload: AckPayload(messageId: messageId, status: status, groupId: groupId)) else { return }
        networkManager.send(data, to: peerId)
    }

    // MARK: - Delete

    /// Delete messages locally, and optionally for everyone in the chat (Telegram style).
    func deleteMessages(_ ids: Set<UUID>, in convId: String, forEveryone: Bool) {
        guard var conv = conversations[convId], !ids.isEmpty else { return }
        removeMessages(ids, from: &conv)
        conversations[convId] = conv
        persist()
        if forEveryone {
            let control = ControlMessage(kind: .delete, ids: Array(ids), groupId: conv.isGroup ? convId : nil)
            for peer in recipients(for: conv) { sendControl(control, to: peer) }
        }
    }

    /// Remove all messages from a chat (optionally for everyone).
    func clearChat(_ convId: String, forEveryone: Bool) {
        guard var conv = conversations[convId] else { return }
        removeMessages(Set(conv.messages.map(\.id)), from: &conv)
        conv.unreadCount = 0
        conversations[convId] = conv
        persist()
        if forEveryone {
            let control = ControlMessage(kind: .clear, groupId: conv.isGroup ? convId : nil)
            for peer in recipients(for: conv) { sendControl(control, to: peer) }
        }
    }

    /// Delete a conversation (for groups this also leaves the group).
    func deleteConversation(peerId convId: String) {
        guard var conv = conversations[convId] else { return }
        if conv.isGroup { leaveGroup(convId) }
        removeMessages(Set(conv.messages.map(\.id)), from: &conv)
        conversations.removeValue(forKey: convId)
        persist()
    }

    // MARK: - Groups

    /// Create a group with known peers; returns the group id.
    @discardableResult
    func createGroup(name: String, members: [String]) -> String {
        let gid = "group-" + UUID().uuidString
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = [localDeviceId] + members.filter { $0 != localDeviceId }
        var names: [String: String] = [localDeviceId: displayName]
        for m in members { names[m] = conversations[m]?.peer.displayName ?? "Member" }
        let info = GroupInfo(id: gid, name: trimmed.isEmpty ? "Group" : trimmed, members: all,
                             memberNames: names, createdBy: localDeviceId, version: 1, updatedAt: Date())
        var conv = Conversation(id: gid, peer: Peer(id: gid, displayName: info.name, isOnline: false, lastSeen: Date()))
        conv.group = info
        conversations[gid] = conv
        persist()
        broadcastGroup(info, extraRecipients: [])
        return gid
    }

    func renameGroup(_ gid: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateGroup(gid) { $0.name = trimmed }
    }

    func addMembers(_ ids: [String], to gid: String) {
        mutateGroup(gid) { g in
            for id in ids where !g.members.contains(id) {
                g.members.append(id)
                g.memberNames[id] = self.conversations[id]?.peer.displayName ?? "Member"
            }
        }
    }

    func removeMember(_ id: String, from gid: String) {
        guard let before = conversations[gid]?.group else { return }
        mutateGroup(gid) { g in g.members.removeAll { $0 == id } }
        // Tell the removed member too.
        if before.members.contains(id), let g = conversations[gid]?.group {
            sendControl(ControlMessage(kind: .groupUpdate, groupId: gid, group: g), to: id)
        }
    }

    func leaveGroup(_ gid: String) {
        guard var conv = conversations[gid], var g = conv.group else { return }
        let others = g.members.filter { $0 != localDeviceId }
        for peer in others {
            sendControl(ControlMessage(kind: .groupLeave, groupId: gid), to: peer)
        }
        g.members.removeAll { $0 == localDeviceId }
        conv.group = g
        conversations[gid] = conv
        persist()
    }

    private func mutateGroup(_ gid: String, _ change: (inout GroupInfo) -> Void) {
        guard var conv = conversations[gid], var g = conv.group else { return }
        change(&g)
        g.memberNames[localDeviceId] = displayName
        g.version = max(g.version, 0) + 1
        g.updatedAt = Date()
        conv.group = g
        conv.peer.displayName = g.name
        conversations[gid] = conv
        persist()
        broadcastGroup(g, extraRecipients: [])
    }

    private func broadcastGroup(_ g: GroupInfo, extraRecipients: [String]) {
        let control = ControlMessage(kind: .groupUpdate, groupId: g.id, group: g)
        for peer in Set(g.members + extraRecipients) where peer != localDeviceId {
            sendControl(control, to: peer)
        }
    }

    private func applyGroupUpdate(_ incoming: GroupInfo, from peerId: String) {
        if var conv = conversations[incoming.id], let local = conv.group {
            let newer = incoming.version > local.version ||
                (incoming.version == local.version && incoming.updatedAt > local.updatedAt)
            guard newer else { return }
            conv.group = incoming
            conv.peer.displayName = incoming.name
            conversations[incoming.id] = conv
        } else {
            guard incoming.members.contains(localDeviceId) else { return }
            var conv = Conversation(id: incoming.id,
                                    peer: Peer(id: incoming.id, displayName: incoming.name, isOnline: false, lastSeen: Date()))
            conv.group = incoming
            conversations[incoming.id] = conv
        }
        persist()
    }

    private func ensureGroupPlaceholder(_ gid: String, sender: String) {
        guard conversations[gid] == nil else { return }
        let names = [sender: conversations[sender]?.peer.displayName ?? "Member", localDeviceId: displayName]
        let info = GroupInfo(id: gid, name: "Group", members: [sender, localDeviceId], memberNames: names,
                             createdBy: sender, version: 0, updatedAt: .distantPast)
        var conv = Conversation(id: gid, peer: Peer(id: gid, displayName: info.name, isOnline: false, lastSeen: Date()))
        conv.group = info
        conversations[gid] = conv
        sendControl(ControlMessage(kind: .groupInfoRequest, groupId: gid), to: sender)
    }

    /// Peers that can be added to groups (1:1 conversations).
    var knownPeers: [Peer] {
        conversations.values.filter { !$0.isGroup }.map(\.peer).sorted { $0.displayName < $1.displayName }
    }

    // MARK: - Display helpers

    func memberName(_ peerId: String, in convId: String? = nil) -> String {
        if peerId == localDeviceId { return displayName }
        if let p = conversations[peerId]?.peer { return p.displayName }
        if let convId, let n = conversations[convId]?.group?.memberNames[peerId] { return n }
        return "Member"
    }

    func avatar(for peerId: String) -> Data? {
        if peerId == localDeviceId { return avatarData }
        return conversations[peerId]?.peer.avatarData
    }

    func senderName(for message: ChatMessage, in convId: String) -> String {
        if message.senderId == localDeviceId { return displayName }
        if let p = conversations[message.senderId]?.peer { return p.displayName }
        return message.senderName ?? memberName(message.senderId, in: convId)
    }

    func isOnline(_ conv: Conversation) -> Bool {
        if let g = conv.group {
            return g.members.contains { $0 != localDeviceId && networkManager.isConnected(to: $0) }
        }
        return conv.peer.isOnline
    }

    func isConnected(_ peerId: String) -> Bool {
        networkManager.isConnected(to: peerId)
    }

    // MARK: - Helpers

    private func ensureConversation(for peerId: String, displayName: String) {
        guard peerId != localDeviceId, !peerId.hasPrefix("group-") else { return }
        if conversations[peerId] == nil {
            let peer = Peer(id: peerId, displayName: displayName, isOnline: true, lastSeen: Date())
            conversations[peerId] = Conversation(id: peerId, peer: peer)
        }
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

// MARK: - Media helpers (nonisolated)

enum MediaHelper {
    struct VideoInfo {
        let width: Int?
        let height: Int?
        let duration: Double?
        let thumbnail: Data?
    }

    static func resize(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    static func videoInfo(for url: URL) -> VideoInfo {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        var width: Int?
        var height: Int?
        if let track = asset.tracks(withMediaType: .video).first {
            let size = track.naturalSize.applying(track.preferredTransform)
            width = Int(abs(size.width))
            height = Int(abs(size.height))
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        var thumb: Data?
        if let cg = try? generator.copyCGImage(at: CMTime(seconds: min(1, max(0, seconds / 2)), preferredTimescale: 600), actualTime: nil) {
            thumb = UIImage(cgImage: cg).jpegData(compressionQuality: 0.6)
        }
        return VideoInfo(width: width, height: height,
                         duration: seconds.isFinite ? seconds : nil, thumbnail: thumb)
    }
}

// MARK: - Chunked, encrypted file transfer engine (nonisolated)

/// Streams files as 64 KB AES-256-GCM chunks. The per-file key travels inside
/// the Double-Ratchet encrypted chat message, so chunks are end-to-end
/// encrypted without advancing the ratchet 1 000s of times.
final class FileTransferEngine: @unchecked Sendable {
    static let chunkSize = 64 * 1024
    static let maxInFlight = 8

    /// (messageId, progress) – main queue.
    var onProgress: ((UUID, Double) -> Void)?
    /// (messageId, peerId, success) – main queue.
    var onIncomingFinished: ((UUID, String, Bool) -> Void)?

    private let recvQueue = DispatchQueue(label: "com.securechat.transfer.recv", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled: Set<UUID> = []

    private final class Incoming {
        let id: UUID
        let peerId: String
        let key: SymmetricKey
        let total: UInt32
        let chunkSize: Int
        let handle: FileHandle
        var received = Set<UInt32>()
        var lastProgress = Date.distantPast

        init(id: UUID, peerId: String, key: SymmetricKey, total: UInt32, chunkSize: Int, handle: FileHandle) {
            self.id = id; self.peerId = peerId; self.key = key
            self.total = total; self.chunkSize = chunkSize; self.handle = handle
        }
    }

    /// recvQueue only. Keyed by "<peerId>|<transferId>".
    private var incoming: [String: Incoming] = [:]

    private func isCancelled(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled.contains(id)
    }

    func cancel(_ id: UUID) {
        lock.lock()
        cancelled.insert(id)
        lock.unlock()
        recvQueue.async {
            for (k, t) in self.incoming where t.id == id {
                try? t.handle.close()
                self.incoming.removeValue(forKey: k)
            }
        }
    }

    // MARK: Receive

    func registerIncoming(transferId: UUID, peerId: String, key: Data, total: Int, chunkSize: Int, fileURL: URL) {
        recvQueue.async {
            let k = "\(peerId)|\(transferId.uuidString)"
            if let old = self.incoming.removeValue(forKey: k) { try? old.handle.close() }
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            guard total > 0 else { return }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else {
                print("[FileTransfer] cannot open \(fileURL.lastPathComponent)")
                return
            }
            self.incoming[k] = Incoming(id: transferId, peerId: peerId, key: SymmetricKey(data: key),
                                        total: UInt32(total), chunkSize: chunkSize, handle: handle)
        }
    }

    func handleChunk(_ frame: Data, from peerId: String) {
        recvQueue.async {
            guard let chunk = FileChunkFrame.decode(frame) else { return }
            let k = "\(peerId)|\(chunk.transferId.uuidString)"
            guard let t = self.incoming[k], chunk.total == t.total, chunk.index < t.total else { return }
            if t.received.contains(chunk.index) { return }
            do {
                let box = try AES.GCM.SealedBox(combined: chunk.box)
                let aad = FileChunkFrame.aad(transferId: chunk.transferId, index: chunk.index, total: chunk.total)
                let plain = try AES.GCM.open(box, using: t.key, authenticating: aad)
                try t.handle.seek(toOffset: UInt64(chunk.index) * UInt64(t.chunkSize))
                try t.handle.write(contentsOf: plain)
            } catch {
                print("[FileTransfer] chunk \(chunk.index) failed: \(error)")
                return
            }
            t.received.insert(chunk.index)
            let done = t.received.count == Int(t.total)
            let now = Date()
            if done {
                try? t.handle.close()
                self.incoming.removeValue(forKey: k)
                let id = t.id
                DispatchQueue.main.async { self.onIncomingFinished?(id, peerId, true) }
            } else if now.timeIntervalSince(t.lastProgress) > 0.2 {
                t.lastProgress = now
                let p = Double(t.received.count) / Double(t.total)
                let id = t.id
                DispatchQueue.main.async { self.onProgress?(id, p) }
            }
        }
    }

    // MARK: Send

    func send(fileURL: URL, transferId: UUID, key: SymmetricKey, chunkCount: Int, to peerId: String,
              network: NetworkManager, completion: @escaping (Bool) -> Void) {
        lock.lock()
        cancelled.remove(transferId)
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            let finish: (Bool) -> Void = { ok in DispatchQueue.main.async { completion(ok) } }
            guard chunkCount > 0 else { finish(true); return }
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { finish(false); return }
            defer { try? handle.close() }

            let semaphore = DispatchSemaphore(value: Self.maxInFlight)
            let failLock = NSLock()
            var failed = false
            var lastProgress = Date.distantPast
            let total = UInt32(chunkCount)

            for i in 0..<chunkCount {
                failLock.lock(); let stop = failed; failLock.unlock()
                if stop || self.isCancelled(transferId) { break }
                guard let data = try? handle.read(upToCount: Self.chunkSize), !data.isEmpty else {
                    failLock.lock(); failed = true; failLock.unlock()
                    break
                }
                let index = UInt32(i)
                let aad = FileChunkFrame.aad(transferId: transferId, index: index, total: total)
                guard let sealed = try? AES.GCM.seal(data, using: key, authenticating: aad),
                      let combined = sealed.combined else {
                    failLock.lock(); failed = true; failLock.unlock()
                    break
                }
                let frame = FileChunkFrame.encode(transferId: transferId, index: index, total: total, box: combined)
                semaphore.wait()
                network.send(frame, to: peerId) { ok in
                    if !ok { failLock.lock(); failed = true; failLock.unlock() }
                    semaphore.signal()
                }
                let now = Date()
                if now.timeIntervalSince(lastProgress) > 0.2 {
                    lastProgress = now
                    let p = Double(i + 1) / Double(chunkCount)
                    DispatchQueue.main.async { self.onProgress?(transferId, p) }
                }
            }
            // Drain in-flight sends.
            for _ in 0..<Self.maxInFlight { semaphore.wait() }
            for _ in 0..<Self.maxInFlight { semaphore.signal() }
            failLock.lock(); let result = !failed && !self.isCancelled(transferId); failLock.unlock()
            finish(result)
        }
    }
}
