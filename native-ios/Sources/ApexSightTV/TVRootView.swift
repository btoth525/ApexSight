import SwiftUI

struct TVRootView: View {
    @EnvironmentObject private var state: TVAppState

    var body: some View {
        Group {
            if state.session == nil {
                TVSignInView()
            } else {
                TVWallView()
            }
        }
        .task { await state.bootstrap() }
    }
}

struct TVSignInView: View {
    @EnvironmentObject private var state: TVAppState
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.04, green: 0.06, blue: 0.12), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 70, weight: .black))
                    .foregroundStyle(.cyan)
                Text("ApexSight")
                    .font(.system(size: 56, weight: .black))
                Text("Sign in to your Frigate server")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                VStack(spacing: 14) {
                    TextField("Server URL (https://…)", text: $url)
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                }
                .textFieldStyle(.plain)
                .frame(maxWidth: 720)

                if let error = state.errorMessage {
                    Text(error).font(.headline).foregroundStyle(.red)
                }

                Button {
                    Task { await state.signIn(baseURL: url, username: username, password: password) }
                } label: {
                    Text(state.isLoading ? "Connecting…" : "Connect")
                        .font(.title3.weight(.black))
                        .frame(maxWidth: 720)
                }
                .disabled(state.isLoading || url.isEmpty)
                .padding(.top, 6)
            }
            .padding(60)
        }
    }
}
