// NetworkManager.swift
// SecureChat – LAN End-to-End Encrypted Messenger
// Manages peer connections and length-prefixed message transport over TCP

import Foundation
import Network
import Combine

/// Central networking hub that owns the `LANDiscovery` layer and manages
/// per-peer TCP connections with length-prefixed JSON framing.
///
/// ## Threading Model
/// All networking work runs on a dedicated serial queue (`networkQueue`).
/// Published properties are updated on `DispatchQueue.main` so SwiftUI
/// views can bind to them directly.
final class NetworkManager: ObservableObject {

    // MARK: - Published State

    /// Currently-visible peers on the LAN, keyed by deviceId.
    @Published var availablePeers: [String: PeerNetworkInfo] = [:]

    /// Lightweight value describing a discovered peer's display name and endpoint.
    struct PeerNetworkInfo: Sendable {
        let displayName: String
        let endpoint: NWEndpoint
    }

    // MARK: - Constants

    /// Maximum incoming payload size: supports 50 MB files + Base64 expansion + envelope metadata.
    static let maxPayloadLength: UInt32 = 150 * 1024 * 1024 // 150 MB

    // MARK: - Callbacks

    /// Called when raw JSON payload bytes arrive from a connected peer.
    /// Parameters: (rawJSONData, fromPeerId).
    var onDataReceived: ((Data, String) -> Void)?

    /// Called when a peer is discovered on the LAN. Parameters: (peerId, displayName).
    var onPeerFound: ((String, String) -> Void)?

    /// Called when a peer disappears from the LAN. Parameter: peerId.
    var onPeerLost: ((String) -> Void)?

    /// Called when a TCP connection to a peer reaches the `.ready` state.
    var onPeerConnected: ((String) -> Void)?

    /// Called when a TCP connection to a peer is disconnected or cleaned up. Parameter: peerId.
    var onPeerDisconnected: ((String) -> Void)?

    // MARK: - Private State

    private let discovery = LANDiscovery()
    private let networkQueue = DispatchQueue(label: "com.securechat.network")
    private let stateLock = NSRecursiveLock()

    /// Our own device identity, set once via `start(deviceId:displayName:)`.
    private var deviceId: String = ""
    private var displayName: String = ""

    /// Active TCP connections indexed by peer deviceId.
    private var connections: [String: NWConnection] = [:]

    /// Connections accepted from the listener whose peer identity is not yet
    /// known. The first received `WireEnvelope` tells us the senderId.
    private var pendingIncoming: Set<ObjectIdentifier> = []

    /// Reverse lookup so we can map an `NWConnection` back to its peerId
    /// when we need to clean up on failure/cancel.
    private var connectionToPeer: [ObjectIdentifier: String] = [:]

    // MARK: - Lifecycle

    /// Start advertising our presence and browsing for peers.
    ///
    /// - Parameters:
    ///   - deviceId: Our unique device UUID.
    ///   - displayName: The user's chosen display name.
    func start(deviceId: String, displayName: String) {
        self.deviceId = deviceId
        self.displayName = displayName

        // Wire up discovery callbacks.
        discovery.onPeerDiscovered = { [weak self] peerId, name, endpoint in
            self?.handlePeerDiscovered(peerId: peerId, name: name, endpoint: endpoint)
        }

        discovery.onPeerLost = { [weak self] peerId in
            self?.handlePeerLost(peerId: peerId)
        }

        discovery.onIncomingConnection = { [weak self] connection in
            self?.handleIncomingConnection(connection)
        }

        discovery.startAdvertising(deviceId: deviceId, displayName: displayName)
        discovery.startBrowsing(ownDeviceId: deviceId)
    }

    /// Update the advertised display name on Bonjour.
    func updateDisplayName(_ name: String) {
        self.displayName = name
        discovery.updateDisplayName(name)
    }

