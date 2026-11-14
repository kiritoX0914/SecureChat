// ChatListView.swift
// SecureChat – LAN End-to-End Encrypted Messenger
// Telegram-inspired main chat list with peer discovery and groups

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

    @State private var path: [String] = []
    @State private var showSettings = false
    @State private var showNewChat = false
    @State private var showNewGroup = false
    @State private var showManualConnect = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if chatManager.sortedConversations.isEmpty {
                    VStack(spacing: 16) {
                        EmptyStateView(
                            icon: "antenna.radiowaves.left.and.right",
                            title: "Looking for Peers",
                            subtitle: emptySubtitle,
                            showSpinner: true
                        )
                        if !listenHint.isEmpty {
                            Text(listenHint)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                                .textSelection(.enabled)
                        }
                        if !network.scanStatus.isEmpty {
                            Text(network.scanStatus)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Button {
                                network.scanNow()
                            } label: {
                                Label("Scan Now", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            Button {
                                showManualConnect = true
                            } label: {
                                Label("Connect by IP", systemImage: "link")
                                    .fontWeight(.semibold)
                            }
                            .buttonStyle(.borderedProminent)
                        }
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
                        Menu {
                            Button { showNewChat = true } label: { Label("New Chat", systemImage: "person") }
                            Button { showNewGroup = true } label: { Label("New Group", systemImage: "person.3") }
                            Button { showManualConnect = true } label: { Label("Connect by IP", systemImage: "link") }
                            Button { network.scanNow() } label: { Label("Scan Network Now", systemImage: "arrow.clockwise") }
                        } label: {
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
                NewChatView { id in open(id) }
                    .environmentObject(chatManager)
            }
            .sheet(isPresented: $showNewGroup) {
                NewGroupView { id in open(id) }
                    .environmentObject(chatManager)
            }
            .sheet(isPresented: $showManualConnect) {
                ManualConnectSheet()
                    .environmentObject(chatManager)
            }
            .navigationDestination(for: String.self) { convId in
                if chatManager.conversations[convId] != nil {
                    ConversationView(peerId: convId)
                        .environmentObject(chatManager)
                }
            }
        }
        .tint(TelegramColors.tint)
    }

    private func open(_ id: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            path = [id]
        }
    }

    // MARK: - Conversation List

    private var conversationList: some View {
        List {
            if !network.scanStatus.isEmpty && onlinePeerCount == 0 {
                HStack(spacing: 8) {
                    if network.isScanning { ProgressView() }
                    Text(network.scanStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Scan") { network.scanNow() }
                        .font(.caption)
                }
            }
            ForEach(chatManager.sortedConversations, id: \.id) { conversation in
                NavigationLink(value: conversation.id) {
                    ConversationRowView(conversation: conversation,
                                        localDeviceId: chatManager.localDeviceId,
                                        isOnline: chatManager.isOnline(conversation),
                                        senderLabel: senderLabel(conversation))
                }
            }
            .onDelete(perform: deleteConversation)
        }
        .listStyle(.plain)
        .refreshable { network.scanNow() }
    }

    private func senderLabel(_ conv: Conversation) -> String? {
        guard conv.isGroup, let last = conv.lastMessage else { return nil }
        if last.senderId == chatManager.localDeviceId { return "You" }
        return chatManager.senderName(for: last, in: conv.id)
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
        chatManager.sortedConversations.filter { !$0.isGroup && $0.peer.isOnline }.count
    }

    // MARK: - Empty-state copy

    private var emptySubtitle: String {
        "Scanning your local network for devices running SecureChat. Keep SecureChat open on the other device, or connect by IP."
    }

    private var listenHint: String {
        let addrs = network.localIPv4Addresses.map(\.address)
        let port = network.listeningPort ?? NetworkManager.defaultTCPPort
        if !addrs.isEmpty {
            return "This device: " + addrs.map { "\($0):\(port)" }.joined(separator: ", ")
        }
        return network.discoveryStatus
    }

    // MARK: - Actions

    private func deleteConversation(at offsets: IndexSet) {
        let idsToDelete = offsets.map { chatManager.sortedConversations[$0].id }
        for convId in idsToDelete {
            chatManager.deleteConversation(peerId: convId)
        }
    }
}

// MARK: - Conversation Row

struct ConversationRowView: View {
    let conversation: Conversation
    let localDeviceId: String
    var isOnline: Bool = false
    var senderLabel: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(name: conversation.peer.displayName, size: 52,
                           imageData: conversation.isGroup ? conversation.group?.avatarData : conversation.peer.avatarData,
                           isGroup: conversation.isGroup)
                if isOnline {
                    OnlineIndicatorView(size: 14)
                        .offset(x: 2, y: 2)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if conversation.isGroup {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 10))
                            .foregroundColor(TelegramColors.tint)
                    } else if conversation.peer.hasIdentity {
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
                        Text(conversation.isGroup ? "\(conversation.group?.members.count ?? 0) members" : "No messages yet")
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
                    .colorMultiply(.gray)
            }
            if let senderLabel {
                Text(senderLabel + ":")
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            Text(msg.previewText)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - New Chat View (Peer Discovery)

struct NewChatView: View {
    @EnvironmentObject var chatManager: ChatManager
    var onSelect: (String) -> Void = { _ in }

    var body: some View {
        NewChatBody(network: chatManager.networkManager, onSelect: onSelect)
            .environmentObject(chatManager)
    }
}

struct NewChatBody: View {
    @EnvironmentObject var chatManager: ChatManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var network: NetworkManager
    var onSelect: (String) -> Void
    @State private var showManualConnect = false

    var body: some View {
        NavigationStack {
            Group {
                if onlinePeers.isEmpty && offlinePeers.isEmpty {
                    VStack(spacing: 16) {
                        EmptyStateView(
                            icon: "magnifyingglass",
                            title: "Searching…",
                            subtitle: "Scanning your local network for devices running SecureChat.",
                            showSpinner: true
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

    private var onlinePeers: [Conversation] {
        chatManager.sortedConversations.filter { !$0.isGroup && $0.peer.isOnline }
    }

    private var offlinePeers: [Conversation] {
        chatManager.sortedConversations.filter { !$0.isGroup && !$0.peer.isOnline }
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
                    Text("Peers are found automatically (Bonjour, remembered addresses and a scan of your local subnet). If one does not appear, use Connect by IP.")
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
            onSelect(conv.id)
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(name: conv.peer.displayName, size: 44, imageData: conv.peer.avatarData)
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

                if conv.peer.hasIdentity {
                    Text(conv.peer.fingerprint)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Member picker (shared by New Group / Add Members)

struct MemberPickerList: View {
    @EnvironmentObject var chatManager: ChatManager
    let candidates: [Peer]
    @Binding var selected: Set<String>

    var body: some View {
        if candidates.isEmpty {
            Text("No known peers yet. Peers you have connected to appear here.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            ForEach(candidates, id: \.id) { peer in
                Button {
                    if selected.contains(peer.id) { selected.remove(peer.id) } else { selected.insert(peer.id) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selected.contains(peer.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selected.contains(peer.id) ? TelegramColors.tint : .secondary)
                            .font(.title3)
                        AvatarView(name: peer.displayName, size: 36, imageData: peer.avatarData)
                        VStack(alignment: .leading) {
                            Text(peer.displayName).foregroundColor(.primary)
                            Text(chatManager.isConnected(peer.id) ? "online" : "offline")
                                .font(.caption)
                                .foregroundColor(chatManager.isConnected(peer.id) ? .green : .secondary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - New Group

struct NewGroupView: View {
    @EnvironmentObject var chatManager: ChatManager
    @Environment(\.dismiss) private var dismiss
    var onCreated: (String) -> Void = { _ in }

    @State private var name = ""
    @State private var selected: Set<String> = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Group Name") {
                    TextField("Group name", text: $name)
                }
                Section {
                    MemberPickerList(candidates: chatManager.knownPeers, selected: $selected)
                } header: {
                    Text("Members")
                } footer: {
                    Text("Each message is encrypted separately for every member (pairwise Signal sessions). Members receive messages while they are reachable on the LAN; offline members get them when they reconnect to you.")
                }
            }
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") {
                        let gid = chatManager.createGroup(name: name, members: Array(selected))
                        dismiss()
                        onCreated(gid)
                    }
                    .fontWeight(.semibold)
                    .disabled(selected.isEmpty)
                }
            }
        }
        .tint(TelegramColors.tint)
    }
}

// MARK: - Group Info

struct GroupInfoView: View {
    let groupId: String
    @EnvironmentObject var chatManager: ChatManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var showAdd = false
    @State private var addSelection: Set<String> = []
    @State private var confirmLeave = false

    private var group: GroupInfo? { chatManager.conversations[groupId]?.group }
    private var isMember: Bool { group?.members.contains(chatManager.localDeviceId) ?? false }

    var body: some View {
        NavigationStack {
            Form {
                Section("Group Name") {
                    HStack {
                        TextField("Group name", text: $name)
                            .onSubmit { chatManager.renameGroup(groupId, to: name) }
                        if name != (group?.name ?? "") {
                            Button("Save") { chatManager.renameGroup(groupId, to: name) }
                        }
                    }
                    .disabled(!isMember)
                }

                Section {
                    ForEach(group?.members ?? [], id: \.self) { member in
                        HStack(spacing: 12) {
                            AvatarView(name: chatManager.memberName(member, in: groupId), size: 36,
                                       imageData: chatManager.avatar(for: member))
                            VStack(alignment: .leading) {
                                Text(member == chatManager.localDeviceId ? "\(chatManager.displayName) (you)" : chatManager.memberName(member, in: groupId))
                                if member != chatManager.localDeviceId {
                                    Text(chatManager.isConnected(member) ? "online" : "offline")
                                        .font(.caption)
                                        .foregroundColor(chatManager.isConnected(member) ? .green : .secondary)
                                }
                            }
                            Spacer()
                            if member == group?.createdBy {
                                Text("creator").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        .swipeActions {
                            if isMember && member != chatManager.localDeviceId {
                                Button(role: .destructive) {
                                    chatManager.removeMember(member, from: groupId)
                                } label: { Label("Remove", systemImage: "person.badge.minus") }
                            }
                        }
                    }
                    if isMember {
                        Button {
                            addSelection = []
                            showAdd = true
                        } label: { Label("Add Members", systemImage: "person.badge.plus") }
                    }
                } header: {
                    Text("\(group?.members.count ?? 0) Members")
                }

                Section {
                    if isMember {
                        Button("Leave Group", role: .destructive) { confirmLeave = true }
                    } else {
                        Text("You are no longer a member of this group.")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Group Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        if isMember && name != (group?.name ?? "") { chatManager.renameGroup(groupId, to: name) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { name = group?.name ?? "" }
            .confirmationDialog("Leave this group?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave Group", role: .destructive) {
                    chatManager.leaveGroup(groupId)
                    dismiss()
                }
            }
            .sheet(isPresented: $showAdd) {
                NavigationStack {
                    Form {
                        MemberPickerList(candidates: chatManager.knownPeers.filter { !(group?.members.contains($0.id) ?? false) },
                                         selected: $addSelection)
                    }
                    .navigationTitle("Add Members")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Cancel") { showAdd = false }
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Add") {
                                chatManager.addMembers(Array(addSelection), to: groupId)
                                showAdd = false
                            }
                            .disabled(addSelection.isEmpty)
                        }
                    }
                }
                .environmentObject(chatManager)
            }
        }
        .tint(TelegramColors.tint)
    }
}
