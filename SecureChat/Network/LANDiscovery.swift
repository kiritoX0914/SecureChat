// LANDiscovery.swift
// SecureChat – LAN End-to-End Encrypted Messenger
// Bonjour/mDNS peer discovery using Network.framework

import Foundation
import Network
import Darwin

/// Handles advertising our presence and discovering peers on the local network
/// via Bonjour (mDNS/DNS-SD) using `NWListener` and `NWBrowser`.
final class LANDiscovery {

    // MARK: - Constants

    /// The Bonjour service type used for peer discovery.
    static let serviceType = "_securechat._tcp"

    /// Preferred TCP port for the listener so peers can connect by IP without
    /// needing Bonjour. Falls back to a system-assigned port if this is busy.
    static let defaultTCPPort: UInt16 = 47823

    // mDNS / DNS-SD error codes from dns_sd.h
    private static let dnsPolicyDenied: Int32 = -65570 // kDNSServiceErr_PolicyDenied
    private static let dnsNoAuth: Int32 = -65555       // kDNSServiceErr_NoAuth

    // MARK: - Status

    enum Phase: Equatable {
        case stopped
        case starting
        case ready
        case waiting(String)
        case failed(String)
        case permissionDenied
    }

    struct LocalAddress: Equatable {
        let interface: String
        let address: String
    }

    // MARK: - Callbacks

    /// Called when a new peer is discovered. Parameters: (deviceId, displayName, endpoint).
    var onPeerDiscovered: ((String, String, NWEndpoint) -> Void)?

    /// Called when a previously-discovered peer disappears. Parameter: deviceId.
    var onPeerLost: ((String) -> Void)?

    /// Called when the listener accepts an incoming TCP connection.
    var onIncomingConnection: ((NWConnection) -> Void)?

    /// Called on the discovery queue whenever listener or browser status changes.
    var onStatusChange: (() -> Void)?

    // MARK: - Public Read-Only State

    /// The TCP port our listener is bound to, available once the listener is `.ready`.
    private(set) var listeningPort: UInt16?

    private(set) var listenerPhase: Phase = .stopped
    private(set) var browserPhase: Phase = .stopped
    private(set) var isLocalNetworkDenied = false

    // MARK: - Private State

    private var listener: NWListener?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.securechat.discovery")

    /// Our own device ID, stored so the browser can filter self-advertisements.
    private var ownDeviceId: String?

    /// Current advertising identity, kept so we can rebuild the TXT record on updates.
    private var advertisedDeviceId: String?
    private var advertisedDisplayName: String?

    /// Tracks discovered peers by their `NWBrowser.Result` hash, mapping to the
    /// extracted deviceId so we can emit `onPeerLost` with the correct id.
    private var discoveredPeers: [NWBrowser.Result: String] = [:]
    private let lock = NSLock()

    /// `true` while we are still trying to bind the preferred fixed port.
    private var preferFixedPort = true

    // MARK: - TCP Parameters

