// PersistenceManager.swift
// SecureChat – LAN End-to-End Encrypted Messenger
// Simple file-based JSON persistence

import Foundation

final class PersistenceManager: Sendable {

    // MARK: - Private

    private let fileManager = FileManager.default

    private var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private var conversationsURL: URL { documentsURL.appendingPathComponent("conversations.json") }
    private var displayNameURL: URL  { documentsURL.appendingPathComponent("displayName.json") }
    private var deviceIdURL: URL     { documentsURL.appendingPathComponent("deviceId.json") }

    // MARK: - Codable wrapper (strips transient state)

    /// Lightweight wrapper for serialisation – we store only the peer info and messages.
    private struct StoredConversation: Codable, Sendable {
        let peerId: String
        let peer: Peer
        let messages: [ChatMessage]
    }

    // MARK: - Conversations

    func saveConversations(_ conversations: [String: Conversation]) {
        let stored = conversations.map { (_, conv) in
            StoredConversation(peerId: conv.id, peer: conv.peer, messages: conv.messages)
        }
        save(stored, to: conversationsURL)
    }

    func loadConversations() -> [String: Conversation] {
        guard let stored: [StoredConversation] = load(from: conversationsURL) else { return [:] }
        var result: [String: Conversation] = [:]
        for s in stored {
            var conversation = Conversation(id: s.peerId, peer: s.peer, messages: s.messages)
            // Persisted peers start offline; they go online once re-discovered
            conversation.peer.isOnline = false
            result[s.peerId] = conversation
        }
        return result
    }

    // MARK: - Display Name

    func saveDisplayName(_ name: String) {
        save(name, to: displayNameURL)
    }

    func loadDisplayName() -> String? {
        load(from: displayNameURL)
    }

    // MARK: - Device ID

    func saveDeviceId(_ id: String) {
        save(id, to: deviceIdURL)
    }

    func loadDeviceId() -> String? {
        load(from: deviceIdURL)
    }

    // MARK: - Generic helpers

    private func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
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
