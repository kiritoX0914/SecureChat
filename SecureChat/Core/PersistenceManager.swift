// PersistenceManager.swift
// SecureChat – LAN End-to-End Encrypted Messenger
// Simple file-based JSON persistence (+ on-disk attachment store)

import Foundation

final class PersistenceManager: @unchecked Sendable {

    // MARK: - Private

    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "com.securechat.persistence", qos: .utility)
    private let lock = NSLock()
    private var pendingConversations: [String: Conversation]?
    private var saveScheduled = false

    private var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private var conversationsURL: URL { documentsURL.appendingPathComponent("conversations.json") }
    private var displayNameURL: URL  { documentsURL.appendingPathComponent("displayName.json") }
    private var deviceIdURL: URL     { documentsURL.appendingPathComponent("deviceId.json") }
    private var knownHostsURL: URL   { documentsURL.appendingPathComponent("knownHosts.json") }
    private var avatarURL: URL       { documentsURL.appendingPathComponent("avatar.jpg") }
    private var profileVersionURL: URL { documentsURL.appendingPathComponent("profileVersion.json") }

    // MARK: - Codable wrapper (strips transient state)

    private struct StoredConversation: Codable, Sendable {
        let peerId: String
        let peer: Peer
        let messages: [ChatMessage]
        var group: GroupInfo?
        var unreadCount: Int?
    }

    // MARK: - Conversations

    /// Debounced, off-main-thread save.
    func saveConversations(_ conversations: [String: Conversation]) {
        lock.lock()
        pendingConversations = conversations
        let alreadyScheduled = saveScheduled
        saveScheduled = true
        lock.unlock()
        guard !alreadyScheduled else { return }
        ioQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.flushConversations()
        }
    }

    /// Write any pending conversation state right now (e.g. app going to background).
    func flushNow() {
        ioQueue.sync { self.flushConversations() }
    }

    private func flushConversations() {
        lock.lock()
        let snapshot = pendingConversations
        pendingConversations = nil
        saveScheduled = false
        lock.unlock()
        guard let snapshot else { return }

        let stored = snapshot.map { (_, conv) -> StoredConversation in
            let msgs = conv.messages.map { Self.stripForStorage($0) }
            return StoredConversation(peerId: conv.id, peer: conv.peer, messages: msgs,
                                      group: conv.group, unreadCount: conv.unreadCount)
        }
        save(stored, to: conversationsURL, pretty: false)
    }

    /// Never persist file keys; keep bytes on disk instead of inline when possible.
    private static func stripForStorage(_ message: ChatMessage) -> ChatMessage {
        var m = message
        if var a = m.attachment {
            a.fileKey = nil
            if a.localFile != nil { a.data = nil }
            m.attachment = a
        }
        return m
    }

    func loadConversations() -> [String: Conversation] {
        guard let stored: [StoredConversation] = load(from: conversationsURL) else { return [:] }
        var result: [String: Conversation] = [:]
        for s in stored {
            var conversation = Conversation(id: s.peerId, peer: s.peer, messages: s.messages)
            conversation.group = s.group
            conversation.unreadCount = s.unreadCount ?? 0
            // Persisted peers start offline; they go online once re-connected
            conversation.peer.isOnline = false
            // Transfers that were interrupted by quitting are marked failed.
            conversation.messages = conversation.messages.map { msg in
                var m = msg
                if m.status == .sending { m.status = .failed }
                return m
            }
            result[s.peerId] = conversation
        }
        return result
    }

    // MARK: - Display Name / Profile

    func saveDisplayName(_ name: String) {
        save(name, to: displayNameURL)
    }

    func loadDisplayName() -> String? {
        load(from: displayNameURL)
    }

    func saveAvatar(_ data: Data?) {
        if let data {
            try? data.write(to: avatarURL, options: .atomic)
        } else {
            try? fileManager.removeItem(at: avatarURL)
        }
    }

    func loadAvatar() -> Data? {
        try? Data(contentsOf: avatarURL)
    }

    func saveProfileVersion(_ v: Int) { save(v, to: profileVersionURL) }
    func loadProfileVersion() -> Int { load(from: profileVersionURL) ?? 1 }

    // MARK: - Known hosts (auto-reconnect)

    func saveKnownHosts(_ hosts: [String]) {
        save(hosts, to: knownHostsURL)
    }

    func loadKnownHosts() -> [String] {
        load(from: knownHostsURL) ?? []
    }

    // MARK: - Device ID

    func saveDeviceId(_ id: String) {
        save(id, to: deviceIdURL)
    }

    func loadDeviceId() -> String? {
        load(from: deviceIdURL)
    }

    // MARK: - Generic helpers

    private func save<T: Encodable>(_ value: T, to url: URL, pretty: Bool = true) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if pretty { encoder.outputFormatting = .prettyPrinted }
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[PersistenceManager] Failed to save to \(url.lastPathComponent): \(error)")
        }
    }

    private func load<T: Decodable>(from url: URL) -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            print("[PersistenceManager] Failed to load from \(url.lastPathComponent): \(error)")
            return nil
        }
    }
}

// MARK: - Attachment store

/// Attachments live on disk under Application Support/SecureChat/Attachments/<messageId>/<filename>.
enum AttachmentStore {
    static var baseURL: URL {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("SecureChat", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func sanitize(_ filename: String) -> String {
        var name = filename.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "file" }
        if name.count > 120 {
            let ext = (name as NSString).pathExtension
            name = String(name.prefix(100)) + (ext.isEmpty ? "" : "." + ext)
        }
        return name
    }

    static func relativePath(messageId: UUID, filename: String) -> String {
        "\(messageId.uuidString)/\(sanitize(filename))"
    }

    static func location(_ relative: String) -> URL {
        baseURL.appendingPathComponent(relative)
    }

    /// Create the directory and return the destination URL for a message's file.
    static func prepare(messageId: UUID, filename: String) -> (relative: String, url: URL) {
        let rel = relativePath(messageId: messageId, filename: filename)
        let url = location(rel)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (rel, url)
    }

    @discardableResult
    static func write(_ data: Data, messageId: UUID, filename: String) -> String? {
        let (rel, url) = prepare(messageId: messageId, filename: filename)
        do {
            try data.write(to: url, options: .atomic)
            return rel
        } catch {
            print("[AttachmentStore] write failed: \(error)")
            return nil
        }
    }

    static func copyIn(_ source: URL, messageId: UUID, filename: String) -> String? {
        let (rel, url) = prepare(messageId: messageId, filename: filename)
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        do {
            try fm.copyItem(at: source, to: url)
            return rel
        } catch {
            print("[AttachmentStore] copy failed: \(error)")
            return nil
        }
    }

    static func delete(messageId: UUID) {
        let dir = baseURL.appendingPathComponent(messageId.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Resolve a URL with the bytes of an attachment, writing inline data to disk if needed.
    static func fileURL(for attachment: Attachment, messageId: UUID) -> URL? {
        if let rel = attachment.localFile {
            let url = location(rel)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let data = attachment.data, let rel = write(data, messageId: messageId, filename: attachment.filename) {
            return location(rel)
        }
        return nil
    }
}
