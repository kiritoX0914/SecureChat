// NetworkManager.swift
// SecureChat – LAN End-to-End Encrypted Messenger
// Manages peer connections and length-prefixed message transport over TCP.
//
// v1.2: Bonjour is only one of several discovery paths. Because TrollStore
// installs cannot use multicast, every peer also
//   • remembers the IPv4 addresses of peers it has talked to and re-dials them,
//   • periodically sweeps its local /24 subnet(s) on the fixed port 47823,
//   • sends a small UDP broadcast beacon (best effort) so others dial back,
//   • heart-beats every live link and drops dead ones so the UI shows offline.

import Foundation
import Network
import Combine
import Darwin

final class NetworkManager: ObservableObject {

    // MARK: - Published State

    /// Lightweight value describing a discovered peer's display name and endpoint.
    struct PeerNetworkInfo: Sendable {
        let displayName: String
        let endpoint: NWEndpoint
    }

    /// Currently-visible peers, keyed by deviceId.
    @Published var availablePeers: [String: PeerNetworkInfo] = [:]

    /// Local IPv4 address of one up, non-loopback interface.
    struct LocalAddress: Identifiable, Equatable {
        let interface: String
        let address: String
        var id: String { "\(interface):\(address)" }
    }

    /// Preferred listener port (same as `LANDiscovery.defaultTCPPort`).
    static let defaultTCPPort: UInt16 = LANDiscovery.defaultTCPPort
    /// UDP port used by the broadcast beacon.
    static let beaconPort: UInt16 = 47824

    @Published var listeningPort: UInt16?
    @Published var localIPv4Addresses: [LocalAddress] = []
    @Published var listenerReady = false
    @Published var browserReady = false
    @Published var isLocalNetworkDenied = false
    @Published var discoveryStatus: String = "Starting…"
    @Published var lastManualConnectError: String?
    @Published var lastManualConnectSuccess: String?
    /// Human readable status of the auto-reconnect scanner.
    @Published var scanStatus: String = ""
    @Published var isScanning = false

    // MARK: - Constants

    /// Maximum incoming frame size (v1.1 peers may still send big inline files).
    static let maxPayloadLength: UInt32 = 150 * 1024 * 1024

    /// A link that sends nothing for this long is considered dead.
    static let deadLinkTimeout: TimeInterval = 25
    static let tickInterval: TimeInterval = 5

    // MARK: - Callbacks (always invoked on the main queue)

    /// Raw frame bytes from an identified peer. Parameters: (data, peerId).
    var onDataReceived: ((Data, String) -> Void)?
    /// A peer became known (name). Parameters: (peerId, displayName).
    var onPeerFound: ((String, String) -> Void)?
    /// Bonjour lost a peer.
    var onPeerLost: ((String) -> Void)?
    /// A link to the peer became the active link (send the full hello now).
    var onPeerConnected: ((String) -> Void)?
    /// The active link to a peer went away.
    var onPeerDisconnected: ((String) -> Void)?
    /// We learned an IPv4 address for a peer. Parameters: (peerId, address).
    var onPeerAddress: ((String, String) -> Void)?

    // MARK: - Private State

    private let discovery = LANDiscovery()
    private let networkQueue = DispatchQueue(label: "com.securechat.network")
    private let snapshotLock = NSLock()

    private var deviceId: String = ""
    private var displayName: String = ""

    /// First frame sent on every new link so the other side can identify us.
    /// Set by ChatManager (thread-safe via snapshotLock).
    private var identHello: Data?
    private var pingFrame: Data?

    private final class Link {
        let connection: NWConnection
        let outgoing: Bool
        let isProbe: Bool
        let isManual: Bool
        var peerId: String?
        var host: String?
        var readyAt: Date?
        var activatedAt: Date?
        var lastReceived = Date()
        var closed = false
        /// Peer sends heartbeats (v1.2+); only such links are dropped when silent.
        var sendsPings = false

        init(connection: NWConnection, outgoing: Bool, isProbe: Bool, isManual: Bool, host: String?) {
            self.connection = connection
            self.outgoing = outgoing
            self.isProbe = isProbe
            self.isManual = isManual
            self.host = host
        }
    }

