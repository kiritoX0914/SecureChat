// SettingsView.swift
// SecureChat – LAN End-to-End Encrypted Messenger
// Settings screen with profile, security info, and about section

import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var chatManager: ChatManager
    @Environment(\.dismiss) private var dismiss

    @State private var editedName: String = ""
    @State private var showCopied = false
    @State private var showHowItWorks = false

    var body: some View {
        NavigationStack {
            Form {
                profileSection
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
            }
        }
        .tint(TelegramColors.tint)
    }

    // MARK: - Profile

    private var profileSection: some View {
        Section {
            HStack(spacing: 16) {
                AvatarView(name: editedName, size: 64)

                VStack(alignment: .leading, spacing: 4) {
                    TextField("Display Name", text: $editedName)
                        .font(.title3.weight(.semibold))
                        .textFieldStyle(.plain)
                        .onSubmit { applyNameChange() }

                    Text("Visible to peers on your network")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 8)
        } header: {
            Text("Profile")
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
                Text("1.0.0")
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
