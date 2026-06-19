import AuthenticationServices
import SwiftUI
import UIKit

/// ApexSight account sign-in / sign-up. On success it stores the account's private
/// ingest token as the push pairing code and (re)registers the device with the relay,
/// so alerts route only to this account.
struct AccountSignInView: View {
    @Environment(\.dismiss) private var dismiss
    var onSignedIn: () -> Void = {}

    @State private var isSignUp = true
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var relayURL: String { DeviceTokenStore.relayURL }

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 8) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 44, weight: .black))
                            .foregroundStyle(GlassTheme.cyan)
                        Text(isSignUp ? "Create your account" : "Welcome back")
                            .font(.system(size: 24, weight: .black))
                            .foregroundStyle(GlassTheme.primary)
                        Text("One account links your Frigate to all your Apple devices, privately.")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(GlassTheme.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 24)

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            field("Email", text: $email, isSecure: false, keyboard: .emailAddress, content: .username)
                            field("Password", text: $password, isSecure: true, keyboard: .default,
                                  content: isSignUp ? .newPassword : .password)

                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(GlassTheme.red)
                            }

                            Button {
                                Task { await submit() }
                            } label: {
                                HStack {
                                    if isWorking { ProgressView().tint(.black) }
                                    Text(isSignUp ? "Create account" : "Log in")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PillButtonStyle(tint: GlassTheme.cyan))
                            .disabled(isWorking || email.isEmpty || password.isEmpty)

                            SignInWithAppleButton(.signIn) { request in
                                request.requestedScopes = [.email]
                            } onCompletion: { result in
                                handleApple(result)
                            }
                            .signInWithAppleButtonStyle(.white)
                            .frame(height: 48)
                            .clipShape(Capsule())

                            Button(isSignUp ? "I already have an account" : "Create a new account") {
                                withAnimation { isSignUp.toggle(); errorMessage = nil }
                            }
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(GlassTheme.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 2)
                        }
                    }
                }
                .padding(16)
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func field(_ title: String, text: Binding<String>, isSecure: Bool,
                       keyboard: UIKeyboardType, content: UITextContentType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .heavy)).foregroundStyle(GlassTheme.secondary)
            Group {
                if isSecure {
                    SecureField("", text: text)
                } else {
                    TextField("", text: text)
                        .keyboardType(keyboard)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .textContentType(content)
            .padding(12)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(GlassTheme.primary)
        }
    }

    private func submit() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        let mail = email.trimmingCharacters(in: .whitespaces).lowercased()
        do {
            let session = isSignUp
                ? try await AccountClient.signup(relayURL: relayURL, email: mail, password: password)
                : try await AccountClient.login(relayURL: relayURL, email: mail, password: password)
            finish(session)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard
                let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                errorMessage = "Apple sign-in didn't return a token. Try again."
                return
            }
            let appleEmail = credential.email
            Task {
                isWorking = true
                errorMessage = nil
                defer { isWorking = false }
                do {
                    let session = try await AccountClient.apple(relayURL: relayURL, identityToken: identityToken, email: appleEmail)
                    finish(session)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        case .failure:
            // User canceled or it failed — don't nag with an error for a cancel.
            break
        }
    }

    private func finish(_ session: AccountClient.Session) {
        DeviceTokenStore.applyAccount(token: session.token, ingestToken: session.ingest_token, email: session.email)
        // Re-register this device's push token under the account's private ingest token.
        PushRegistrar.ensureRegistered()
        Haptics.success()
        onSignedIn()
        dismiss()
    }
}
