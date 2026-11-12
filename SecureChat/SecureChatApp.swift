// SecureChatApp.swift
// SecureChat – LAN End-to-End Encrypted Messenger
// App entry point

import SwiftUI
import UIKit

@main
struct SecureChatApp: App {
    @StateObject private var chatManager: ChatManager

    init() {
        let persistence = PersistenceManager()

        // Load or generate a stable device ID
        let deviceId: String
        if let saved = persistence.loadDeviceId() {
            deviceId = saved
        } else {
            let newId = UUID().uuidString
            persistence.saveDeviceId(newId)
            deviceId = newId
        }

        // Load or default display name
        let displayName = persistence.loadDisplayName() ?? {
            #if canImport(UIKit)
            return UIDevice.current.name
            #else
            return "User"
            #endif
        }()

        _chatManager = StateObject(wrappedValue: ChatManager(
            deviceId: deviceId,
            displayName: displayName,
            persistence: persistence
        ))
    }

    var body: some Scene {
        WindowGroup {
            ChatListView()
                .environmentObject(chatManager)
        }
    }
}
