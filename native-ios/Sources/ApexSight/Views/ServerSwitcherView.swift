import SwiftUI
import UIKit

struct ServerSwitcherView: View {
    @EnvironmentObject private var appState: AppState
    @State private var allSessions: [FrigateSession] = []
    @State private var showAddServer = false

    var body: some View {
        ZStack {
            GlassTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("Servers", systemImage: "server.rack")
                                .font(.system(size: 21, weight: .black))
                                .foregroundStyle(GlassTheme.primary)

                            ForEach(allSessions, id: \.baseURL) { session in
                                serverRow(session)
                            }

                            Button {
                                showAddServer = true
                            } label: {
                                Label("Add Server", systemImage: "plus.circle.fill")
                                    .font(.system(size: 15, weight: .black))
                                    .foregroundStyle(GlassTheme.cyan)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(GlassTheme.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(18)
            }
        }
        .navigationTitle("Servers")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .onAppear { allSessions = appState.keychain.loadAllSessions() }
        .sheet(isPresented: $showAddServer) {
            AddServerView { session in
                appState.keychain.save(session: session)
                allSessions = appState.keychain.loadAllSessions()
            }
        }
    }

    private func serverRow(_ session: FrigateSession) -> some View {
        let isActive = appState.session?.baseURL == session.baseURL
        return HStack(spacing: 12) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(isActive ? GlassTheme.green : GlassTheme.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.baseURL.host() ?? session.baseURL.absoluteString)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
                Text(session.username)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(GlassTheme.secondary)
            }
            Spacer()
            if !isActive {
                Button("Switch") {
                    appState.switchTo(session: session)
                }
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(GlassTheme.cyan)
            }
            Button {
                appState.keychain.remove(session: session)
                allSessions = appState.keychain.loadAllSessions()
                if isActive { appState.signOut() }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(GlassTheme.red)
            }
        }
        .padding(12)
        .background(isActive ? GlassTheme.green.opacity(0.08) : .white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var error: String?
    let onSave: (FrigateSession) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                GlassTheme.background.ignoresSafeArea()
                VStack(spacing: 18) {
                    GlassCard {
                        VStack(spacing: 14) {
                            field("Server URL", text: $baseURL, keyboard: .URL)
                            field("Username", text: $username, keyboard: .default)
                            SecureField("Password", text: $password)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(GlassTheme.primary)
                                .padding(14)
                                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    if let err = error {
                        Text(err)
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(GlassTheme.red)
                            .padding(.horizontal, 18)
                    }
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            if isLoading { ProgressView().tint(.black) }
                            Text("Connect")
                                .font(.system(size: 16, weight: .black))
                                .foregroundStyle(.black)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(GlassTheme.cyan, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading || baseURL.isEmpty)
                    .padding(.horizontal, 18)
                    Spacer()
                }
                .padding(.top, 18)
            }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .glassNavBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(keyboard)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(GlassTheme.primary)
            .padding(14)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func connect() async {
        isLoading = true
        error = nil
        do {
            let normalized = try FrigateSession.normalizedBaseURL(baseURL)
            let client = FrigateClient(baseURL: normalized)
            let token = try await client.login(username: username, password: password)
            let session = FrigateSession(baseURL: normalized, username: username, token: token, password: password)
            onSave(session)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