    /// Shared TCP parameters used by the listener, browser, and connections.
    /// `includePeerToPeer` lets Network.framework also try AWDL / peer-to-peer
    /// interfaces, which can help when devices aren't on the same L2 broadcast
    /// domain (for example some Internet Sharing setups).
    static func makeTCPParameters(connectTimeout: Int? = nil) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // Detect dead peers (phone locked / app suspended / cable pulled) quickly.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        if let connectTimeout {
            tcp.connectionTimeout = connectTimeout
        }
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    /// Restart the listener / browser if iOS tore them down while the app was
    /// suspended. Safe to call repeatedly.
    func ensureRunning() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.listenerPhase != .ready && self.listenerPhase != .starting,
               let id = self.advertisedDeviceId, let name = self.advertisedDisplayName {
                print("[LANDiscovery] Restarting listener (phase: \(self.listenerPhase))")
                self.startAdvertising(deviceId: id, displayName: name, preferFixedPort: true)
            }
            if self.browserPhase != .ready && self.browserPhase != .starting,
               let own = self.ownDeviceId {
                print("[LANDiscovery] Restarting browser")
                self.startBrowsing(ownDeviceId: own)
            }
        }
    }

    /// One IPv4 interface with its netmask, used for subnet scanning.
    struct IPv4Interface: Equatable {
        let interface: String
        let address: String
        let addressValue: UInt32   // host byte order
        let netmaskValue: UInt32   // host byte order
    }

    /// Enumerate up, non-loopback IPv4 interfaces with their netmask.
    static func currentIPv4Interfaces() -> [IPv4Interface] {
        var result: [IPv4Interface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(first) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = ptr {
            defer { ptr = iface.pointee.ifa_next }
            let flags = Int32(iface.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = iface.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard let maskPtr = iface.pointee.ifa_netmask else { continue }

            let addrValue: UInt32 = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let maskValue: UInt32 = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let name = String(cString: iface.pointee.ifa_name)
            let text = "\((addrValue >> 24) & 0xFF).\((addrValue >> 16) & 0xFF).\((addrValue >> 8) & 0xFF).\(addrValue & 0xFF)"
            guard addrValue != 0, (addrValue >> 24) != 127 else { continue }
            result.append(IPv4Interface(interface: name, address: text, addressValue: addrValue, netmaskValue: maskValue))
        }
        return result
    }

    // MARK: - Advertising

    /// Begin advertising our service on the LAN. Tries the default TCP port
    /// first and falls back to a random available port if it is already taken.
    ///
    /// - Parameters:
    ///   - deviceId: Our unique device UUID.
    ///   - displayName: The user's chosen display name.
    func startAdvertising(deviceId: String, displayName: String) {
        startAdvertising(deviceId: deviceId, displayName: displayName, preferFixedPort: true)
    }

    private func startAdvertising(deviceId: String, displayName: String, preferFixedPort: Bool) {
        // Tear down any existing listener first.
        stopAdvertising()

        advertisedDeviceId = deviceId
        advertisedDisplayName = displayName
        self.preferFixedPort = preferFixedPort

        let parameters = Self.makeTCPParameters()
        do {
            if preferFixedPort, let port = NWEndpoint.Port(rawValue: Self.defaultTCPPort) {
                listener = try NWListener(using: parameters, on: port)
            } else {
                listener = try NWListener(using: parameters)
            }
        } catch {
            print("[LANDiscovery] Failed to create NWListener on preferred port: \(error). Falling back.")
            if preferFixedPort {
                startAdvertising(deviceId: deviceId, displayName: displayName, preferFixedPort: false)
                return
            }
            print("[LANDiscovery] Failed to create NWListener: \(error)")
            setListenerPhase(.failed(error.localizedDescription))
            return
        }

        // Build Bonjour service descriptor with a TXT record.
        let txtRecord = buildTXTRecord(deviceId: deviceId, displayName: displayName)
        listener?.service = NWListener.Service(
            type: Self.serviceType,
            txtRecord: txtRecord
        )

        setListenerPhase(.starting)

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let port = self.listener?.port?.rawValue
                self.listeningPort = port
                if let port {
                    print("[LANDiscovery] Listener ready on port \(port)")
                }
                self.setListenerPhase(.ready)

            case .waiting(let error):
                print("[LANDiscovery] Listener waiting: \(error)")
                if Self.isLocalNetworkDenied(error) {
                    self.flagPermissionDenied()
                    self.setListenerPhase(.permissionDenied)
                } else {
                    self.setListenerPhase(.waiting(error.localizedDescription))
                }

            case .failed(let error):
                print("[LANDiscovery] Listener failed: \(error). Restarting…")
                self.listener?.cancel()
                if preferFixedPort && Self.isAddressInUse(error) {
                    self.queue.async { [weak self] in
                        guard let self, let id = self.advertisedDeviceId,
                              let name = self.advertisedDisplayName else { return }
                        self.startAdvertising(deviceId: id, displayName: name, preferFixedPort: false)
                    }
                    return
                }
                if Self.isLocalNetworkDenied(error) {
                    self.flagPermissionDenied()
                    self.setListenerPhase(.permissionDenied)
                    return
                }
                self.setListenerPhase(.failed(error.localizedDescription))
                // Attempt to restart after a brief delay.
                self.queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, let id = self.advertisedDeviceId,
                          let name = self.advertisedDisplayName else { return }
                    self.startAdvertising(deviceId: id, displayName: name, preferFixedPort: self.preferFixedPort)
                }

            case .cancelled:
                print("[LANDiscovery] Listener cancelled")
                self.listeningPort = nil
                self.setListenerPhase(.stopped)

            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            print("[LANDiscovery] Incoming connection from \(connection.endpoint)")
            self?.onIncomingConnection?(connection)
        }

        listener?.start(queue: queue)
    }

    /// Update the advertised display name without restarting the listener.
    /// This rebuilds and re-publishes the Bonjour TXT record in-place.
    ///
    /// - Parameter name: The new display name to advertise.
    func updateDisplayName(_ name: String) {
        guard let deviceId = advertisedDeviceId else { return }
        advertisedDisplayName = name
        let txtRecord = buildTXTRecord(deviceId: deviceId, displayName: name)
        listener?.service = NWListener.Service(
            type: Self.serviceType,
            txtRecord: txtRecord
        )
    }

    // MARK: - Browsing

    /// Begin browsing for other SecureChat peers on the LAN.
    ///
    /// - Parameter ownDeviceId: Our device UUID so we can filter out our own advertisement.
    func startBrowsing(ownDeviceId: String) {
        stopBrowsing()

        self.ownDeviceId = ownDeviceId

        let descriptor = NWBrowser.Descriptor.bonjour(type: Self.serviceType, domain: nil)
        browser = NWBrowser(for: descriptor, using: Self.makeTCPParameters())

        setBrowserPhase(.starting)

        browser?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("[LANDiscovery] Browser ready")
                self.setBrowserPhase(.ready)
            case .waiting(let error):
                print("[LANDiscovery] Browser waiting: \(error)")
                if Self.isLocalNetworkDenied(error) {
                    self.flagPermissionDenied()
                    self.setBrowserPhase(.permissionDenied)
                } else {
                    self.setBrowserPhase(.waiting(error.localizedDescription))
                }
            case .failed(let error):
                print("[LANDiscovery] Browser failed: \(error)")
                if Self.isLocalNetworkDenied(error) {
                    self.flagPermissionDenied()
                    self.setBrowserPhase(.permissionDenied)
                } else {
                    self.setBrowserPhase(.failed(error.localizedDescription))
                }
            case .cancelled:
                print("[LANDiscovery] Browser cancelled")
                self.setBrowserPhase(.stopped)
            default:
                break
            }
        }

        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            self?.handleBrowseChanges(results: results, changes: changes)
        }

        browser?.start(queue: queue)
    }

    // MARK: - Teardown

    /// Stop both advertising and browsing.
    func stopAll() {
        stopAdvertising()
        stopBrowsing()
        isLocalNetworkDenied = false
        listeningPort = nil
        setListenerPhase(.stopped)
        setBrowserPhase(.stopped)
    }

    // MARK: - Local IPv4 Addresses

    /// Enumerate currently-up IPv4 addresses, skipping loopback.
    /// Includes interfaces such as en0, bridge100 (Internet Sharing), ap1, etc.
    static func currentIPv4Addresses() -> [LocalAddress] {
        var addresses: [LocalAddress] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(first) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = ptr {
            defer { ptr = iface.pointee.ifa_next }

            let flags = Int32(iface.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = iface.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let name = String(cString: iface.pointee.ifa_name)
            let address = String(cString: host)
            guard address != "0.0.0.0", !address.hasPrefix("127.") else { continue }
            addresses.append(LocalAddress(interface: name, address: address))
        }

        // Prefer common LAN interfaces first so the most useful IP is at the top.
        let rank: [String: Int] = [
            "en0": 0, "en1": 1, "en2": 2,
            "bridge100": 3, "bridge101": 4,
            "ap1": 5, "awdl0": 6
        ]
        addresses.sort { a, b in
            let ra = rank[a.interface] ?? 50
            let rb = rank[b.interface] ?? 50
            if ra != rb { return ra < rb }
            return a.interface < b.interface
        }
        return addresses
    }

    // MARK: - Error Classification

    static func isLocalNetworkDenied(_ error: NWError) -> Bool {
        switch error {
        case .dns(let code):
            return code == dnsPolicyDenied || code == dnsNoAuth
        case .posix(let code):
            return code == .EPERM || code == .EACCES
        default:
            break
        }
        let text = String(describing: error)
        return text.contains("PolicyDenied")
            || text.contains("-65570")
            || text.contains("NoAuth")
            || text.contains("-65555")
    }

    static func isAddressInUse(_ error: NWError) -> Bool {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return true
        }
        let text = String(describing: error)
        return text.contains("Address already in use") || text.contains("EADDRINUSE")
    }

    // MARK: - Private Helpers

    private func stopAdvertising() {
        listener?.cancel()
        listener = nil
        listeningPort = nil
    }

    private func stopBrowsing() {
        browser?.cancel()
        browser = nil
        lock.lock()
        discoveredPeers.removeAll()
        lock.unlock()
    }

    private func flagPermissionDenied() {
        isLocalNetworkDenied = true
    }

    private func setListenerPhase(_ phase: Phase) {
        listenerPhase = phase
        onStatusChange?()
    }

    private func setBrowserPhase(_ phase: Phase) {
        browserPhase = phase
        onStatusChange?()
    }

    /// Build an `NWTXTRecord` containing our identity fields.
    private func buildTXTRecord(deviceId: String, displayName: String) -> NWTXTRecord {
        var record = NWTXTRecord()
        record[TXTKey.deviceId] = deviceId
        record[TXTKey.displayName] = displayName
        return record
    }

    /// Process a batch of browse-result changes, emitting discovery / loss callbacks.
    private func handleBrowseChanges(
        results: Set<NWBrowser.Result>,
        changes: Set<NWBrowser.Result.Change>
    ) {
        for change in changes {
            switch change {
            case .added(let result):
                handleResultAdded(result)

            case .removed(let result):
                handleResultRemoved(result)

            case .changed(old: let old, new: let new, flags: _):
                // Treat a metadata change as a remove-then-add so the caller
                // receives an updated displayName.
                handleResultRemoved(old)
                handleResultAdded(new)

            case .identical:
                break

            @unknown default:
                break
            }
        }
    }

    /// Extract TXT metadata from a newly-appeared browse result and notify the delegate.
    private func handleResultAdded(_ result: NWBrowser.Result) {
        guard let (deviceId, displayName) = extractMetadata(from: result) else { return }

        // Ignore our own advertisement.
        guard deviceId != ownDeviceId else { return }

        lock.lock()
        discoveredPeers[result] = deviceId
        lock.unlock()

        print("[LANDiscovery] Discovered peer: \(displayName) (\(deviceId))")
        onPeerDiscovered?(deviceId, displayName, result.endpoint)
    }

    /// Handle a browse result disappearing and notify the delegate.
    private func handleResultRemoved(_ result: NWBrowser.Result) {
        lock.lock()
        let deviceId = discoveredPeers.removeValue(forKey: result)
        lock.unlock()

        guard let deviceId else { return }
        print("[LANDiscovery] Lost peer: \(deviceId)")
        onPeerLost?(deviceId)
    }

    /// Parse `deviceId` and `displayName` from a browse result's Bonjour TXT record.
    ///
    /// - Returns: A tuple of `(deviceId, displayName)`, or `nil` if the metadata
    ///   is missing or malformed.
    private func extractMetadata(from result: NWBrowser.Result) -> (String, String)? {
        guard case .bonjour(let txtRecord) = result.metadata else { return nil }

        guard let deviceId = txtRecord[TXTKey.deviceId],
              let displayName = txtRecord[TXTKey.displayName] else {
            print("[LANDiscovery] Browse result missing required TXT keys")
            return nil
        }

        return (deviceId, displayName)
    }
}

// MARK: - TXT Record Keys

private extension LANDiscovery {
    enum TXTKey {
        static let deviceId    = "deviceId"
        static let displayName = "displayName"
    }
}
