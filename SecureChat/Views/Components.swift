// Components.swift
// SecureChat – LAN End-to-End Encrypted Messenger
// Reusable SwiftUI components (Telegram-inspired design)

import SwiftUI
import UIKit
import AVKit
import UniformTypeIdentifiers

// MARK: - Telegram-style Colors

enum TelegramColors {
    static let tint = Color(red: 0.0, green: 0.48, blue: 1.0)

    /// Palette used for avatar backgrounds, indexed by name hash
    static let avatarColors: [Color] = [
        Color(red: 0.20, green: 0.59, blue: 0.86),   // blue
        Color(red: 0.90, green: 0.56, blue: 0.22),   // orange
        Color(red: 0.56, green: 0.36, blue: 0.76),   // violet
        Color(red: 0.34, green: 0.73, blue: 0.36),   // green
        Color(red: 0.13, green: 0.73, blue: 0.73),   // cyan
        Color(red: 0.87, green: 0.40, blue: 0.57),   // pink
        Color(red: 0.85, green: 0.33, blue: 0.33),   // red
    ]

    static func avatarColor(for name: String) -> Color {
        let hash = abs(name.hashValue)
        return avatarColors[hash % avatarColors.count]
    }

    static let outgoingBubble = Color(red: 0.0, green: 0.48, blue: 1.0)
    static let incomingBubble = Color(.systemGray6)
}

// MARK: - AvatarView

struct AvatarView: View {
    let name: String
    var size: CGFloat = 48
    var imageData: Data? = nil
    var isGroup: Bool = false

