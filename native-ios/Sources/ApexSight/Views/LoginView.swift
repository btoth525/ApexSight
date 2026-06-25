import SwiftUI
import UIKit

struct LoginView: View {
    @EnvironmentObject private var appState: AppState
    @State private var baseURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var appeared = false

    @FocusState private var focus: Field?
    private enum Field { case url, username, password }

    var body: some View {
        ZStack {
            GlassBackground()
            VStack(spacing: GlassTheme.Space.xl) {
                Spacer()

                // Logo + title
                VStack(spacing: GlassTheme.Space.m) {
                    ZStack {
                        Circle()
                            .fill(GlassTheme.surfaceHigh)
                            .frame(width: 96, height: 96)
                            .cardStroke(48)

                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 44, weight: .regular))
                            .foregroundStyle(GlassTheme.accent)
                    }
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.55, dampingFraction: 0.7).delay(0.1), value: appeared)

                    Text("ApexSight")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .foregroundStyle(GlassTheme.primary)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 12)
                        .animation(.easeOut(duration: 0.4).delay(0.25), value: appeared)

                    Text("Native Frigate control")
                        .font(.subheadline)
                        .foregroundStyle(GlassTheme.secondary)
                        .opacity(appeared ? 1 : 0)
                        .animation(.easeOut(duration: 0.4).delay(0.35), value: appeared)
                }

                // Form card
                GlassCard {
                    VStack(spacing: GlassTheme.Space.m) {
                        formField("Server URL", text: $baseURL, keyboard: .URL, focusField: .url, submitLabel: .next) {
                            focus = .username
                        }
                        formField("Username", text: $username, keyboard: .default, focusField: .username, submitLabel: .next) {
                            focus = .password
                        }
                        passwordField("Password", text: $password, focusField: .password, submitLabel: .go) {
                            submitIfReady()
                        }

                        if let error = appState.errorMessage {
                            HStack(spacing: GlassTheme.Space.s) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(GlassTheme.red)
                                Text(error)
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(GlassTheme.red)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button {
                            submitIfReady()
                        } label: {
                            HStack(spacing: GlassTheme.Space.s) {
                                if appState.isLoading {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "bolt.fill")
                                }
                                Text(appState.isLoading ? "Connecting…" : "Connect to Frigate")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PillButtonStyle())
                        .disabled(appState.isLoading || baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.horizontal, GlassTheme.Space.l)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 24)
                .animation(.easeOut(duration: 0.45).delay(0.4), value: appeared)

                Spacer()

                Text("Connects directly to your Frigate instance.\nNo data leaves your network.")
                    .font(.footnote)
                    .foregroundStyle(GlassTheme.tertiary)
                    .multilineTextAlignment(.center)
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.4).delay(0.55), value: appeared)
            }
        }
        .onAppear {
            appeared = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if baseURL.isEmpty { focus = .url }
                else if username.isEmpty { focus = .username }
                else { focus = .password }
            }
        }
    }

    private func submitIfReady() {
        guard !baseURL.trimmingCharacters(in: .whitespaces).isEmpty, !appState.isLoading else { return }
        focus = nil
        Task { await appState.signIn(baseURL: baseURL, username: username, password: password) }
    }

    private func formField(
        _ title: String,
        text: Binding<String>,
        keyboard: UIKeyboardType,
        focusField: Field,
        submitLabel: SubmitLabel,
        onSubmit: @escaping () -> Void
    ) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboard)
            .font(.body)
            .fontWeight(.medium)
            .foregroundStyle(GlassTheme.primary)
            .padding(GlassTheme.Space.l)
            .background(GlassTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous)
                    .stroke(focus == focusField ? GlassTheme.accent : GlassTheme.separator, lineWidth: focus == focusField ? 1.5 : 1)
            )
            .focused($focus, equals: focusField)
            .submitLabel(submitLabel)
            .onSubmit(onSubmit)
    }

    private func passwordField(
        _ title: String,
        text: Binding<String>,
        focusField: Field,
        submitLabel: SubmitLabel,
        onSubmit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: GlassTheme.Space.s) {
            Group {
                if showPassword {
                    TextField(title, text: text)
                } else {
                    SecureField(title, text: text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)
            .font(.body)
            .fontWeight(.medium)
            .foregroundStyle(GlassTheme.primary)
            .focused($focus, equals: focusField)
            .submitLabel(submitLabel)
            .onSubmit(onSubmit)

            Button {
                showPassword.toggle()
            } label: {
                Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                    .font(.subheadline)
                    .foregroundStyle(GlassTheme.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showPassword ? "Hide password" : "Show password")
        }
        .padding(GlassTheme.Space.l)
        .background(GlassTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous)
                .stroke(focus == focusField ? GlassTheme.accent : GlassTheme.separator, lineWidth: focus == focusField ? 1.5 : 1)
        )
    }
}
