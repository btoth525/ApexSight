import SwiftUI
import UIKit

struct LoginView: View {
    @EnvironmentObject private var appState: AppState
    @State private var baseURL = "https://frigate.plexserver525.com"
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        ZStack {
            GlassBackground()
            VStack(spacing: 18) {
                Spacer()

                VStack(spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 52, weight: .black))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [GlassTheme.cyan, GlassTheme.blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .padding(.bottom, 4)

                    Text("ApexSight")
                        .font(.system(size: 44, weight: .black, design: .rounded))
                        .foregroundStyle(GlassTheme.primary)

                    Text("Native Frigate control")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(GlassTheme.secondary)
                }

                GlassCard {
                    VStack(spacing: 14) {
                        field("Server URL", text: $baseURL, keyboard: .URL)
                        field("Username", text: $username, keyboard: .default)
                        secureField("Password", text: $password)

                        if let error = appState.errorMessage {
                            Text(error)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(GlassTheme.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button {
                            Task {
                                await appState.signIn(baseURL: baseURL, username: username, password: password)
                            }
                        } label: {
                            HStack {
                                if appState.isLoading {
                                    ProgressView().tint(.white)
                                }
                                Text("Connect to Frigate")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PillButtonStyle(tint: GlassTheme.blue))
                        .disabled(appState.isLoading || baseURL.isEmpty)
                    }
                }
                .padding(.horizontal, 20)

                Spacer()
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboard)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(GlassTheme.primary)
            .padding(14)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func secureField(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(GlassTheme.primary)
            .padding(14)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

