// ConversationView.swift
// SecureChat – LAN End-to-End Encrypted Messenger
// Telegram-inspired chat conversation with image/file support

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct ConversationView: View {
    let peerId: String
    @EnvironmentObject var chatManager: ChatManager

    @State private var messageText = ""
    @State private var typingTask: Task<Void, Never>?
    @FocusState private var isInputFocused: Bool

    // Pickers
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showFilePicker = false

    // File save feedback
    @State private var savedFileName: String?
    @State private var showSavedToast = false

    private var conversation: Conversation? {
        chatManager.conversations[peerId]
    }

    var body: some View {
        VStack(spacing: 0) {
            messagesScrollView

            if conversation?.isTyping == true {
                peerTypingBar
            }

            inputBar
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                navTitleView
            }
        }
        .onAppear {
            chatManager.markAsRead(peerId: peerId)
        }
        .onDisappear {
            sendTypingStop()
        }
        .onChange(of: selectedPhotoItem) { newItem in
            handlePhotoSelection(newItem)
        }
        .sheet(isPresented: $showFilePicker) {
            DocumentPickerView { urls in
                for url in urls {
                    sendFileFromURL(url)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showSavedToast, let name = savedFileName {
                savedToast(name: name)
            }
        }
    }

    // MARK: - Navigation Title

    private var navTitleView: some View {
        HStack(spacing: 8) {
            AvatarView(name: conversation?.peer.displayName ?? "?", size: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(conversation?.peer.displayName ?? "Unknown")
                    .font(.subheadline.weight(.semibold))

                if conversation?.peer.isOnline == true {
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
                                MessageBubbleView(
                                    message: message,
                                    isOutgoing: message.senderId == chatManager.localDeviceId,
                                    onSaveFile: { attachment in
                                        saveAttachmentToFiles(attachment)
                                    }
                                )
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
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
            .onAppear {
                if let lastId = conversation?.messages.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
            .onTapGesture {
                isInputFocused = false
            }
        }
    }

    // MARK: - Encryption Banner

    private var encryptionBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.caption2)
            Text("Messages are end-to-end encrypted. No one outside this chat can read them.")
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

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(alignment: .bottom, spacing: 6) {
                // Photo picker button
                PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .any(of: [.images, .screenshots])
                ) {
                    Image(systemName: "photo.circle.fill")
                        .font(.system(size: 26))
                        .foregroundColor(TelegramColors.tint)
                }

                // File picker button
                Button {
                    showFilePicker = true
                } label: {
                    Image(systemName: "paperclip.circle.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.orange)
                }

                // Text input
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

                // Send button
                if !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: sendTextMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(TelegramColors.tint)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(.systemBackground))
            .animation(.easeInOut(duration: 0.15), value: messageText.isEmpty)
        }
    }

    // MARK: - Saved Toast

    private func savedToast(name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text("Saved \(name)")
                .font(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .padding(.bottom, 80)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Actions

    private func sendTextMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chatManager.sendMessage(text, to: peerId)
        messageText = ""
        sendTypingStop()
    }

    private func handlePhotoSelection(_ item: PhotosPickerItem?) {
        guard let item = item else { return }

        Task {
            if let data = try? await item.loadTransferable(type: Data.self) {
                let filename = "IMG_\(DateFormatter.fileTimestamp.string(from: Date())).jpg"
                await MainActor.run {
                    chatManager.sendImage(data, filename: filename, to: peerId)
                }
            }
            // Reset selection so the same photo can be re-selected
            await MainActor.run {
                selectedPhotoItem = nil
            }
        }
    }

    private func sendFileFromURL(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let data = try Data(contentsOf: url)
            let filename = url.lastPathComponent
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            chatManager.sendFile(data, filename: filename, mimeType: mimeType, to: peerId)
        } catch {
            print("[ConversationView] Failed to read file: \(error)")
        }
    }

    private func saveAttachmentToFiles(_ attachment: Attachment) {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(attachment.filename)

        do {
            try attachment.data.write(to: fileURL)

            // Use UIActivityViewController to let the user save/share
            let activityVC = UIActivityViewController(
                activityItems: [fileURL],
                applicationActivities: nil
            )
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? windowScene.windows.first?.rootViewController {
                var topVC = rootVC
                while let presented = topVC.presentedViewController {
                    topVC = presented
                }
                if let popover = activityVC.popoverPresentationController {
                    popover.sourceView = topVC.view
                    popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
                    popover.permittedArrowDirections = []
                }
                topVC.present(activityVC, animated: true)
            }

            savedFileName = attachment.filename
            withAnimation { showSavedToast = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { showSavedToast = false }
            }
        } catch {
            print("[ConversationView] Failed to save file: \(error)")
        }
    }

    private func handleTypingChange(_ text: String) {
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
        chatManager.sendTypingIndicator(to: peerId, isTyping: false)
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

// MARK: - DateFormatter Extension

extension DateFormatter {
    static let fileTimestamp: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        return fmt
    }()
}

// MARK: - DocumentPickerView (UIKit wrapper)

struct DocumentPickerView: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.item]  // All file types
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}
