// ConversationView.swift
// SecureChat – LAN End-to-End Encrypted Messenger
// Telegram-inspired chat conversation: text, photos, videos, files, replies,
// multi-select delete, groups.

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import QuickLook
import UIKit

struct ConversationView: View {
    /// Conversation id (peer id, or group id).
    let peerId: String
    @EnvironmentObject var chatManager: ChatManager

    @State private var messageText = ""
    @State private var typingTask: Task<Void, Never>?
    @FocusState private var isInputFocused: Bool

    // Reply
    @State private var replyingTo: ChatMessage?

    // Pickers
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false

    // Viewers
    @State private var quickLookURL: URL?
    @State private var videoURL: IdentifiableURL?
    @State private var fullImage: IdentifiableImage?
    @State private var selectTextItem: IdentifiableText?
    @State private var shareURL: IdentifiableURL?
    @State private var exportURL: IdentifiableURL?

    // Selection / delete
    @State private var isSelecting = false
    @State private var selectedIds: Set<UUID> = []
    @State private var pendingDelete: Set<UUID> = []
    @State private var showDeleteDialog = false
    @State private var showClearDialog = false
    @State private var showGroupInfo = false
    @State private var highlightedId: UUID?
    @State private var scrollRequest: UUID?

    private var conversation: Conversation? {
        chatManager.conversations[peerId]
    }

    private var isGroup: Bool { conversation?.isGroup ?? false }