    private var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "?" : String(trimmed.prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Circle()
                    .fill(TelegramColors.avatarColor(for: name))
                if isGroup {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: size * 0.34, weight: .semibold))
                        .foregroundColor(.white)
                } else {
                    Text(initial)
                        .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - Attachment image cache

enum AttachmentImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 120
        return c
    }()

    static func image(for message: ChatMessage) -> UIImage? {
        guard let a = message.attachment else { return nil }
        let key = message.id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        var image: UIImage?
        if let rel = a.localFile, a.isComplete ?? true {
            image = UIImage(contentsOfFile: AttachmentStore.location(rel).path)
        }
        if image == nil, let data = a.data {
            image = UIImage(data: data)
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

// MARK: - MessageBubbleView

struct MessageBubbleView: View {
    let message: ChatMessage
    let isOutgoing: Bool
    var senderName: String? = nil          // shown for incoming group messages
    var progress: Double? = nil
    var highlighted: Bool = false
    var onTapReply: ((UUID) -> Void)? = nil
    var onOpenAttachment: ((ChatMessage) -> Void)? = nil
    var onRetry: (() -> Void)? = nil

    private var foreground: Color { isOutgoing ? .white : .primary }

    var body: some View {
        HStack {
            if isOutgoing { Spacer(minLength: 60) }

            VStack(alignment: .leading, spacing: 4) {
                if let senderName, !isOutgoing {
                    Text(senderName)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(TelegramColors.avatarColor(for: senderName))
                }

                if message.replyToId != nil {
                    ReplyQuoteView(sender: message.replyToSender ?? "",
                                   text: message.replyToText ?? "",
                                   isOutgoing: isOutgoing)
                        .onTapGesture {
                            if let id = message.replyToId { onTapReply?(id) }
                        }
                }

                switch message.contentType {
                case .image:
                    ImageContentView(message: message, isOutgoing: isOutgoing)
                        .onTapGesture { onOpenAttachment?(message) }
                case .file:
                    if message.isVideo {
                        VideoContentView(message: message, isOutgoing: isOutgoing, progress: progress)
                            .onTapGesture { onOpenAttachment?(message) }
                    } else {
                        FileContentView(message: message, isOutgoing: isOutgoing, progress: progress)
                            .onTapGesture { onOpenAttachment?(message) }
                    }
                case .text:
                    Text(message.text)
                        .font(.body)
                        .foregroundColor(foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                HStack(spacing: 3) {
                    Spacer(minLength: 0)
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(isOutgoing ? .white.opacity(0.7) : .secondary)

                    if isOutgoing {
                        StatusIconView(status: message.status)
                        if message.status == .failed, let onRetry {
                            Button(action: onRetry) {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(.white)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isOutgoing ? TelegramColors.outgoingBubble : TelegramColors.incomingBubble
            )
            .clipShape(BubbleShape(isOutgoing: isOutgoing))
            .overlay(
                BubbleShape(isOutgoing: isOutgoing)
                    .stroke(Color.yellow, lineWidth: highlighted ? 3 : 0)
            )

            if !isOutgoing { Spacer(minLength: 60) }
        }
    }
}

// MARK: - Reply quote

struct ReplyQuoteView: View {
    let sender: String
    let text: String
    let isOutgoing: Bool

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isOutgoing ? Color.white : TelegramColors.tint)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(sender)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(isOutgoing ? .white : TelegramColors.tint)
                    .lineLimit(1)
                Text(text)
                    .font(.caption)
                    .foregroundColor(isOutgoing ? .white.opacity(0.85) : .secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isOutgoing ? Color.white.opacity(0.15) : TelegramColors.tint.opacity(0.08))
        )
        .frame(maxWidth: 260, alignment: .leading)
    }
}

// MARK: - ImageContentView (inside bubble)

struct ImageContentView: View {
    let message: ChatMessage
    let isOutgoing: Bool

    var body: some View {
        Group {
            if let uiImage = AttachmentImageCache.image(for: message) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: 220, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let thumb = message.attachment?.thumbnailData,
                      let uiThumb = UIImage(data: thumb) {
                Image(uiImage: uiThumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: 220, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "photo.fill")
                    Text("Photo")
                }
                .foregroundColor(isOutgoing ? .white : .primary)
            }
        }
    }
}

// MARK: - VideoContentView (inside bubble)

struct VideoContentView: View {
    let message: ChatMessage
    let isOutgoing: Bool
    var progress: Double?

    private var durationText: String? {
        guard let d = message.attachment?.duration, d.isFinite, d > 0 else { return nil }
        let total = Int(d.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var body: some View {
        ZStack {
            if let thumb = message.attachment?.thumbnailData, let img = UIImage(data: thumb) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 220, height: 160)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.black.opacity(0.8))
                    .frame(width: 220, height: 160)
            }

            if let progress {
                TransferRing(progress: progress)
            } else if message.attachment?.isAvailable == true {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.white, Color.black.opacity(0.4))
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "icloud.and.arrow.down")
                    Text("Waiting…").font(.caption2)
                }
                .foregroundColor(.white)
            }

            VStack {
                Spacer()
                HStack {
                    if let durationText {
                        Text(durationText)
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Text(message.attachment?.formattedSize ?? "")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Capsule())
                }
                .foregroundColor(.white)
                .padding(6)
            }
        }
        .frame(width: 220, height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct TransferRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.45))
                .frame(width: 48, height: 48)
            Circle()
                .stroke(Color.white.opacity(0.3), lineWidth: 3)
                .frame(width: 38, height: 38)
            Circle()
                .trim(from: 0, to: CGFloat(max(0.02, min(1, progress))))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 38, height: 38)
            Text("\(Int(progress * 100))%")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundColor(.white)
        }
    }
}

// MARK: - FullScreenImageView

struct FullScreenImageView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in scale = value }
                            .onEnded { _ in
                                withAnimation { scale = max(1.0, scale) }
                            }
                    )
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: Image(uiImage: image),
                              preview: SharePreview("Photo", image: Image(uiImage: image)))
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

// MARK: - FileContentView (inside bubble)

struct FileContentView: View {
    let message: ChatMessage
    let isOutgoing: Bool
    var progress: Double?

