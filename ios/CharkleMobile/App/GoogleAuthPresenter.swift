import AuthenticationServices
import CharkleCore
import Foundation
import UIKit

/// Native RFC 8252 OAuth 2.0 session presenter backed by `ASWebAuthenticationSession`
/// for universal iPadOS & iOS Google Drive sign-in.
final class GoogleAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var activeSession: ASWebAuthenticationSession?

    func present(authURL: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                MainActor.assumeIsolated {
                    self?.activeSession = nil
                }
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                    return
                }
                if let authError = error as? ASWebAuthenticationSessionError,
                   authError.code == .canceledLogin {
                    continuation.resume(throwing: DriveTransportError.authenticationRequired("已取消 Google 账号授权。"))
                    return
                }
                let detail = error?.localizedDescription ?? "未收到 Google 登录回调。"
                continuation.resume(throwing: DriveTransportError.authenticationRequired(detail))
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.activeSession = session
            if !session.start() {
                self.activeSession = nil
                continuation.resume(throwing: DriveTransportError.authenticationRequired("无法启动系统授权窗口，请重试。"))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }),
           let keyWindow = activeScene.windows.first(where: \.isKeyWindow) ?? activeScene.windows.first {
            return keyWindow
        }
        if let fallbackScene = scenes.first, let window = fallbackScene.windows.first {
            return window
        }
        if let anyScene = scenes.first {
            return UIWindow(windowScene: anyScene)
        }
        fatalError("No active UIWindowScene available for ASWebAuthenticationSession.")
    }
}
