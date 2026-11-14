// SettingsView.swift
// SecureChat – LAN End-to-End Encrypted Messenger
// Settings screen with profile, security info, and about section

import SwiftUI
import UIKit
import PhotosUI

struct SettingsView: View {
    @EnvironmentObject var chatManager: ChatManager

    var body: some View {
        SettingsBody(network: chatManager.networkManager)
            .environmentObject(chatManager)
    }
}

struct SettingsBody: View {
    @EnvironmentObject var chatManager: ChatManager
    @ObservedObject var network: NetworkManager
    @Environment(\.dismiss) private var dismiss

    @State private var editedName: String = ""
    @State private var showCopied = false
    @State private var showHowItWorks = false
    @State private var avatarItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                LocalNetworkForm(network: network)
                securitySection
                howItWorksSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        applyNameChange()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                editedName = chatManager.displayName
                network.refreshLocalAddresses()
            }
        }
        .tint(TelegramColors.tint)
    }

    // MARK: - Profile

    private var profileSection: some View {
        Section {
            HStack(spacing: 16) {
                PhotosPicker(selection: $avatarItem, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        AvatarView(name: editedName, size: 64, imageData: chatManager.avatarData)
                        Image(systemName: "camera.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.white, TelegramColors.tint)
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    TextField("Display Name", text: $editedName)
                        .font(.title3.weight(.semibold))
                        .textFieldStyle(.plain)
                        .onSubmit { applyNameChange() }

                    Text("Your name and photo are visible to everyone you chat with")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 8)

            if chatManager.avatarData != nil {
                Button("Remove Photo", role: .destructive) {
                    chatManager.updateAvatar(nil)
                }
            }
        } header: {
            Text("Profile")
        }
        .onChange(of: avatarItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run { chatManager.updateAvatar(data) }
                }
                await MainActor.run { avatarItem = nil }
            }
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        Section {
            // Device ID
            VStack(alignment: .leading, spacing: 4) {
                Text("Device ID")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text(chatManager.localDeviceId)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button {
                        UIPasteboard.general.string = chatManager.localDeviceId
                        withAnimation { showCopied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { showCopied = false }
                        }
                    } label: {
                        Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                            .foregroundColor(TelegramColors.tint)
                    }
                }
            }
            .padding(.vertical, 2)

            // Identity Fingerprint
            VStack(alignment: .leading, spacing: 4) {
                Text("Identity Fingerprint")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(identityFingerprint)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
            }
            .padding(.vertical, 2)

            // Explanation
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(.green)
                    .font(.title3)

                Text("Your identity keys are generated locally and never leave this device. Compare fingerprints with peers in person to verify identity.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Security")
        }
    }

    // MARK: - How It Works

    private var howItWorksSection: some View {
        Section {
            DisclosureGroup("How E2E Encryption Works", isExpanded: $showHowItWorks) {
                VStack(alignment: .leading, spacing: 12) {
                    featureRow(
                        icon: "key.fill",
                        color: .orange,
                        title: "X3DH Key Agreement",
                        detail: "Extended Triple Diffie-Hellman establishes a shared secret between two peers without prior communication."
                    )
                    featureRow(
                        icon: "arrow.triangle.2.circlepath",
                        color: .blue,
                        title: "Double Ratchet",
                        detail: "Every message uses a unique encryption key. Keys are continuously ratcheted forward, providing forward secrecy."
                    )
                    featureRow(
                        icon: "wifi",
                        color: .green,
                        title: "LAN Only",
                        detail: "Messages travel directly between devices on your local network. No servers, no internet, no metadata leaks."
                    )
                    featureRow(
                        icon: "shield.checkered",
                        color: .purple,
                        title: "AES-256-GCM",
                        detail: "Messages are encrypted with AES-256 in GCM mode, providing both confidentiality and integrity."
                    )
                }
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text("1.2.0")
                    .foregroundColor(.secondary)
            }
            HStack {
                Text("Protocol")
                Spacer()
                Text("Signal Protocol (X3DH + Double Ratchet)")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            HStack {
                Text("Encryption")
                Spacer()
                Text("AES-256-GCM · Curve25519 · Ed25519")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        } header: {
            Text("About")
        } footer: {
            Text("SecureChat uses the Signal Protocol for end-to-end encryption over your local network. No data is sent to external servers.")
                .font(.caption2)
                .padding(.top, 4)
        }
    }

    // MARK: - Helpers

    private func featureRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var identityFingerprint: String {
        let dhKey = chatManager.cryptoEngine.identityDHPublicKeyData
        return dhKey.map { String(format: "%02X", $0) }
            .enumerated()
            .map { index, hex in
                (index > 0 && index % 4 == 0) ? " " + hex : hex
            }
            .joined()
    }

    private func applyNameChange() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            editedName = chatManager.displayName
            return
        }
        chatManager.updateDisplayName(trimmed)
    }
}


