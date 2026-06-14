import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var doorbellManager: DoorbellManager
    @State private var selectedTab: Tab = .cameras
    @State private var activeCallCameraName: String?
    @State private var activeCallUUID: UUID?

    enum Tab {
        case cameras, events, settings
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    CameraGridView()
                        .navigationTitle("Cameras")
                        .navigationBarTitleDisplayMode(.large)
                }
                .tabItem {
                    Label("Cameras", systemImage: "video.fill")
                }
                .tag(Tab.cameras)

                NavigationStack {
                    ReviewView()
                        .navigationTitle("Events")
                        .navigationBarTitleDisplayMode(.large)
                }
                .tabItem {
                    Label("Events", systemImage: "clock.fill")
                }
                .tag(Tab.events)

                NavigationStack {
                    SettingsView()
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.large)
                }
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(Tab.settings)
            }
            .accentColor(.green)
        }
        .fullScreenCover(item: $doorbellManager.activeCall) { call in
            DoorbellCallView(cameraName: call.cameraName, callUUID: call.uuid)
                .environmentObject(doorbellManager)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthManager.shared)
        .environmentObject(DoorbellManager.shared)
}