    /// All links (networkQueue only).
    private var links: [ObjectIdentifier: Link] = [:]
    /// Active link per peer (networkQueue only).
    private var active: [String: ObjectIdentifier] = [:]
    /// Hosts with an in-flight probe (networkQueue only).
    private var probingHosts: Set<String> = []

    /// Thread-safe snapshots.
    private var connectedPeerSnapshot: Set<String> = []
    private var knownHosts: Set<String> = []

    private var timer: DispatchSourceTimer?
    private var tickCount = 0
    private var sweepQueue: [String] = []
    private var sweepInFlight = 0
    private var lastSweep = Date.distantPast
    private var started = false

    private var beacon: UDPBeacon?

    // MARK: - Lifecycle

    func start(deviceId: String, displayName: String) {
        self.deviceId = deviceId
        self.displayName = displayName
        guard !started else { return }
        started = true

        discovery.onPeerDiscovered = { [weak self] peerId, name, endpoint in
            self?.handlePeerDiscovered(peerId: peerId, name: name, endpoint: endpoint)
        }
        discovery.onPeerLost = { [weak self] peerId in
            DispatchQueue.main.async {
                self?.availablePeers.removeValue(forKey: peerId)
                self?.onPeerLost?(peerId)
            }
        }
        discovery.onIncomingConnection = { [weak self] connection in
            guard let self else { return }
            self.networkQueue.async { self.handleIncomingConnection(connection) }
        }
        discovery.onStatusChange = { [weak self] in
            self?.publishDiscoveryStatus()
        }

        refreshLocalAddresses()
        discovery.startAdvertising(deviceId: deviceId, displayName: displayName)
        discovery.startBrowsing(ownDeviceId: deviceId)

        let beacon = UDPBeacon(port: Self.beaconPort, deviceId: deviceId, queue: networkQueue)
        beacon.onHeard = { [weak self] host, remoteId in
            guard let self else { return }
            guard remoteId != self.deviceId else { return }
            if !self.isConnected(to: remoteId) {
                self.connect(host: host, port: Self.defaultTCPPort, probe: true, manual: false, timeout: 3)
            }
        }
        beacon.start()
        self.beacon = beacon

        startTimer()
    }

    /// Update the frames sent on every new link and as heartbeat.
    func setIdentity(helloFrame: Data?, pingFrame: Data?) {
        snapshotLock.lock()
        identHello = helloFrame
        self.pingFrame = pingFrame
        snapshotLock.unlock()
    }

    /// Addresses of peers we have talked to before (auto re-dial).
    func setKnownHosts(_ hosts: Set<String>) {
        snapshotLock.lock()
        knownHosts = hosts
        snapshotLock.unlock()
    }

    /// Called when the app returns to the foreground: restart listener /
    /// browser if iOS killed them, verify links and re-dial immediately.
    func wake() {
        discovery.ensureRunning()
        refreshLocalAddresses()
        networkQueue.async { [weak self] in
            guard let self else { return }
            // Ping every link; dead ones error out and get removed.
            let ping = self.currentPingFrame()
            for link in self.links.values where link.peerId != nil {
                if let ping { self.sendFramed(ping, on: link.connection) }
            }
            self.dialKnownHosts(jitter: false)
            self.startSweep(force: true)
        }
    }

    /// Manually trigger a re-dial + subnet sweep.
    func scanNow() {
        networkQueue.async { [weak self] in
            self?.dialKnownHosts(jitter: false)
            self?.startSweep(force: true)
        }
    }

    func refreshLocalAddresses() {
        let addresses = LANDiscovery.currentIPv4Addresses().map {
            LocalAddress(interface: $0.interface, address: $0.address)
        }
        DispatchQueue.main.async {
            self.localIPv4Addresses = addresses
        }
    }