// MARK: - Local Network / Connect by IP

struct LocalNetworkForm: View {
    @EnvironmentObject var chatManager: ChatManager
    @ObservedObject var network: NetworkManager

    @State private var connectHost: String = ""
    @State private var connectPort: String = "\(NetworkManager.defaultTCPPort)"
    @State private var isConnecting = false

    var body: some View {
        Section {
            HStack {
                Text("Status")
                Spacer()
                if network.isLocalNetworkDenied {
                    Text("Bonjour blocked – using direct scan")
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.trailing)
                } else {
                    Text(network.discoveryStatus)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            .font(.subheadline)

            if let port = network.listeningPort {
                HStack {
                    Text("Listening Port")
                    Spacer()
                    Text("\(port)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                    Button {
                        UIPasteboard.general.string = String(port)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundColor(TelegramColors.tint)
                    }
                }
            }

            if network.localIPv4Addresses.isEmpty {
                Text("No IPv4 address found. Check that Wi-Fi or Internet Sharing is connected.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(network.localIPv4Addresses) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.interface)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(addressLine(item))
                                .font(.system(.body, design: .monospaced))
                        }
                        Spacer()
                        Button {
                            UIPasteboard.general.string = addressLine(item)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                                .foregroundColor(TelegramColors.tint)
                        }
                    }
                }
            }

            Button("Refresh Addresses") {
                network.refreshLocalAddresses()
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-reconnect")
                    Text(network.scanStatus.isEmpty ? "Remembered peers are re-dialed every 5 s; the local subnet is scanned periodically." : network.scanStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if network.isScanning {
                    ProgressView()
                } else {
                    Button("Scan Now") { network.scanNow() }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Connect by IP")
                    .font(.subheadline.weight(.semibold))
                HStack {
                    TextField("IP address", text: $connectHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Port", text: $connectPort)
                        .keyboardType(.numberPad)
                        .frame(width: 72)
                        .multilineTextAlignment(.trailing)
                }
                Button {
                    submitManualConnect()
                } label: {
                    HStack {
                        if isConnecting {
                            ProgressView()
                        }
                        Text("Connect")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(connectHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)

                if let ok = network.lastManualConnectSuccess, !ok.isEmpty {
                    Text(ok)
                        .font(.caption)
                        .foregroundColor(.green)
                }
                if let err = network.lastManualConnectError, !err.isEmpty {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Local Network")
        } footer: {
            Text(networkFooter)
                .font(.caption2)
        }
        .onAppear {
            network.refreshLocalAddresses()
        }
    }

    private var networkFooter: String {
        "Peers are found automatically: Bonjour where allowed, remembered addresses (re-dialed every few seconds and whenever the app returns to the foreground), a UDP beacon, and a scan of your local /24 subnet on port \(NetworkManager.defaultTCPPort). TrollStore installs cannot use Bonjour, but the scan still works. You only need Connect by IP if the devices are on different subnets."
    }

    private func addressLine(_ item: NetworkManager.LocalAddress) -> String {
        if let port = network.listeningPort {
            return "\(item.address):\(port)"
        }
        return item.address
    }

    private func submitManualConnect() {
        let host = connectHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = UInt16(connectPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? NetworkManager.defaultTCPPort
        guard !host.isEmpty else { return }
        isConnecting = true
        chatManager.connectByIP(host, port: port)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            isConnecting = false
        }
    }
}

struct ManualConnectSheet: View {
    @EnvironmentObject var chatManager: ChatManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                LocalNetworkForm(network: chatManager.networkManager)
            }
            .navigationTitle("Connect by IP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(TelegramColors.tint)
    }
}
