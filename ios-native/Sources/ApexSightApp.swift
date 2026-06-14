import SwiftUI
import PushKit
import CallKit
import AVFoundation

@main
struct ApexSightApp: App {
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var doorbellManager = DoorbellManager.shared

    init() {
        configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authManager.isAuthenticated {
                    ContentView()
                        .environmentObject(authManager)
                        .environmentObject(doorbellManager)
                } else {
                    LoginView()
                        .environmentObject(authManager)
                }
            }
            .onAppear {
                doorbellManager.registerForVoIPPushes()
            }
        }
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("[ApexSight] Audio session configuration failed: \(error)")
        }
    }
}
