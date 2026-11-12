// ChatListView.swift
// SecureChat – LAN End-to-End Encrypted Messenger
// Telegram-inspired main chat list with peer discovery

import SwiftUI

struct ChatListView: View {
    @EnvironmentObject var chatManager: ChatManager

    var body: some View {
        ChatListBody(network: chatManager.networkManager)
            .environmentObject(chatManager)
    }
}

struct ChatListBody: View {
    @EnvironmentObject var chatManager: ChatManager
    @ObservedObject var network: NetworkManager

    @State private var showSettings = false
    @State private var showNewChat = false
    @State private var showManualConnect = false

    var body: some View {
        NavigationStack {
            Group {
                if chatManager.sortedConversations.isEmpty {
                    VStack(spacing: 16) {
                        EmptyStateView(
                            icon: "antenna.radiowaves.left.and.right",
                            title: "No Peers Found",
                            subtitle: emptySubtitle,
                            showSpinner: !network.isLocalNetworkDenied
                        )
                        if !listenHint.isEmpty {
                            Text(listenHint)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        Button {
                            showManualConnect = true
                        } label: {
                            Label("Connect by IP", systemImage: "link")
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    conversationList
                }
            }
            .navigationTitle("SecureChat")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        connectionIndicator
                        Button { showManualConnect = true } label: {
                            Image(systemName: "link")
                        }
                        .accessibilityLabel("Connect by IP")
                        Button { showNewChat = true } label: {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(chatManager)
            }
            .sheet(isPresented: $showNewChat) {
                NewChatView()
                    .environmentObject(chatManager)
            }
            .sheet(isPresented: $showManualConnect) {
                ManualConnectSheet()
                    .environmentObject(chatManager)
            }
            .navigationDestination(for: String.self) { peerId in
                if chatManager.conversations[peerId] != nil {
                    ConversationView(peerId: peerId)
                        .environmentObject(chatManager)
                }
            }
        }
        .tint(TelegramColors.tint)
    }

    // MARK: - Conversation List

    private var conversationList: some View {
        List {
            ForEach(chatManager.sortedConversations, id: \.id) { conversation in
                NavigationLink(value: conversation.id) {
                    ConversationRowView(conversation: conversation,
                                        localDeviceId: chatManager.localDeviceId)
                }
            }
            .onDelete(perform: deleteConversation)
        }
        .listStyle(.plain)
    }

    // MARK: - Connection Indicator

    private var connectionIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(onlinePeerCount > 0 ? Color.green : (network.isLocalNetworkDenied ? Color.red : Color.orange))
                .frame(width: 8, height: 8)
            Text(onlinePeerCount > 0 ? "\(onlinePeerCount) online" : (network.isLocalNetworkDenied ? "No LAN access" : "Searching…"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var onlinePeerCount: Int {
        chatManager.sortedConversations.filter { $0.peer.isOnline }.count
    }

    // MARK: - Empty-state copy

    private var emptySubtitle: String {
        if network.isLocalNetworkDenied {
            return "Local network permission denied. Automatic discovery is blocked — connect by IP instead."
        }
        return "Looking for devices running SecureChat on your local network…"
    }

    private var listenHint: String {
        let addrs = network.localIPv4Addresses.map(\.address)
        if let port = network.listeningPort, !addrs.isEmpty {
            return "This device: " + addrs.map { "\($0):\(port)" }.joined(separator: ", ")
        }
        if let port = network.listeningPort {
            return "Listening on port \(port)"
        }
        return network.discoveryStatus
    }

    // MARK: - Actions

    private func deleteConversation(at offsets: IndexSet) {
        let idsToDelete = offsets.map { chatManager.sortedConversations[$0].id }
        for peerId in idsToDelete {
            chatManager.deleteConversation(peerId: peerId)
        }
    }
}

// MARK: - Conversation Row

struct ConversationRowView: View {
    let conversation: Conversation
    let localDeviceId: String

    var body: some View {
        HStack(spacing: 12) {
            // Avatar with online indicator
            ZStack(alignment: .bottomTrailing) {
                AvatarView(name: conversation.peer.displayName, size: 52)
                if conversation.peer.isOnline {
                    OnlineIndicatorView(size: 14)
                        .offset(x: 2, y: 2)
                }
            }

            // Name + last message
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if conversation.peer.hasIdentity {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundColor(TelegramColors.tint)
                    }
                    Text(conversation.peer.displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)

                    Spacer()

                    if let last = conversation.lastMessage {
                        Text(last.timestamp.chatListTimestamp)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    if conversation.isTyping {
                        HStack(spacing: 4) {
                            TypingIndicatorView()
                            Text("typing")
                                .font(.subheadline)
                                .foregroundColor(TelegramColors.tint)
                        }
                    } else if let last = conversation.lastMessage {
                        lastMessagePreview(last)
                    } else {
                        Text("No messages yet")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .italic()
                    }

                    Spacer()

                    if conversation.unreadCount > 0 {
                        UnreadBadgeView(count: conversation.unreadCount)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func lastMessagePreview(_ msg: ChatMessage) -> some View {
        let isOutgoing = msg.senderId == localDeviceId

        HStack(spacing: 2) {
            if isOutgoing {
                StatusIconView(status: msg.status)
            }

            switch msg.contentType {
            case .image:
                HStack(spacing: 3) {
                    Image(systemName: "camera.fill")
                        .font(.caption)
                    Text("Photo")
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)

            case .file:
                HStack(spacing: 3) {
                    Image(systemName: "paperclip")
                        .font(.caption)
                    Text(msg.attachment?.filename ?? "File")
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)

            case .text:
                Text(msg.text)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - New Chat View (Peer Discovery)

struct NewChatView: View {
    @EnvironmentObject var chatManager: ChatManager

    var body: some View {
        NewChatBody(network: chatManager.networkManager)
            .environmentObject(chatManager)
    }
}

struct NewChatBody: View {
    @EnvironmentObject var chatManager: ChatManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var network: NetworkManager
    @State private var showManualConnect = false

    var body: some View {
        NavigationStack {
            Group {
                if onlinePeers.isEmpty && offlinePeers.isEmpty {
                    VStack(spacing: 16) {
                        EmptyStateView(
                            icon: "magnifyingglass",
                            title: network.isLocalNetworkDenied ? "Discovery Blocked" : "Searching…",
                            subtitle: network.isLocalNetworkDenied
                                ? "Local network permission denied. Connect by IP instead."
                                : "Looking for devices running SecureChat on your local network.",
                            showSpinner: !network.isLocalNetworkDenied
                        )
                        Button {
                            showManualConnect = true
                        } label: {
                            Label("Connect by IP", systemImage: "link")
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    peerList
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showManualConnect = true
                    } label: {
                        Image(systemName: "link")
                    }
                    .accessibilityLabel("Connect by IP")
                }
            }
            .sheet(isPresented: $showManualConnect) {
                ManualConnectSheet()
                    .environmentObject(chatManager)
            }
        }
        .tint(TelegramColors.tint)
    }

    // MARK: - Peers

    /// Online peers from discovered network
    private var onlinePeers: [Conversation] {
        chatManager.sortedConversations.filter { $0.peer.isOnline }
    }

    /// Previously seen but currently offline peers
    private var offlinePeers: [Conversation] {
        chatManager.sortedConversations.filter { !$0.peer.isOnline }
    }

    private var peerList: some View {
        List {
            if !onlinePeers.isEmpty {
                Section {
                    ForEach(onlinePeers, id: \.id) { conv in
                        peerRow(conv, online: true)
                    }
                } header: {
                    Label("Online Now", systemImage: "wifi")
                }
            }

            if !offlinePeers.isEmpty {
                Section {
                    ForEach(offlinePeers, id: \.id) { conv in
                        peerRow(conv, online: false)
                    }
                } header: {
                    Label("Previously Seen", systemImage: "clock")
                }
            }

            Section {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("Peers are discovered automatically via Bonjour. If none appear (TrollStore or Internet Sharing), use Connect by IP.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func peerRow(_ conv: Conversation, online: Bool) -> some View {
        Button {
            dismiss()
            // Small delay to let the sheet dismiss before navigation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // The conversation already exists since peers are auto-added.
                // The user will see it in the chat list and can tap to open.
            }
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(name: conv.peer.displayName, size: 44)
                    if online {
                        OnlineIndicatorView(size: 12)
                            .offset(x: 2, y: 2)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(conv.peer.displayName)
                            .font(.body.weight(.medium))
                            .foregroundColor(.primary)

                        if conv.peer.hasIdentity {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                                .foregroundColor(TelegramColors.tint)
                        }
                    }

                    if online {
                        Text("Available")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Text("Last seen \(conv.peer.lastSeen.chatListTimestamp)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Fingerprint snippet for identity verification
                if conv.peer.hasIdentity {
                    Text(conv.peer.fingerprint)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
