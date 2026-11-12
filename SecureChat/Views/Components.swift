// Components.swift
// SecureChat – LAN End-to-End Encrypted Messenger
// Reusable SwiftUI components (Telegram-inspired design)

import SwiftUI
import UIKit

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

    private var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "?" : String(trimmed.prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(TelegramColors.avatarColor(for: name))
            Text(initial)
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - MessageBubbleView

struct MessageBubbleView: View {
    let message: ChatMessage
    let isOutgoing: Bool
    var onSaveFile: ((Attachment) -> Void)?

    var body: some View {
        HStack {
            if isOutgoing { Spacer(minLength: 60) }

            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                // Content based on type
                switch message.contentType {
                case .image:
                    ImageContentView(message: message, isOutgoing: isOutgoing)
                case .file:
                    FileContentView(
                        message: message,
                        isOutgoing: isOutgoing,
                        onSave: onSaveFile
                    )
                case .text:
                    Text(message.text)
                        .font(.body)
                        .foregroundColor(isOutgoing ? .white : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 3) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(isOutgoing ? .white.opacity(0.7) : .secondary)

                    if isOutgoing {
                        StatusIconView(status: message.status)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isOutgoing ? TelegramColors.outgoingBubble : TelegramColors.incomingBubble
            )
            .clipShape(BubbleShape(isOutgoing: isOutgoing))

            if !isOutgoing { Spacer(minLength: 60) }
        }
    }
}

// MARK: - ImageContentView (inside bubble)

struct ImageContentView: View {
    let message: ChatMessage
    let isOutgoing: Bool
    @State private var showFullScreen = false

    var body: some View {
        Group {
            if let attachment = message.attachment,
               let uiImage = UIImage(data: attachment.data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: 220, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { showFullScreen = true }
                    .fullScreenCover(isPresented: $showFullScreen) {
                        FullScreenImageView(image: uiImage)
                    }
            } else if let attachment = message.attachment,
                      let thumb = attachment.thumbnailData,
                      let uiThumb = UIImage(data: thumb) {
                // Fallback to thumbnail
                Image(uiImage: uiThumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: 220, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                // Placeholder
                HStack(spacing: 6) {
                    Image(systemName: "photo.fill")
                    Text("Photo")
                }
                .foregroundColor(isOutgoing ? .white : .primary)
            }
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
    var onSave: ((Attachment) -> Void)?

    var body: some View {
        if let attachment = message.attachment {
            HStack(spacing: 10) {
                // File icon
                Image(systemName: attachment.fileIcon)
                    .font(.title2)
                    .foregroundColor(isOutgoing ? .white : TelegramColors.tint)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isOutgoing ? Color.white.opacity(0.15) : TelegramColors.tint.opacity(0.1))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(isOutgoing ? .white : .primary)
                        .lineLimit(1)

                    Text(attachment.formattedSize)
                        .font(.caption)
                        .foregroundColor(isOutgoing ? .white.opacity(0.7) : .secondary)
                }

                Spacer(minLength: 0)

                // Save button
                Button {
                    onSave?(attachment)
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                        .foregroundColor(isOutgoing ? .white.opacity(0.8) : TelegramColors.tint)
                }
            }
            .frame(maxWidth: 240)
        }
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
