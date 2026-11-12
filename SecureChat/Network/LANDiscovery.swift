// LANDiscovery.swift
// SecureChat – LAN End-to-End Encrypted Messenger
// Bonjour/mDNS peer discovery using Network.framework

import Foundation
import Network

/// Handles advertising our presence and discovering peers on the local network
/// via Bonjour (mDNS/DNS-SD) using `NWListener` and `NWBrowser`.
final class LANDiscovery {

    // MARK: - Constants

    /// The Bonjour service type used for peer discovery.
    private static let serviceType = "_securechat._tcp"

    // MARK: - Callbacks

    /// Called when a new peer is discovered. Parameters: (deviceId, displayName, endpoint).
    var onPeerDiscovered: ((String, String, NWEndpoint) -> Void)?

    /// Called when a previously-discovered peer disappears. Parameter: deviceId.
    var onPeerLost: ((String) -> Void)?

    /// Called when the listener accepts an incoming TCP connection.
    var onIncomingConnection: ((NWConnection) -> Void)?

    // MARK: - Public Read-Only State

    /// The TCP port our listener is bound to, available once the listener is `.ready`.
    var listeningPort: UInt16? {
        guard let port = listener?.port else { return nil }
        return port.rawValue
    }

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

    // MARK: - Advertising

    /// Begin advertising our service on the LAN. The listener picks a random
    /// available TCP port and publishes a Bonjour TXT record containing our
    /// `deviceId` and `displayName`.
    ///
    /// - Parameters:
    ///   - deviceId: Our unique device UUID.
    ///   - displayName: The user's chosen display name.
    func startAdvertising(deviceId: String, displayName: String) {
        // Tear down any existing listener first.
        stopAdvertising()

        advertisedDeviceId = deviceId
        advertisedDisplayName = displayName

        do {
            let parameters = NWParameters.tcp
            listener = try NWListener(using: parameters)
        } catch {
            print("[LANDiscovery] Failed to create NWListener: \(error)")
            return
        }

        // Build Bonjour service descriptor with a TXT record.
        let txtRecord = buildTXTRecord(deviceId: deviceId, displayName: displayName)
        listener?.service = NWListener.Service(
            type: Self.serviceType,
            txtRecord: txtRecord
        )

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = self?.listener?.port {
                    print("[LANDiscovery] Listener ready on port \(port)")
                }
            case .failed(let error):
                print("[LANDiscovery] Listener failed: \(error). Restarting…")
                self?.listener?.cancel()
                // Attempt to restart after a brief delay.
                self?.queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, let id = self.advertisedDeviceId,
                          let name = self.advertisedDisplayName else { return }
                    self.startAdvertising(deviceId: id, displayName: name)
                }
            case .cancelled:
                print("[LANDiscovery] Listener cancelled")
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
        browser = NWBrowser(for: descriptor, using: .tcp)

        browser?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[LANDiscovery] Browser ready")
            case .failed(let error):
                print("[LANDiscovery] Browser failed: \(error)")
            case .cancelled:
                print("[LANDiscovery] Browser cancelled")
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
    }

    // MARK: - Private Helpers

    private func stopAdvertising() {
        listener?.cancel()
        listener = nil
    }

    private func stopBrowsing() {
        browser?.cancel()
        browser = nil
        lock.lock()
        discoveredPeers.removeAll()
        lock.unlock()
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
