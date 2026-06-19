import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Google OAuth configuration. Fill `clientID` with your Google Cloud **iOS** OAuth
/// client id, and add its reversed-client-id (see `urlScheme`) to the app's URL types.
/// Empty `clientID` simply hides the Google button — the app builds and runs without it.
enum GoogleConfig {
    static let clientID = ""   // e.g. "123456789-abc123.apps.googleusercontent.com"

    static var isConfigured: Bool { !clientID.isEmpty }

    /// "123-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.123-abc"
    static var urlScheme: String {
        guard let prefix = clientID.components(separatedBy: ".apps.googleusercontent.com").first,
              !prefix.isEmpty else { return "" }
        return "com.googleusercontent.apps.\(prefix)"
    }

    static var redirectURI: String { "\(urlScheme):/oauth2redirect" }
}

/// Drives Google's OAuth 2.0 authorization-code + PKCE flow with a system web sheet
/// (no third-party SDK) and returns a Google ID token to hand to the relay.
@MainActor
final class GoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum SignInError: LocalizedError {
        case notConfigured, canceled, failed(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Google sign-in isn't set up."
            case .canceled: return nil
            case .failed(let message): return message
            }
        }
    }

    private var session: ASWebAuthenticationSession?

    func idToken() async throws -> String {
        guard GoogleConfig.isConfigured else { throw SignInError.notConfigured }
        let verifier = Self.codeVerifier()
        let code = try await authorize(challenge: Self.codeChallenge(verifier))
        return try await exchange(code: code, verifier: verifier)
    }

    private func authorize(challenge: String) async throws -> String {
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: GoogleConfig.clientID),
            .init(name: "redirect_uri", value: GoogleConfig.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        guard let authURL = comps.url else { throw SignInError.failed("Couldn't build the sign-in URL.") }

        return try await withCheckedThrowingContinuation { continuation in
            let webSession = ASWebAuthenticationSession(
                url: authURL, callbackURLScheme: GoogleConfig.urlScheme
            ) { callback, error in
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: SignInError.canceled); return
                }
                if let error {
                    continuation.resume(throwing: SignInError.failed(error.localizedDescription)); return
                }
                guard
                    let callback,
                    let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "code" })?.value
                else {
                    continuation.resume(throwing: SignInError.failed("No authorization code returned.")); return
                }
                continuation.resume(returning: code)
            }
            webSession.presentationContextProvider = self
            self.session = webSession
            webSession.start()
        }
    }

    private func exchange(code: String, verifier: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "client_id": GoogleConfig.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": GoogleConfig.redirectURI,
        ]
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let idToken = obj["id_token"] as? String
        else {
            throw SignInError.failed("Google didn't return an ID token.")
        }
        return idToken
    }

    // MARK: - PKCE

    private static func codeVerifier() -> String {
        // System RNG is cryptographically secure on Apple platforms.
        Data((0..<64).map { _ in UInt8.random(in: 0...255) }).base64URL()
    }

    private static func codeChallenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}

private extension Data {
    func base64URL() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