    var body: some View {
        if let attachment = message.attachment {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isOutgoing ? Color.white.opacity(0.15) : TelegramColors.tint.opacity(0.1))
                        .frame(width: 44, height: 44)
                    if let progress {
                        Circle()
                            .trim(from: 0, to: CGFloat(max(0.02, min(1, progress))))
                            .stroke(isOutgoing ? Color.white : TelegramColors.tint,
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: attachment.isAvailable ? attachment.fileIcon : "icloud.and.arrow.down")
                            .font(.title2)
                            .foregroundColor(isOutgoing ? .white : TelegramColors.tint)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(isOutgoing ? .white : .primary)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    Text(subtitle(attachment))
                        .font(.caption)
                        .foregroundColor(isOutgoing ? .white.opacity(0.7) : .secondary)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: 260)
            .contentShape(Rectangle())
        }
    }

    private func subtitle(_ a: Attachment) -> String {
        if let progress {
            return "\(Int(progress * 100))% of \(a.formattedSize)"
        }
        if !a.isAvailable { return "\(a.formattedSize) · waiting for sender" }
        return a.formattedSize
    }
}

// MARK: - BubbleShape

struct BubbleShape: Shape {
    let isOutgoing: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 16
        let tailRadius: CGFloat = 6

        if isOutgoing {
            return RoundedRectangle(cornerRadius: radius)
                .path(in: rect)
                .union(
                    Circle()
                        .path(in: CGRect(
                            x: rect.maxX - tailRadius,
                            y: rect.maxY - tailRadius * 2,
                            width: tailRadius * 2,
                            height: tailRadius * 2
                        ))
                )
        } else {
            return RoundedRectangle(cornerRadius: radius)
                .path(in: rect)
                .union(
                    Circle()
                        .path(in: CGRect(
                            x: rect.minX - tailRadius,
                            y: rect.maxY - tailRadius * 2,
                            width: tailRadius * 2,
                            height: tailRadius * 2
                        ))
                )
        }
    }
}

extension Path {
    func union(_ other: Path) -> Path {
        var copy = self
        copy.addPath(other)
        return copy
    }
}

// MARK: - StatusIconView

struct StatusIconView: View {
    let status: ChatMessage.Status

    var body: some View {
        switch status {
        case .sending:
            Image(systemName: "clock")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.7))
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
        case .delivered:
            HStack(spacing: -3) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.7))
        case .read:
            HStack(spacing: -3) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(.red)
        }
    }
}

// MARK: - TypingIndicatorView

struct TypingIndicatorView: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(TelegramColors.tint)
                    .frame(width: 6, height: 6)
                    .offset(y: bounceOffset(for: index))
            }
        }
        .onAppear {
            withAnimation(
                .easeInOut(duration: 0.5)
                .repeatForever(autoreverses: true)
            ) {
                phase = 1
            }
        }
    }

    private func bounceOffset(for index: Int) -> CGFloat {
        let delay = Double(index) * 0.15
        let progress = max(0, min(1, phase - CGFloat(delay)))
        return -4 * sin(.pi * progress)
    }
}

// MARK: - UnreadBadgeView

struct UnreadBadgeView: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(TelegramColors.tint)
                .clipShape(Capsule())
        }
    }
}

// MARK: - OnlineIndicatorView

struct OnlineIndicatorView: View {
    var size: CGFloat = 12

    var body: some View {
        Circle()
            .fill(Color.green)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(Color(.systemBackground), lineWidth: 2)
            )
    }
}

// MARK: - DateSeparatorView

struct DateSeparatorView: View {
    let date: Date

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            if !calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
                formatter.dateFormat = "MMM d, yyyy"
            }
            return formatter.string(from: date)
        }
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(.systemGray5))
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