    var body: some View {
        VStack(spacing: 0) {
            messagesScrollView

            if conversation?.isTyping == true && !isSelecting {
                peerTypingBar
            }

            if isSelecting {
                selectionBar
            } else {
                inputBar
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                navTitleView
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isSelecting {
                    Button("Cancel") {
                        isSelecting = false
                        selectedIds.removeAll()
                    }
                } else {
                    Menu {
                        Button {
                            isSelecting = true
                        } label: { Label("Select Messages", systemImage: "checkmark.circle") }
                        if isGroup {
                            Button {
                                showGroupInfo = true
                            } label: { Label("Group Info", systemImage: "person.3") }
                        }
                        Button(role: .destructive) {
                            showClearDialog = true
                        } label: { Label("Clear Chat", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .onAppear {
            chatManager.markAsRead(peerId: peerId)
        }
        .onChange(of: conversation?.messages.count) { _ in
            chatManager.markAsRead(peerId: peerId)
        }
        .onDisappear {
            sendTypingStop()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                      maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { items in
            handlePickedItems(items)
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    chatManager.sendFile(at: url, to: peerId, replyTo: replyingTo, securityScoped: true)
                }
                replyingTo = nil
            case .failure(let error):
                chatManager.lastError = error.localizedDescription
            }
        }
        .quickLookPreview($quickLookURL)
        .sheet(item: $videoURL) { item in
            VideoPlayerSheet(url: item.url)
        }
        .sheet(item: $selectTextItem) { item in
            SelectableTextSheet(text: item.text)
        }
        .sheet(item: $shareURL) { item in
            ActivityView(items: [item.url])
        }
        .sheet(item: $exportURL) { item in
            ExportPickerView(url: item.url)
        }
        .fullScreenCover(item: $fullImage) { item in
            FullScreenImageView(image: item.image)
        }
        .sheet(isPresented: $showGroupInfo) {
            GroupInfoView(groupId: peerId)
                .environmentObject(chatManager)
        }
        .confirmationDialog(deleteTitle, isPresented: $showDeleteDialog, titleVisibility: .visible) {
            Button("Delete for me", role: .destructive) {
                performDelete(forEveryone: false)
            }
            Button(isGroup ? "Delete for everyone" : "Delete for me and \(conversation?.peer.displayName ?? "peer")", role: .destructive) {
                performDelete(forEveryone: true)
            }
            Button("Cancel", role: .cancel) { pendingDelete.removeAll() }
        }
        .confirmationDialog("Clear all messages in this chat?", isPresented: $showClearDialog, titleVisibility: .visible) {
            Button("Clear for me", role: .destructive) {
                chatManager.clearChat(peerId, forEveryone: false)
            }
            Button(isGroup ? "Clear for everyone" : "Clear for both sides", role: .destructive) {
                chatManager.clearChat(peerId, forEveryone: true)
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("SecureChat", isPresented: Binding(
            get: { chatManager.lastError != nil },
            set: { if !$0 { chatManager.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { chatManager.lastError = nil }
        } message: {
            Text(chatManager.lastError ?? "")
        }
    }

    private var deleteTitle: String {
        let n = pendingDelete.count
        return n == 1 ? "Delete message?" : "Delete \(n) messages?"
    }

    // MARK: - Navigation Title

    private var navTitleView: some View {
        HStack(spacing: 8) {
            AvatarView(name: conversation?.peer.displayName ?? "?", size: 32,
                       imageData: isGroup ? conversation?.group?.avatarData : conversation?.peer.avatarData,
                       isGroup: isGroup)

            VStack(alignment: .leading, spacing: 1) {
                Text(conversation?.peer.displayName ?? "Unknown")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                if let g = conversation?.group {
                    let online = g.members.filter { $0 != chatManager.localDeviceId && chatManager.isConnected($0) }.count
                    Text("\(g.members.count) members" + (online > 0 ? ", \(online) online" : ""))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else if conversation?.peer.isOnline == true {
                    Text("online")
                        .font(.caption2)
                        .foregroundColor(TelegramColors.tint)
                } else if let lastSeen = conversation?.peer.lastSeen {
                    Text("last seen \(lastSeen.chatListTimestamp)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onTapGesture {
            if isGroup { showGroupInfo = true }
        }
    }

    // MARK: - Messages Scroll View

    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    encryptionBanner

                    if let conv = conversation {
                        ForEach(groupedMessages(conv.messages), id: \.id) { group in
                            DateSeparatorView(date: group.date)

                            ForEach(group.messages) { message in
                                messageRow(message)
                                    .id(message.id)
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .background(Color(.systemGroupedBackground))
            .onChange(of: conversation?.messages.count) { _ in
                if let lastId = conversation?.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
            .onChange(of: scrollRequest) { target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .center) }
                highlightedId = target
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if highlightedId == target { highlightedId = nil }
                }
                scrollRequest = nil
            }
            .onAppear {
                if let lastId = conversation?.messages.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
            .simultaneousGesture(TapGesture().onEnded { isInputFocused = false })
        }
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        let isOutgoing = message.senderId == chatManager.localDeviceId
        let showSender = isGroup && !isOutgoing
        HStack(alignment: .bottom, spacing: 6) {
            if isSelecting {
                Image(systemName: selectedIds.contains(message.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(selectedIds.contains(message.id) ? TelegramColors.tint : .secondary)
                    .padding(.leading, 4)
            }
            if showSender {
                AvatarView(name: chatManager.senderName(for: message, in: peerId), size: 28,
                           imageData: chatManager.avatar(for: message.senderId))
            }
            MessageBubbleView(
                message: message,
                isOutgoing: isOutgoing,
                senderName: showSender ? chatManager.senderName(for: message, in: peerId) : nil,
                progress: chatManager.transferProgress[message.id],
                highlighted: highlightedId == message.id,
                onTapReply: { id in scrollRequest = id },
                onOpenAttachment: { msg in
                    if isSelecting { toggleSelection(msg.id) } else { open(msg) }
                },
                onRetry: { chatManager.resend(message.id, in: peerId) }
            )
            .allowsHitTesting(!isSelecting)
            .contextMenu { contextMenu(for: message, isOutgoing: isOutgoing) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting { toggleSelection(message.id) }
        }
    }

    @ViewBuilder
    private func contextMenu(for message: ChatMessage, isOutgoing: Bool) -> some View {
        Button {
            replyingTo = message
            isInputFocused = true
        } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }

        if message.contentType == .text {
            Button {
                UIPasteboard.general.string = message.text
            } label: { Label("Copy", systemImage: "doc.on.doc") }
            Button {
                selectTextItem = IdentifiableText(text: message.text)
            } label: { Label("Select Text", systemImage: "selection.pin.in.out") }
        } else if message.contentType == .image, let img = AttachmentImageCache.image(for: message) {
            Button {
                UIPasteboard.general.image = img
            } label: { Label("Copy Image", systemImage: "doc.on.doc") }
        }

        if let a = message.attachment, a.isAvailable,
           let url = AttachmentStore.fileURL(for: a, messageId: message.id) {
            Button { open(message) } label: { Label("Open", systemImage: "eye") }
            Button { shareURL = IdentifiableURL(url: url) } label: { Label("Share…", systemImage: "square.and.arrow.up") }
            Button { exportURL = IdentifiableURL(url: url) } label: { Label("Save to Files…", systemImage: "square.and.arrow.down") }
        }

        if isOutgoing && (message.status == .failed || message.pendingRecipients != nil) {
            Button {
                chatManager.resend(message.id, in: peerId)
            } label: { Label("Resend", systemImage: "arrow.clockwise") }
        }

        Button {
            isSelecting = true
            selectedIds = [message.id]
        } label: { Label("Select", systemImage: "checkmark.circle") }

        Button(role: .destructive) {
            pendingDelete = [message.id]
            showDeleteDialog = true
        } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: - Encryption Banner

    private var encryptionBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.caption2)
            Text(isGroup
                 ? "Group messages are end-to-end encrypted separately for every member."
                 : "Messages are end-to-end encrypted. No one outside this chat can read them.")
                .font(.caption2)
        }
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .padding(.vertical, 12)
    }

    // MARK: - Typing Bar

    private var peerTypingBar: some View {
        HStack(spacing: 6) {
            TypingIndicatorView()
            Text("\(conversation?.peer.displayName ?? "Peer") is typing…")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(.systemBackground))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Selection Bar

    private var selectionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button {
                    if let conv = conversation {
                        if selectedIds.count == conv.messages.count {
                            selectedIds.removeAll()
                        } else {
                            selectedIds = Set(conv.messages.map(\.id))
                        }
                    }
                } label: {
                    Text(selectedIds.count == (conversation?.messages.count ?? -1) ? "Deselect All" : "Select All")
                }
                Spacer()
                Text("\(selectedIds.count) selected")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Button(role: .destructive) {
                    pendingDelete = selectedIds
                    showDeleteDialog = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selectedIds.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()

            if let reply = replyingTo {
                HStack(spacing: 8) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .foregroundColor(TelegramColors.tint)
                    ReplyQuoteView(sender: chatManager.senderName(for: reply, in: peerId),
                                   text: reply.previewText, isOutgoing: false)
                    Spacer()
                    Button {
                        replyingTo = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .background(Color(.systemBackground))
            }

            HStack(alignment: .bottom, spacing: 6) {
                Menu {
                    Button {
                        showPhotoPicker = true
                    } label: { Label("Photo or Video", systemImage: "photo.on.rectangle") }
                    Button {
                        showFileImporter = true
                    } label: { Label("File", systemImage: "doc") }
                } label: {
                    Image(systemName: "paperclip.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(TelegramColors.tint)
                }

                composer

                if !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: sendTextMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(TelegramColors.tint)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(.systemBackground))
            .animation(.easeInOut(duration: 0.15), value: messageText.isEmpty)
        }
    }

    @ViewBuilder
    private var composer: some View {
        #if targetEnvironment(macCatalyst)
        MacComposerView(text: $messageText, onSubmit: sendTextMessage)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .leading) {
                if messageText.isEmpty {
                    Text("Message  (Enter to send, Shift+Enter for new line)")
                        .foregroundColor(.secondary)
                        .padding(.leading, 12)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: messageText) { newValue in
                handleTypingChange(newValue)
            }
        #else
        TextField("Message", text: $messageText, axis: .vertical)
            .lineLimit(1...6)
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .focused($isInputFocused)
            .onChange(of: messageText) { newValue in
                handleTypingChange(newValue)
            }
        #endif
    }

    // MARK: - Actions

    private func sendTextMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chatManager.sendMessage(text, to: peerId, replyTo: replyingTo)
        messageText = ""
        replyingTo = nil
        sendTypingStop()
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
    }

    private func performDelete(forEveryone: Bool) {
        chatManager.deleteMessages(pendingDelete, in: peerId, forEveryone: forEveryone)
        selectedIds.subtract(pendingDelete)
        pendingDelete.removeAll()
        if selectedIds.isEmpty { isSelecting = false }
    }

    private func open(_ message: ChatMessage) {
        guard let a = message.attachment, a.isAvailable,
              let url = AttachmentStore.fileURL(for: a, messageId: message.id) else { return }
        if message.contentType == .image, let img = AttachmentImageCache.image(for: message) {
            fullImage = IdentifiableImage(image: img)
        } else if a.isVideo {
            videoURL = IdentifiableURL(url: url)
        } else {
            quickLookURL = url
        }
    }

    private func handlePickedItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let reply = replyingTo
        replyingTo = nil
        let convId = peerId
        Task {
            for item in items {
                let isMovie = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
                if isMovie {
                    if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                        let ext = movie.url.pathExtension
                        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "video/quicktime"
                        let name = "VID_\(DateFormatter.fileTimestamp.string(from: Date())).\(ext.isEmpty ? "mov" : ext)"
                        await MainActor.run {
                            chatManager.sendFile(at: movie.url, filename: name, mimeType: mime, to: convId, replyTo: reply)
                        }
                    } else {
                        await MainActor.run { chatManager.lastError = "Could not load the video" }
                    }
                } else if let data = try? await item.loadTransferable(type: Data.self) {
                    let filename = "IMG_\(DateFormatter.fileTimestamp.string(from: Date())).jpg"
                    await MainActor.run {
                        chatManager.sendImage(data, filename: filename, to: convId, replyTo: reply)
                    }
                }
            }
            await MainActor.run { photoItems = [] }
        }
    }

    private func handleTypingChange(_ text: String) {
        guard !isGroup else { return }
        typingTask?.cancel()

        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chatManager.sendTypingIndicator(to: peerId, isTyping: true)

            typingTask = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                chatManager.sendTypingIndicator(to: peerId, isTyping: false)
            }
        } else {
            sendTypingStop()
        }
    }

    private func sendTypingStop() {
        typingTask?.cancel()
        typingTask = nil
        if !isGroup {
            chatManager.sendTypingIndicator(to: peerId, isTyping: false)
        }
    }

    // MARK: - Message Grouping

    private struct MessageGroup: Identifiable {
        let id: String
        let date: Date
        var messages: [ChatMessage]
    }

    private func groupedMessages(_ messages: [ChatMessage]) -> [MessageGroup] {
        let calendar = Calendar.current
        var groups: [String: MessageGroup] = [:]
        var order: [String] = []

        for msg in messages {
            let comps = calendar.dateComponents([.year, .month, .day], from: msg.timestamp)
            let key = "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"

            if groups[key] != nil {
                groups[key]!.messages.append(msg)
            } else {
                let dayStart = calendar.startOfDay(for: msg.timestamp)
                groups[key] = MessageGroup(id: key, date: dayStart, messages: [msg])
                order.append(key)
            }
        }

        return order.compactMap { groups[$0] }
    }
}

struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

// MARK: - DateFormatter Extension

extension DateFormatter {
    static let fileTimestamp: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        return fmt
    }()
}
