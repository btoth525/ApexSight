import SwiftUI

struct LoginView: View {
    @EnvironmentObject var authManager: AuthManager

    @State private var username: String = ""
    @State private var password: String = ""
    @State private var serverURL: String = UserDefaults.standard.string(forKey: "frigate_base_url") ?? "https://frigate.plexserver525.com"
    @State private var showingServerURLSheet = false
    @FocusState private var focusedField: Field?

    enum Field: Hashable { case username, password }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo / header
                VStack(spacing: 12) {
                    Image(systemName: "video.badge.checkmark")
                        .font(.system(size: 64))
                        .foregroundColor(.green)

                    Text("ApexSight")
                        .font(.largeTitle.bold())
                        .foregroundColor(.white)

                    Text(serverURL)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .onTapGesture { showingServerURLSheet = true }
                }
                .padding(.bottom, 48)

                // Form
                VStack(spacing: 16) {
                    TextField("Username", text: $username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                        .textFieldStyle(ApexTextFieldStyle())

                    SecureField("Password", text: $password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { Task { await signIn() } }
                        .textFieldStyle(ApexTextFieldStyle())

                    if let error = authManager.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    Button(action: { Task { await signIn() } }) {
                        Group {
                            if authManager.isLoading {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.black)
                            } else {
                                Text("Sign In")
                                    .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.green)
                        .foregroundColor(.black)
                        .cornerRadius(12)
                    }
                    .disabled(authManager.isLoading || username.isEmpty || password.isEmpty)
                }
                .padding(.horizontal, 32)

                // Biometric shortcut — only shown if a token is already saved
                BiometricLoginButton()
                    .padding(.top, 24)

                Spacer()

                // Server URL change
                Button("Change Server") {
                    showingServerURLSheet = true
                }
                .font(.caption)
                .foregroundColor(.gray)
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $showingServerURLSheet) {
            ServerURLSheet(currentURL: $serverURL)
        }
        .preferredColorScheme(.dark)
    }

    private func signIn() async {
        focusedField = nil
        await authManager.login(username: username, password: password)
    }
}

// MARK: - Biometric Button

private struct BiometricLoginButton: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var isAttempting = false

    var body: some View {
        // Only show if a stored token exists (i.e. user has logged in before)
        if KeychainHelper.read(service: "ApexSight", account: "frigate_token") != nil {
            Button(action: {
                isAttempting = true
                Task {
                    await authManager.authenticateWithBiometrics()
                    isAttempting = false
                }
            }) {
                Label("Use Face ID", systemImage: "faceid")
                    .foregroundColor(.green)
            }
            .disabled(isAttempting)
        }
    }
}

// MARK: - Server URL Sheet

private struct ServerURLSheet: View {
    @Binding var currentURL: String
    @State private var editingURL: String = ""
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Frigate Server URL") {
                    TextField("https://frigate.example.com", text: $editingURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("Server Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = editingURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            currentURL = trimmed
                            UserDefaults.standard.set(trimmed, forKey: "frigate_base_url")
                        }
                        dismiss()
                    }
                }
            }
            .onAppear { editingURL = currentURL }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Text Field Style

private struct ApexTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(14)
            .background(Color.white.opacity(0.08))
            .cornerRadius(10)
            .foregroundColor(.white)
            .tint(.green)
    }
}

#Preview {
    LoginView()
        .environmentObject(AuthManager.shared)
}