    /// Open a TCP connection to a host:port typed by the user.
    func connectToAddress(host: String, port: UInt16) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, port > 0 else { return }
        DispatchQueue.main.async {
            self.lastManualConnectError = nil
            self.lastManualConnectSuccess = nil
        }
        connect(host: trimmed, port: port, probe: false, manual: true, timeout: 8)
    }

    func updateDisplayName(_ name: String) {
        self.displayName = name
        discovery.updateDisplayName(name)
    }

    func stop() {
        discovery.stopAll()
        timer?.cancel()
        timer = nil
        beacon?.stop()
        networkQueue.async { [weak self] in
            guard let self else { return }
            for link in self.links.values { link.connection.cancel() }
            self.links.removeAll()
            self.active.removeAll()
            self.updateSnapshot()
        }
        DispatchQueue.main.async {
            self.availablePeers.removeAll()
        }
    }

    // MARK: - Sending

    /// Send a frame to a peer's active link. `completion` (if any) is called
    /// on the network queue with `true` once the bytes were handed to TCP.
    func send(_ data: Data, to peerId: String, completion: ((Bool) -> Void)? = nil) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            guard let oid = self.active[peerId], let link = self.links[oid], !link.closed else {
                completion?(false)
                return
            }
            self.sendFramed(data, on: link.connection, completion: completion)
        }
    }

    /// Returns `true` if we hold a live, identified link for the peer.
    func isConnected(to peerId: String) -> Bool {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return connectedPeerSnapshot.contains(peerId)
    }

    var connectedPeerIds: Set<String> {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return connectedPeerSnapshot
    }

    // MARK: - Dialing

    private func connect(host: String, port: UInt16, probe: Bool, manual: Bool, timeout: Int) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            let own = Set(LANDiscovery.currentIPv4Interfaces().map(\.address))
            if own.contains(host) && !manual { return }
            if probe {
                if self.probingHosts.contains(host) { return }
                // Already have a live link to that address?
                if self.links.values.contains(where: { $0.host == host && !$0.closed && ($0.peerId != nil || $0.readyAt == nil) }) {
                    return
                }
            }
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                if manual { DispatchQueue.main.async { self.lastManualConnectError = "Invalid port" } }
                return
            }
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: nwPort,
                using: LANDiscovery.makeTCPParameters(connectTimeout: timeout)
            )
            let link = Link(connection: connection, outgoing: true, isProbe: probe, isManual: manual, host: host)
            self.register(link)
            if probe { self.probingHosts.insert(host) }

            // Hard deadline for probes that never become ready.
            if probe {
                let deadline = Double(timeout) + 0.5
                self.networkQueue.asyncAfter(deadline: .now() + deadline) { [weak self, weak link] in
                    guard let self, let link, !link.closed else { return }
                    if link.readyAt == nil { self.close(link) }
                }
            }
            connection.start(queue: self.networkQueue)
        }
    }

    private func handlePeerDiscovered(peerId: String, name: String, endpoint: NWEndpoint) {
        DispatchQueue.main.async {
            self.availablePeers[peerId] = PeerNetworkInfo(displayName: name, endpoint: endpoint)
            self.onPeerFound?(peerId, name)
        }
        networkQueue.async { [weak self] in
            guard let self else { return }
            if self.active[peerId] != nil { return }
            let connection = NWConnection(to: endpoint, using: LANDiscovery.makeTCPParameters(connectTimeout: 8))
            let link = Link(connection: connection, outgoing: true, isProbe: false, isManual: false, host: nil)
            self.register(link)
            connection.start(queue: self.networkQueue)
        }
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        let host = Self.ipv4Host(of: connection.endpoint)
        let link = Link(connection: connection, outgoing: false, isProbe: false, isManual: false, host: host)
        register(link)
        connection.start(queue: networkQueue)
        // Drop incoming links that never identify themselves.
        networkQueue.asyncAfter(deadline: .now() + 15) { [weak self, weak link] in
            guard let self, let link, !link.closed else { return }
            if link.peerId == nil { self.close(link) }
        }
    }

    // MARK: - Link state machine (networkQueue)

    private func register(_ link: Link) {
        let oid = ObjectIdentifier(link.connection)
        links[oid] = link
        link.connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link else { return }
            self.handleState(state, link: link)
        }
    }

    private func handleState(_ state: NWConnection.State, link: Link) {
        switch state {
        case .ready:
            link.readyAt = Date()
            link.lastReceived = Date()
            if link.host == nil, let remote = link.connection.currentPath?.remoteEndpoint {
                link.host = Self.ipv4Host(of: remote)
            }
            if let hello = currentHelloFrame() {
                sendFramed(hello, on: link.connection)
            }
            receiveLoop(link)
            if link.isProbe {
                // A real SecureChat peer answers with its hello right away.
                networkQueue.asyncAfter(deadline: .now() + 6) { [weak self, weak link] in
                    guard let self, let link, !link.closed else { return }
                    if link.peerId == nil { self.close(link) }
                }
            }

        case .waiting(let error):
            if link.isManual {
                DispatchQueue.main.async { self.lastManualConnectError = error.localizedDescription }
            }
            // Refused / unreachable – don't let Network.framework retry forever.
            if link.isProbe || link.isManual {
                close(link)
            }

        case .failed(let error):
            if link.isManual {
                DispatchQueue.main.async { self.lastManualConnectError = error.localizedDescription }
            }
            close(link)

        case .cancelled:
            close(link)

        default:
            break
        }
    }

    private func close(_ link: Link) {
        guard !link.closed else { return }
        link.closed = true
        let oid = ObjectIdentifier(link.connection)
        links.removeValue(forKey: oid)
        if let host = link.host, link.isProbe { probingHosts.remove(host) }
        link.connection.stateUpdateHandler = nil
        link.connection.cancel()

        if sweepMembers.remove(oid) != nil {
            sweepInFlight = max(0, sweepInFlight - 1)
            pumpSweep()
        }

        if let peerId = link.peerId, active[peerId] == oid {
            active.removeValue(forKey: peerId)
            updateSnapshot()
            DispatchQueue.main.async {
                self.onPeerDisconnected?(peerId)
            }
        }
    }

    /// First envelope on a link tells us who is on the other end.
    private func identify(_ link: Link, peerId: String, name: String) {
        let oid = ObjectIdentifier(link.connection)
        if link.isProbe, let host = link.host { probingHosts.remove(host) }
        if sweepMembers.remove(oid) != nil {
            sweepInFlight = max(0, sweepInFlight - 1)
            pumpSweep()
        }

        if peerId == deviceId {
            // We dialed ourselves (own address on another interface).
            close(link)
            return
        }
        link.peerId = peerId

        let now = Date()
        if let existingOid = active[peerId], existingOid != oid, let existing = links[existingOid] {
            let existingFresh = now.timeIntervalSince(existing.activatedAt ?? .distantPast) < 3
            var keepNew = true
            if existingFresh {
                // Simultaneous dial: both sides must keep the same TCP link.
                // Rule: the link initiated by the smaller deviceId wins.
                let winner = min(deviceId, peerId)
                let newInitiator = link.outgoing ? deviceId : peerId
                let oldInitiator = existing.outgoing ? deviceId : peerId
                if newInitiator != oldInitiator {
                    keepNew = (newInitiator == winner)
                }
            }
            if keepNew {
                print("[NetworkManager] Replacing link for \(peerId)")
                active[peerId] = oid
                existing.peerId = nil   // so close() does not report a disconnect
                close(existing)
            } else {
                print("[NetworkManager] Keeping existing link for \(peerId), dropping new one")
                link.peerId = nil
                close(link)
                return
            }
        } else {
            active[peerId] = oid
        }
        link.activatedAt = now
        updateSnapshot()

        let host = link.host
        let manual = link.isManual
        DispatchQueue.main.async {
            self.availablePeers[peerId] = PeerNetworkInfo(displayName: name, endpoint: link.connection.endpoint)
            self.onPeerFound?(peerId, name)
            if let host { self.onPeerAddress?(peerId, host) }
            self.onPeerConnected?(peerId)
            if manual {
                self.lastManualConnectError = nil
                self.lastManualConnectSuccess = "Connected to \(name)"
            }
        }
    }

    private func updateSnapshot() {
        let set = Set(active.keys)
        snapshotLock.lock()
        connectedPeerSnapshot = set
        snapshotLock.unlock()
    }

    private func currentHelloFrame() -> Data? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return identHello
    }

    private func currentPingFrame() -> Data? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return pingFrame
    }

    // MARK: - Receive Loop

    private func receiveLoop(_ link: Link) {
        let connection = link.connection
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak link] data, _, isComplete, error in
            guard let self, let link, !link.closed else { return }
            if let error {
                print("[NetworkManager] Receive header error: \(error)")
                self.close(link)
                return
            }
            guard let lengthData = data, lengthData.count == 4 else {
                if isComplete { self.close(link) }
                return
            }
            let b = [UInt8](lengthData)
            let payloadLength = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
            guard payloadLength > 0, payloadLength <= Self.maxPayloadLength else {
                print("[NetworkManager] Invalid payload length: \(payloadLength)")
                self.close(link)
                return
            }
            let len = Int(payloadLength)
            connection.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self, weak link] payload, _, isComplete, error in
                guard let self, let link, !link.closed else { return }
                if let error {
                    print("[NetworkManager] Receive payload error: \(error)")
                    self.close(link)
                    return
                }
                guard let payload, payload.count == len else {
                    print("[NetworkManager] Short payload / closed")
                    self.close(link)
                    return
                }
                self.handleFrame(payload, on: link)
                if !link.closed && !isComplete {
                    self.receiveLoop(link)
                } else if isComplete {
                    self.close(link)
                }
            }
        }
    }

    private func handleFrame(_ data: Data, on link: Link) {
        link.lastReceived = Date()
        if !link.sendsPings, data.count < 512, data.first == UInt8(ascii: "{"),
           let text = String(data: data, encoding: .utf8), text.contains("\"type\":7") {
            link.sendsPings = true
        }

        if let peerId = link.peerId {
            DispatchQueue.main.async {
                self.onDataReceived?(data, peerId)
            }
            return
        }

        // Unidentified link – the first frame must be a JSON envelope.
        guard data.first == UInt8(ascii: "{"),
              let envelope = try? JSONDecoder().decode(WireEnvelope.self, from: data) else {
            print("[NetworkManager] Unidentified link sent a non-envelope frame; closing")
            close(link)
            return
        }
        identify(link, peerId: envelope.senderId, name: envelope.senderName)
        if let peerId = link.peerId, !link.closed {
            DispatchQueue.main.async {
                self.onDataReceived?(data, peerId)
            }
        }
    }

    // MARK: - Framing

    private func sendFramed(_ data: Data, on connection: NWConnection, completion: ((Bool) -> Void)? = nil) {
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(data)
        connection.send(content: frame, completion: .contentProcessed { error in
            if let error {
                print("[NetworkManager] Send error: \(error)")
            }
            completion?(error == nil)
        })
    }

    // MARK: - Heartbeat / auto reconnect (networkQueue)

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: networkQueue)
        t.schedule(deadline: .now() + 1.5, repeating: Self.tickInterval, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        tickCount += 1
        let now = Date()

        // 1. Heartbeat + dead link detection.
        let ping = currentPingFrame()
        for link in Array(links.values) where !link.closed && link.peerId != nil {
            if link.sendsPings && now.timeIntervalSince(link.lastReceived) > Self.deadLinkTimeout {
                print("[NetworkManager] Link to \(link.peerId ?? "?") silent for \(Int(now.timeIntervalSince(link.lastReceived)))s – dropping")
                close(link)
                continue
            }
            if let ping { sendFramed(ping, on: link.connection) }
        }

        // 2. Re-dial known addresses of peers that are not connected.
        dialKnownHosts(jitter: true)

        // 3. Subnet sweep: every 15 s while nobody is online, else every 60 s.
        let interval: TimeInterval = active.isEmpty ? 15 : 60
        if now.timeIntervalSince(lastSweep) >= interval {
            startSweep(force: false)
        }

        // 4. UDP beacon (best effort).
        beacon?.announce()
    }

    private func dialKnownHosts(jitter: Bool) {
        snapshotLock.lock()
        let hosts = knownHosts
        snapshotLock.unlock()
        let connectedHosts = Set(links.values.compactMap { $0.peerId != nil ? $0.host : nil })
        for host in hosts where !connectedHosts.contains(host) && !probingHosts.contains(host) {
            let delay = jitter ? Double.random(in: 0...1.5) : 0
            networkQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.connect(host: host, port: Self.defaultTCPPort, probe: true, manual: false, timeout: 3)
            }
        }
    }

    private var sweepMembers: Set<ObjectIdentifier> = []
    private static let sweepConcurrency = 24

    private func startSweep(force: Bool) {
        if !force && !sweepQueue.isEmpty { return }
        lastSweep = Date()
        let interfaces = LANDiscovery.currentIPv4Interfaces().filter { Self.isScannableInterface($0.interface) }
        let own = Set(LANDiscovery.currentIPv4Interfaces().map(\.addressValue))
        let connectedHosts = Set(links.values.compactMap { $0.peerId != nil ? $0.host : nil })

        var targets: [String] = []
        var seen = Set<String>()
        for iface in interfaces {
            var mask = iface.netmaskValue
            // Cap large subnets to the /24 we live in.
            if mask < 0xFFFF_FF00 { mask = 0xFFFF_FF00 }
            let network = iface.addressValue & mask
            let broadcast = network | ~mask
            guard broadcast > network + 1 else { continue }
            var host = network + 1
            while host < broadcast {
                if !own.contains(host) {
                    let text = Self.ipv4String(host)
                    if !connectedHosts.contains(text) && !seen.contains(text) {
                        seen.insert(text)
                        targets.append(text)
                    }
                }
                host += 1
            }
        }
        guard !targets.isEmpty else {
            publishScan(running: false, text: "No scannable network")
            return
        }
        sweepQueue = targets
        publishScan(running: true, text: "Scanning \(targets.count) addresses…")
        pumpSweep()
    }

    private func pumpSweep() {
        while sweepInFlight < Self.sweepConcurrency, !sweepQueue.isEmpty {
            let host = sweepQueue.removeFirst()
            if probingHosts.contains(host) { continue }
            guard let port = NWEndpoint.Port(rawValue: Self.defaultTCPPort) else { return }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port,
                                          using: LANDiscovery.makeTCPParameters(connectTimeout: 2))
            let link = Link(connection: connection, outgoing: true, isProbe: true, isManual: false, host: host)
            register(link)
            probingHosts.insert(host)
            let oid = ObjectIdentifier(connection)
            sweepMembers.insert(oid)
            sweepInFlight += 1
            networkQueue.asyncAfter(deadline: .now() + 2.5) { [weak self, weak link] in
                guard let self, let link, !link.closed else { return }
                if link.readyAt == nil { self.close(link) }
            }
            connection.start(queue: networkQueue)
        }
        if sweepQueue.isEmpty && sweepInFlight == 0 {
            let n = active.count
            publishScan(running: false, text: n > 0 ? "\(n) peer(s) connected" : "No peers found yet – retrying")
        }
    }

    private func publishScan(running: Bool, text: String) {
        DispatchQueue.main.async {
            self.isScanning = running
            self.scanStatus = text
        }
    }

    private static func isScannableInterface(_ name: String) -> Bool {
        // Wi-Fi / Ethernet / Internet Sharing bridges / personal hotspot.
        return name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("ap") || name.hasPrefix("eth")
    }

    static func ipv4String(_ v: UInt32) -> String {
        "\((v >> 24) & 0xFF).\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)"
    }

    /// Extract a dotted IPv4 string from an endpoint (handles IPv4-mapped IPv6).
    static func ipv4Host(of endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let addr):
            let b = [UInt8](addr.rawValue)
            guard b.count == 4 else { return nil }
            return "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
        case .ipv6(let addr):
            let b = [UInt8](addr.rawValue)
            guard b.count == 16, b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF else { return nil }
            return "\(b[12]).\(b[13]).\(b[14]).\(b[15])"
        case .name(let name, _):
            let parts = name.split(separator: ".")
            if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) { return name }
            return nil
        @unknown default:
            return nil
        }
    }

    // MARK: - Discovery Status

    private func publishDiscoveryStatus() {
        let port = discovery.listeningPort
        let listenerPhase = discovery.listenerPhase
        let browserPhase = discovery.browserPhase
        let denied = discovery.isLocalNetworkDenied
        let addresses = LANDiscovery.currentIPv4Addresses().map {
            LocalAddress(interface: $0.interface, address: $0.address)
        }

        let status: String
        if denied {
            status = "Bonjour blocked · direct scan active"
        } else {
            var parts: [String] = []
            parts.append(Self.phrase(for: listenerPhase, role: "Listener"))
            parts.append(Self.phrase(for: browserPhase, role: "Browser"))
            if let port {
                parts.append("port \(port)")
            }
            status = parts.joined(separator: " · ")
        }

        DispatchQueue.main.async {
            self.listeningPort = port
            self.localIPv4Addresses = addresses
            self.listenerReady = (listenerPhase == .ready)
            self.browserReady = (browserPhase == .ready)
            self.isLocalNetworkDenied = denied
            self.discoveryStatus = status
        }
    }

    private static func phrase(for phase: LANDiscovery.Phase, role: String) -> String {
        switch phase {
        case .stopped: return "\(role) stopped"
        case .starting: return "\(role) starting"
        case .ready: return "\(role) ready"
        case .waiting(let msg): return "\(role) waiting (\(msg))"
        case .failed(let msg): return "\(role) failed (\(msg))"
        case .permissionDenied: return "\(role) blocked"
        }
    }
}

