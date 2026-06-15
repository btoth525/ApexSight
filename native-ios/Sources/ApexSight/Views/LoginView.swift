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
            VStack(spacing: 18) {
                Spacer()

                // Logo + title
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [GlassTheme.cyan.opacity(0.3), .clear],
                                    center: .center,
                                    startRadius: 10,
                                    endRadius: 56
                                )
                            )
                            .frame(width: 112, height: 112)

                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 54, weight: .black))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [GlassTheme.cyan, GlassTheme.blue],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.55, dampingFraction: 0.7).delay(0.1), value: appeared)

                    Text("ApexSight")
                        .font(.system(size: 44, weight: .black, design: .rounded))
                        .foregroundStyle(GlassTheme.primary)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 12)
                        .animation(.easeOut(duration: 0.4).delay(0.25), value: appeared)

                    Text("Native Frigate control")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(GlassTheme.secondary)
                        .opacity(appeared ? 1 : 0)
                        .animation(.easeOut(duration: 0.4).delay(0.35), value: appeared)
                }

                // Form card
                GlassCard {
                    VStack(spacing: 14) {
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
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(GlassTheme.orange)
                                Text(error)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(GlassTheme.orange)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button {
                            submitIfReady()
                        } label: {
                            HStack(spacing: 10) {
                                if appState.isLoading {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "bolt.fill")
                                }
                                Text(appState.isLoading ? "Connecting…" : "Connect to Frigate")
                                    .fontWeight(.black)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PillButtonStyle(tint: GlassTheme.blue))
                        .disabled(appState.isLoading || baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.horizontal, 20)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 24)
                .animation(.easeOut(duration: 0.45).delay(0.4), value: appeared)

                Spacer()

                Text("Connects directly to your Frigate instance.\nNo data leaves your network.")
                    .font(.system(size: 12, weight: .semibold))
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
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(GlassTheme.primary)
            .padding(14)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(focus == focusField ? GlassTheme.cyan.opacity(0.6) : .clear, lineWidth: 1.5)
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
        HStack(spacing: 8) {
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
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(GlassTheme.primary)
            .focused($focus, equals: focusField)
            .submitLabel(submitLabel)
            .onSubmit(onSubmit)

            Button {
                showPassword.toggle()
            } label: {
                Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(GlassTheme.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showPassword ? "Hide password" : "Show password")
        }
        .padding(14)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(focus == focusField ? GlassTheme.cyan.opacity(0.6) : .clear, lineWidth: 1.5)
        )
    }
}
