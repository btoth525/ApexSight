import SwiftUI
import UIKit

struct ServerSwitcherView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var allSessions: [FrigateSession] = []
    @State private var showAddServer = false

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                    SectionHeader("Servers", subtitle: "Switch between Frigate instances")

                    if allSessions.isEmpty {
                        GlassCard {
                            EmptyStateView(
                                icon: "server.rack",
                                title: "No servers",
                                message: "Add a Frigate server to get started."
                            )
                        }
                    } else {
                        VStack(spacing: GlassTheme.Space.m) {
                            ForEach(allSessions, id: \.baseURL) { session in
                                serverRow(session)
                            }
                        }
                    }

                    Button {
                        showAddServer = true
                    } label: {
                        Label("Add Server", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassButtonStyle())
                }
                .padding(GlassTheme.Space.l)
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
        return HStack(spacing: GlassTheme.Space.m) {
            StatusDot(state: isActive ? .live : .offline)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.baseURL.host() ?? session.baseURL.absoluteString)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GlassTheme.primary)
                Text(isActive ? "\(session.username) · Active" : session.username)
                    .font(.footnote)
                    .foregroundStyle(GlassTheme.secondary)
            }
            Spacer(minLength: GlassTheme.Space.s)
            if !isActive {
                Button("Switch") {
                    appState.switchTo(session: session)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GlassTheme.accent)
            }
            Button {
                appState.keychain.remove(session: session)
                allSessions = appState.keychain.loadAllSessions()
                if isActive {
                    // Pop this pushed screen first — otherwise signing out leaves a
                    // blank detail view stranded on top of the re-rendered root.
                    dismiss()
                    appState.signOut()
                }
            } label: {
                Image(systemName: "trash")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GlassTheme.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(GlassTheme.Space.l)
        .background(GlassTheme.surface, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous))
        .cardStroke()
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous)
                    .strokeBorder(GlassTheme.accent.opacity(0.55), lineWidth: 1)
            }
        }
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
                GlassBackground()
                VStack(spacing: GlassTheme.Space.l) {
                    GlassCard {
                        VStack(spacing: GlassTheme.Space.m) {
                            field("Server URL", text: $baseURL, keyboard: .URL)
                            field("Username", text: $username, keyboard: .default)
                            SecureField("Password", text: $password)
                                .font(.body)
                                .foregroundStyle(GlassTheme.primary)
                                .padding(GlassTheme.Space.m)
                                .background(GlassTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous))
                                .cardStroke(GlassTheme.Radius.chip)
                        }
                    }
                    if let err = error {
                        HStack(spacing: GlassTheme.Space.s) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(GlassTheme.red)
                            Text(err)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(GlassTheme.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, GlassTheme.Space.l)
                    }
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack(spacing: GlassTheme.Space.s) {
                            if isLoading { ProgressView().tint(.white) }
                            Text("Connect")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(isLoading || baseURL.isEmpty)
                    .opacity(isLoading || baseURL.isEmpty ? 0.5 : 1)
                    .padding(.horizontal, GlassTheme.Space.l)
                    Spacer()
                }
                .padding(.top, GlassTheme.Space.l)
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
            .font(.body)
            .foregroundStyle(GlassTheme.primary)
            .padding(GlassTheme.Space.m)
            .background(GlassTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous))
            .cardStroke(GlassTheme.Radius.chip)
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
