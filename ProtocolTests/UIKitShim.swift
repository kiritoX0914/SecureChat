// Minimal UIKit stand-ins so ChatManager.swift can be compiled as a macOS
// command-line tool for headless protocol tests. Not part of the app.
import Foundation
import CoreGraphics

final class UIImage {
    let size: CGSize = .zero
    init?(data: Data) { return nil }
    init(cgImage: CGImage) {}
    func jpegData(compressionQuality: CGFloat) -> Data? { nil }
    func draw(in rect: CGRect) {}
}

struct UIBackgroundTaskIdentifier: Equatable {
    let raw: Int
    static let invalid = UIBackgroundTaskIdentifier(raw: 0)
}

final class UIApplication {
    static let shared = UIApplication()
    func beginBackgroundTask(withName name: String?, expirationHandler: (() -> Void)?) -> UIBackgroundTaskIdentifier {
        UIBackgroundTaskIdentifier(raw: 1)
    }
    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {}
}

final class UIGraphicsImageRendererFormat {
    var scale: CGFloat = 1
}

final class UIGraphicsImageRenderer {
    init(size: CGSize, format: UIGraphicsImageRendererFormat) {}
    func image(actions: (Any) -> Void) -> UIImage { fatalError("not used in tests") }
}