    /// Tear down all connections and stop discovery.
    func stop() {
        discovery.stopAll()

        stateLock.lock()
        for (_, connection) in connections {
            connection.cancel()
        }
        connections.removeAll()
        connectionToPeer.removeAll()
        pendingIncoming.removeAll()
        stateLock.unlock()

        DispatchQueue.main.async {
            self.availablePeers.removeAll()
        }
    }

    // MARK: - Sending

    /// Send raw data (already JSON-encoded) to a connected peer, framed with
    /// a 4-byte big-endian length header.
    ///
    /// - Parameters:
    ///   - data: The JSON payload bytes to send.
    ///   - peerId: The destination peer's deviceId.
    func send(_ data: Data, to peerId: String) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let connection = self.connections[peerId]
            self.stateLock.unlock()
            guard let connection else {
                print("[NetworkManager] Cannot send – no connection to \(peerId)")
                return
            }
            self.sendFramed(data, on: connection)
        }
    }

    /// Returns `true` if we hold a live connection for the given peer.
    func isConnected(to peerId: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connections[peerId] != nil
    }

    // MARK: - Discovery Handling

    private func handlePeerDiscovered(peerId: String, name: String, endpoint: NWEndpoint) {
        DispatchQueue.main.async {
            self.availablePeers[peerId] = PeerNetworkInfo(displayName: name, endpoint: endpoint)
            self.onPeerFound?(peerId, name)
        }

        // Initiate an outgoing connection if we don't already have one.
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let hasConnection = self.connections[peerId] != nil
            self.stateLock.unlock()
            if !hasConnection {
                self.connectToPeer(peerId: peerId, endpoint: endpoint)
            }
        }
    }

    private func handlePeerLost(peerId: String) {
        networkQueue.async { [weak self] in
            self?.removeConnection(for: peerId)
        }

        DispatchQueue.main.async {
            self.availablePeers.removeValue(forKey: peerId)
            self.onPeerLost?(peerId)
        }
    }

    // MARK: - Outgoing Connections

    /// Open a TCP connection to a discovered peer's endpoint.
    private func connectToPeer(peerId: String, endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let connId = ObjectIdentifier(connection)
        stateLock.lock()
        connectionToPeer[connId] = peerId
        stateLock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionStateChange(state, peerId: peerId, connection: connection)
        }

        connection.start(queue: networkQueue)
    }

    // MARK: - Incoming Connections

    /// Accept an incoming connection from the NWListener. The remote peer's
    /// identity is unknown until we receive the first `WireEnvelope`.
    private func handleIncomingConnection(_ connection: NWConnection) {
        let connId = ObjectIdentifier(connection)
        stateLock.lock()
        pendingIncoming.insert(connId)
        stateLock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[NetworkManager] Incoming connection ready (pending identification)")
                // Start receive loop with nil peerId; the first message will identify the peer.
                self?.receiveLoop(on: connection, peerId: nil)

            case .failed(let error):
                print("[NetworkManager] Incoming connection failed: \(error)")
                self?.cleanupConnection(connection)

            case .cancelled:
                self?.cleanupConnection(connection)

            default:
                break
            }
        }

        connection.start(queue: networkQueue)
    }

    // MARK: - Connection State Machine

    private func handleConnectionStateChange(
        _ state: NWConnection.State,
        peerId: String,
        connection: NWConnection
    ) {
        switch state {
        case .ready:
            print("[NetworkManager] Connected to \(peerId)")
            stateLock.lock()
            if let existing = connections[peerId], existing !== connection {
                if deviceId < peerId {
                    // We have smaller ID: prefer our outgoing connection
                    print("[NetworkManager] Keeping outgoing connection to \(peerId), cancelling prior")
                    existing.cancel()
                    connections[peerId] = connection
                    stateLock.unlock()
                } else {
                    // Remote has smaller ID: prefer their incoming connection
                    print("[NetworkManager] Keeping incoming connection from \(peerId), dropping outgoing")
                    stateLock.unlock()
                    connection.cancel()
                    return
                }
            } else {
                connections[peerId] = connection
                stateLock.unlock()
            }
            receiveLoop(on: connection, peerId: peerId)

            DispatchQueue.main.async {
                self.onPeerConnected?(peerId)
            }

        case .failed(let error):
            print("[NetworkManager] Connection to \(peerId) failed: \(error)")
            removeConnection(for: peerId)

        case .cancelled:
            print("[NetworkManager] Connection to \(peerId) cancelled")
            removeConnection(for: peerId)

        case .waiting(let error):
            print("[NetworkManager] Connection to \(peerId) waiting: \(error)")

        default:
            break
        }
    }

    // MARK: - Receive Loop (Length-Prefixed Framing & Chunked Accumulation)

    /// Continuously read length-prefixed messages from a connection.
    ///
    /// The framing protocol is:
    /// ```
    /// [4 bytes – big-endian UInt32 payload length][N bytes – JSON payload]
    /// ```
    ///
    /// - Parameters:
    ///   - connection: The TCP connection to read from.
    ///   - peerId: The peer's deviceId, or `nil` for incoming connections whose
    ///     identity hasn't been established yet.
    private func receiveLoop(on connection: NWConnection, peerId: String?) {
        // Step 1: Read the 4-byte length header.
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                print("[NetworkManager] Receive header error: \(error)")
                self.cleanupConnection(connection)
                return
            }

            guard let lengthData = data, lengthData.count == 4 else {
                if isComplete {
                    // Connection closed gracefully by the remote end.
                    print("[NetworkManager] Connection closed by remote")
                    self.cleanupConnection(connection)
                }
                return
            }

            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }
            let payloadLength = UInt32(bigEndian: length)

            guard payloadLength > 0, payloadLength <= Self.maxPayloadLength else {
                // Reject payloads exceeding maximum allowed size
                print("[NetworkManager] Invalid payload length: \(payloadLength) (max: \(Self.maxPayloadLength))")
                self.cleanupConnection(connection)
                return
            }

            // Step 2: Read the payload using chunked accumulation.
            self.receivePayload(ofLength: Int(payloadLength), on: connection) { [weak self] payload in
                guard let self, let payload else {
                    self?.cleanupConnection(connection)
                    return
                }

                // Step 3: Process the payload and continue the loop.
                self.handleReceivedData(payload, from: peerId, on: connection)
                self.receiveLoop(on: connection, peerId: peerId)
            }
        }
    }

    /// Accumulate payload bytes in chunks (up to 64 KB) to support large payloads without socket buffer truncation.
    private func receivePayload(
        ofLength length: Int,
        accumulating: Data = Data(),
        on connection: NWConnection,
        completion: @escaping (Data?) -> Void
    ) {
        let remaining = length - accumulating.count
        let chunkSize = min(remaining, 65536)
        connection.receive(minimumIncompleteLength: 1, maximumLength: chunkSize) { [weak self] data, _, isComplete, error in
            if let error {
                print("[NetworkManager] Receive chunk error: \(error)")
                completion(nil)
                return
            }
            guard let chunk = data, !chunk.isEmpty else {
                if isComplete {
                    completion(nil)
                }
                return
            }
            var buffer = accumulating
            buffer.append(chunk)
            if buffer.count == length {
                completion(buffer)
            } else if buffer.count < length {
                if isComplete {
                    print("[NetworkManager] Connection closed before full payload received (\(buffer.count)/\(length))")
                    completion(nil)
                } else {
                    self?.receivePayload(ofLength: length, accumulating: buffer, on: connection, completion: completion)
                }
            } else {
                print("[NetworkManager] Received excess data (\(buffer.count) > \(length))")
                completion(nil)
            }
        }
    }

    // MARK: - Message Handling

    /// Process a received JSON payload. For pending incoming connections the
    /// first message is used to establish the peer's identity (via `WireEnvelope.senderId`).
    ///
    /// After the first message identifies the peer, subsequent calls with `peerId == nil`
    /// resolve the identity via the `connectionToPeer` map, avoiding repeated envelope decoding.
    private func handleReceivedData(_ data: Data, from peerId: String?, on connection: NWConnection) {
        // Fast path: peerId already known by the receive loop.
        if let peerId {
            DispatchQueue.main.async {
                self.onDataReceived?(data, peerId)
            }
            return
        }

        // The receive loop was started with peerId=nil (incoming connection).
        // Check if we've already identified this connection from a prior message.
        let connId = ObjectIdentifier(connection)
        stateLock.lock()
        let resolvedPeerId = connectionToPeer[connId]
        stateLock.unlock()
        if let resolvedPeerId {
            DispatchQueue.main.async {
                self.onDataReceived?(data, resolvedPeerId)
            }
            return
        }

        // First message on an unidentified incoming connection – extract senderId.
        guard let envelope = try? JSONDecoder().decode(WireEnvelope.self, from: data) else {
            print("[NetworkManager] Failed to decode WireEnvelope from incoming connection")
            connection.cancel()
            return
        }

        let remotePeerId = envelope.senderId

        stateLock.lock()
        pendingIncoming.remove(connId)

        // Duplicate-connection resolution: when both sides connect simultaneously,
        // the peer with the lexicographically *smaller* deviceId keeps the connection
        // it *initiated* (the outgoing one). The other side keeps its incoming.
        if let existing = connections[remotePeerId] {
            if deviceId < remotePeerId {
                // We have the smaller ID → keep our outgoing, drop this incoming.
                print("[NetworkManager] Dropping duplicate incoming from \(remotePeerId) (we keep outgoing)")
                stateLock.unlock()
                connection.cancel()
                return
            } else {
                // They have the smaller ID → they keep their outgoing (our incoming).
                print("[NetworkManager] Replacing outgoing with incoming for \(remotePeerId)")
                existing.cancel()
            }
        }

        // Register the connection.
        connections[remotePeerId] = connection
        connectionToPeer[connId] = remotePeerId
        stateLock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionStateChange(state, peerId: remotePeerId, connection: connection)
        }

        print("[NetworkManager] Identified incoming peer: \(remotePeerId)")

        DispatchQueue.main.async {
            self.onPeerConnected?(remotePeerId)
            self.onDataReceived?(data, remotePeerId)
        }

        // The calling receiveLoop continues with peerId=nil. Subsequent messages
        // will hit the `connectionToPeer` lookup above and be routed correctly
        // without needing to re-decode the envelope for identity.
    }

    // MARK: - Framing

    /// Send data on a connection with a 4-byte big-endian length prefix.
    private func sendFramed(_ data: Data, on connection: NWConnection) {
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(data)

        connection.send(content: frame, completion: .contentProcessed { error in
            if let error {
                print("[NetworkManager] Send error: \(error)")
            }
        })
    }

    // MARK: - Connection Cleanup

    /// Remove a known peer's connection and notify the caller.
    private func removeConnection(for peerId: String) {
        stateLock.lock()
        let connection = connections.removeValue(forKey: peerId)
        if let connection {
            let connId = ObjectIdentifier(connection)
            connectionToPeer.removeValue(forKey: connId)
        }
        stateLock.unlock()

        if let connection {
            connection.cancel()
            DispatchQueue.main.async {
                self.onPeerDisconnected?(peerId)
            }
        }
    }

    /// Clean up a connection identified only by its object identity (used for
    /// pending incoming connections whose peerId may not be known yet).
    private func cleanupConnection(_ connection: NWConnection) {
        let connId = ObjectIdentifier(connection)
        stateLock.lock()
        pendingIncoming.remove(connId)
        let peerId = connectionToPeer.removeValue(forKey: connId)
        if let peerId {
            connections.removeValue(forKey: peerId)
        }
        stateLock.unlock()

        connection.cancel()
        if let peerId {
            DispatchQueue.main.async {
                self.onPeerDisconnected?(peerId)
            }
        }
    }
}
