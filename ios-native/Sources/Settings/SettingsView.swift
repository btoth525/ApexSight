import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var doorbellManager: DoorbellManager

    @State private var serverURL: String = UserDefaults.standard.string(forKey: "frigate_base_url") ?? ""
    @State private var editingURL = false
    @State private var copiedToken = false

    private var voipTokenDisplay: String {
        guard let t = doorbellManager.voipToken else { return "Not registered yet" }
        let s = t.prefix(8)
        let e = t.suffix(8)
        return "\(s)…\(e)"
    }

    var body: some View {
        List {
            // ── Server ────────────────────────────────────────────────────────
            Section("Server") {
                LabeledContent("URL") {
                    Text(serverURL.isEmpty ? "Not set" : serverURL)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Change Server URL") { editingURL = true }
            }

            // ── Doorbell ──────────────────────────────────────────────────────
            Section {
                LabeledContent("VoIP Token") {
                    Text(voipTokenDisplay)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                if let token = doorbellManager.voipToken {
                    Button {
                        UIPasteboard.general.string = token
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        copiedToken = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedToken = false }
                    } label: {
                        Label(copiedToken ? "Copied!" : "Copy Full Token", systemImage: copiedToken ? "checkmark" : "doc.on.doc")
                    }
                    .foregroundColor(copiedToken ? .green : .accentColor)
                }
            } header: {
                Text("Doorbell")
            } footer: {
                Text("Paste this token into your Home Assistant ring_doorbell.sh script to enable VoIP push notifications.")
            }

            // ── App ───────────────────────────────────────────────────────────
            Section("App") {
                LabeledContent("Version") {
                    Text(appVersion)
                        .foregroundColor(.secondary)
                }
                LabeledContent("Build") {
                    Text(buildNumber)
                        .foregroundColor(.secondary)
                }
            }

            // ── Account ───────────────────────────────────────────────────────
            Section {
                Button(role: .destructive) {
                    authManager.logout()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $editingURL) {
            ServerURLEditor(currentURL: $serverURL)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}

// MARK: - Server URL editor sheet

private struct ServerURLEditor: View {
    @Binding var currentURL: String
    @State private var draft = ""
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Frigate Server URL") {
                    TextField("https://frigate.example.com", text: $draft)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("Server Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            currentURL = trimmed
                            UserDefaults.standard.set(trimmed, forKey: "frigate_base_url")
                        }
                        dismiss()
                    }
                }
            }
            .onAppear { draft = currentURL }
        }
        .presentationDetents([.medium])
    }
}