// MARK: - EmptyStateView

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    var showSpinner: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundColor(.primary)

            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if showSpinner {
                ProgressView()
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: - Time Formatting Helper

extension Date {
    /// Returns a short time label like "2:30 PM", "Yesterday", or "Nov 8"
    var chatListTimestamp: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) {
            let fmt = DateFormatter()
            fmt.dateFormat = "h:mm a"
            return fmt.string(from: self)
        } else if calendar.isDateInYesterday(self) {
            return "Yesterday"
        } else if calendar.isDate(self, equalTo: Date(), toGranularity: .weekOfYear) {
            let fmt = DateFormatter()
            fmt.dateFormat = "EEEE"
            return fmt.string(from: self)
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"
            return fmt.string(from: self)
        }
    }
}

// MARK: - Identifiable wrappers

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct IdentifiableText: Identifiable {
    let id = UUID()
    let text: String
}

// MARK: - Selectable text (partial selection + copy)

struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.adjustsFontForContentSizeCategory = true
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        tv.dataDetectorTypes = [.link, .phoneNumber]
        tv.text = text
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
    }
}

struct SelectableTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            SelectableTextView(text: text)
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(copied ? "Copied" : "Copy All") {
                            UIPasteboard.general.string = text
                            copied = true
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }.fontWeight(.semibold)
                    }
                }
        }
    }
}

// MARK: - Share sheet / export

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// "Save to Files…" (iOS) / "Save…" (Mac) using the system export picker.
struct ExportPickerView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}

// MARK: - Video player

struct VideoPlayerSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var showExport = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                }
            }
            .onAppear {
                let p = AVPlayer(url: url)
                player = p
                p.play()
            }
            .onDisappear { player?.pause() }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button { showExport = true } label: { Image(systemName: "square.and.arrow.down") }
                        ShareLink(item: url)
                    }
                }
            }
            .sheet(isPresented: $showExport) { ExportPickerView(url: url) }
        }
    }
}

// MARK: - Photos picker video import

struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("VID_\(UUID().uuidString.prefix(8)).\(ext)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

// MARK: - Mac composer (Enter = send, Shift+Enter = newline)

#if targetEnvironment(macCatalyst)
final class ComposerTextView: UITextView {
    var onSubmit: (() -> Void)?
    private(set) var lastModifiers: UIKeyModifierFlags = []

    private func isReturn(_ presses: Set<UIPress>) -> UIKey? {
        guard let key = presses.first?.key else { return nil }
        if key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter { return key }
        return nil
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let key = presses.first?.key { lastModifiers = key.modifierFlags }
        if markedTextRange == nil, let key = isReturn(presses) {
            if key.modifierFlags.contains(.shift) || key.modifierFlags.contains(.alternate) {
                insertText("\n")
            } else {
                onSubmit?()
            }
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        lastModifiers = []
        if markedTextRange == nil, isReturn(presses) != nil { return }
        super.pressesEnded(presses, with: event)
    }
}

struct MacComposerView: UIViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerTextView {
        let tv = ComposerTextView()
        tv.delegate = context.coordinator
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.backgroundColor = .clear
        tv.isScrollEnabled = true
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        tv.onSubmit = onSubmit
        tv.text = text
        return tv
    }

    func updateUIView(_ tv: ComposerTextView, context: Context) {
        context.coordinator.parent = self
        if tv.text != text { tv.text = text }
        tv.onSubmit = onSubmit
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let line = uiView.font?.lineHeight ?? 20
        let minH = line + 16
        let maxH = line * 6 + 16
        return CGSize(width: width, height: min(max(fitting.height, minH), maxH))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MacComposerView
        init(_ parent: MacComposerView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Fallback if the Return key arrives as text input instead of a key press.
            guard text == "\n", textView.markedTextRange == nil,
                  let tv = textView as? ComposerTextView else { return true }
            if tv.lastModifiers.contains(.shift) || tv.lastModifiers.contains(.alternate) { return true }
            parent.onSubmit()
            return false
        }
    }
}
#endif