// MARK: - UDP broadcast beacon (best effort)

/// Sends "SCv2|<deviceId>" to the subnet broadcast address of every LAN
/// interface and listens for other peers' beacons. Whoever hears a beacon
/// dials the sender over TCP. Works on macOS; on iOS it only works if the
/// system lets the app broadcast (TrollStore installs may be blocked), in
/// which case the TCP subnet sweep still finds peers.
final class UDPBeacon {
    var onHeard: ((String, String) -> Void)?

    private let port: UInt16
    private let deviceId: String
    private let queue: DispatchQueue
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    init(port: UInt16, deviceId: String, queue: DispatchQueue) {
        self.port = port
        self.deviceId = deviceId
        self.queue = queue
    }

    func start() {
        let s = socket(AF_INET, SOCK_DGRAM, Int32(IPPROTO_UDP))
        guard s >= 0 else { print("[UDPBeacon] socket() failed"); return }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 {
            print("[UDPBeacon] bind failed: \(errno)")
            Darwin.close(s)
            return
        }
        fd = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { Darwin.close(s) }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
        fd = -1
    }

    func announce() {
        guard fd >= 0 else { return }
        let message = Array("SCv2|\(deviceId)".utf8)
        var targets: [UInt32] = [0xFFFF_FFFF]
        for iface in LANDiscovery.currentIPv4Interfaces() {
            let n = iface.interface
            guard n.hasPrefix("en") || n.hasPrefix("bridge") || n.hasPrefix("ap") else { continue }
            let bcast = (iface.addressValue & iface.netmaskValue) | ~iface.netmaskValue
            targets.append(bcast)
        }
        for target in Set(targets) {
            var dest = sockaddr_in()
            dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            dest.sin_family = sa_family_t(AF_INET)
            dest.sin_port = port.bigEndian
            dest.sin_addr = in_addr(s_addr: target.bigEndian)
            _ = message.withUnsafeBytes { buf in
                withUnsafePointer(to: &dest) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buffer.withUnsafeMutableBytes { buf in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, buf.baseAddress, buf.count, 0, $0, &fromLen)
                    }
                }
            }
            if n <= 0 { return }
            guard let text = String(bytes: buffer[0..<n], encoding: .utf8), text.hasPrefix("SCv2|") else { continue }
            let remoteId = String(text.dropFirst(5))
            let ip = UInt32(bigEndian: from.sin_addr.s_addr)
            let host = NetworkManager.ipv4String(ip)
            onHeard?(host, remoteId)
        }
    }
}
