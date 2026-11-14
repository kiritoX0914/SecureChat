// SecureChatApp.swift
// SecureChat – LAN End-to-End Encrypted Messenger
// App entry point

import SwiftUI
import UIKit

@main
struct SecureChatApp: App {
    @StateObject private var chatManager: ChatManager
    @Environment(\.scenePhase) private var scenePhase

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
            #if targetEnvironment(macCatalyst)
            // UIDevice.current.name is a generic "iPad" on Catalyst
            let host = ProcessInfo.processInfo.hostName
            let short = host.hasSuffix(".local") ? String(host.dropLast(6)) : host
            return short.replacingOccurrences(of: "-", with: " ")
            #elseif canImport(UIKit)
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
                #if targetEnvironment(macCatalyst)
                .frame(minWidth: 800, minHeight: 560)
                #endif
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                chatManager.appDidBecomeActive()
            case .background:
                chatManager.appDidEnterBackground()
            default:
                break
            }
        }
    }
}
