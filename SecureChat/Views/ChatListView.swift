// ChatListView.swift
// SecureChat – LAN End-to-End Encrypted Messenger
// Telegram-inspired main chat list with peer discovery

import SwiftUI

struct ChatListView: View {
    @EnvironmentObject var chatManager: ChatManager

    @State private var showSettings = false
    @State private var showNewChat = false

    var body: some View {
        NavigationStack {
            Group {
                if chatManager.sortedConversations.isEmpty {
                    EmptyStateView(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "No Peers Found",
                        subtitle: "Looking for devices running SecureChat on your local network…",
                        showSpinner: true
                    )
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
                        // New Chat button
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
                .fill(onlinePeerCount > 0 ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(onlinePeerCount > 0 ? "\(onlinePeerCount) online" : "Searching…")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var onlinePeerCount: Int {
        chatManager.sortedConversations.filter { $0.peer.isOnline }.count
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if onlinePeers.isEmpty && offlinePeers.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "Searching…",
                        subtitle: "Looking for devices running SecureChat on your local network.",
                        showSpinner: true
                    )
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
                    Text("Peers are discovered automatically via Bonjour on your local network. Make sure both devices are on the same WiFi.")
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
