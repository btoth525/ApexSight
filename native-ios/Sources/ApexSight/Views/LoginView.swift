import SwiftUI
import UIKit

struct LoginView: View {
    @EnvironmentObject private var appState: AppState
    @State private var baseURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @FocusState private var focus: Field?
    private enum Field { case url, username, password }

    var body: some View {
        ZStack {
            GlassBackground()
            // Scrollable so the software keyboard can't cover the lower fields / Connect button on
            // short viewports (iPhone SE, landscape); the minHeight keeps the content centered when
            // there's room, exactly as before.
            GeometryReader { proxy in
              ScrollView {
                VStack(spacing: GlassTheme.Space.xl) {
                    Spacer(minLength: 0)

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
                    .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.7).delay(0.1), value: appeared)

                    Text("ApexSight")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .foregroundStyle(GlassTheme.primary)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 12)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.4).delay(0.25), value: appeared)

                    Text("Native Frigate control")
                        .font(.subheadline)
                        .foregroundStyle(GlassTheme.secondary)
                        .opacity(appeared ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.4).delay(0.35), value: appeared)
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
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .accessibilityElement(children: .combine)
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
                    .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: appState.errorMessage)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: appState.isLoading)
                }
                .padding(.horizontal, GlassTheme.Space.l)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 24)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.4), value: appeared)

                Spacer(minLength: 0)

                Text("Connects directly to your Frigate instance.\nNo data leaves your network.")
                    .font(.footnote)
                    .foregroundStyle(GlassTheme.tertiary)
                    .multilineTextAlignment(.center)
                    .opacity(appeared ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.4).delay(0.55), value: appeared)
                }
                .frame(minHeight: proxy.size.height)
                .frame(maxWidth: .infinity)
              }
              .scrollBounceBehavior(.basedOnSize)
              .scrollDismissesKeyboard(.interactively)
            }
        }
        // Buzz when a sign-in attempt fails so the error registers even if the user
        // isn't looking at the form's error line.
        .sensoryFeedback(.error, trigger: appState.errorMessage) { old, new in
            old == nil && new != nil
        }
        .onAppear { appeared = true }
        .task {
            // Let the entrance animation settle before raising the keyboard. A Task
            // (vs asyncAfter) cancels if the view leaves, so focus never lands on a
            // dismissed form.
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            if baseURL.isEmpty { focus = .url }
            else if username.isEmpty { focus = .username }
            else { focus = .password }
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
            // Let password managers and the keyboard offer the right autofill per field.
            .textContentType(keyboard == .URL ? .URL : .username)
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
                let wasFocused = focus == focusField
                showPassword.toggle()
                // Swapping SecureField <-> TextField rebuilds the field and drops the
                // keyboard; re-assert focus so the user can keep typing uninterrupted.
                if wasFocused {
                    DispatchQueue.main.async { focus = focusField }
                }
            } label: {
                Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                    .font(.subheadline)
                    .foregroundStyle(GlassTheme.secondary)
                    .hitTarget()
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
