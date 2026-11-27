import CharkleCore
import SwiftUI
import UIKit
import WebKit

/// Visible iOS / iPadOS WebKit login sheet sharing `PinterestSessionBridge.shared`'s persistent cookie store.
///
/// Properly supports real child popup `WKWebView`s (`createWebViewWith` + `webViewDidClose`) so
/// "Continue with Google" / Apple OAuth popups preserve `window.opener.postMessage()`, close cleanly
/// back into Pinterest's login page instead of stranding on a blank OAuth callback page, and auto-detect
/// authenticated Pinterest cookies even on SPA redirects.
struct PinterestLoginSheetMobile: View {
    @Environment(\.colorScheme) private var colorScheme

    let onVerifySession: () async -> Bool
    let onDismiss: () -> Void

    @State private var currentHost: String = "www.pinterest.com"
    @State private var isLoadingPage: Bool = true
    @State private var isPopupActive: Bool = false
    @State private var isVerifying: Bool = false
    @State private var statusHint: String? = nil
    @State private var webCommand = WebCommand()
    @State private var cookieRetryGeneration: Int = 0
    @State private var postPopupVerifyTask: Task<Void, Never>?
    @State private var autoVerifyTask: Task<Void, Never>?

    struct WebCommand: Equatable {
        enum Action { case none, reload, goBack, closePopup }
        var id = UUID()
        var action: Action = .none
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isPopupActive {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MobileTheme.accent(for: colorScheme))
                        Text("正在第三方账号验证窗口（\(currentHost)）")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            .lineLimit(1)
                        Spacer()
                        Button("返回登录页") {
                            webCommand = WebCommand(action: .closePopup)
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MobileTheme.accent(for: colorScheme))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(MobileTheme.surfaceSubtle(for: colorScheme))
                }

                ZStack(alignment: .top) {
                    PinterestLoginWebViewMobile(
                        command: webCommand,
                        cookieRetryGeneration: cookieRetryGeneration,
                        onURLChanged: { url in
                            if let host = url.host(), !host.isEmpty {
                                currentHost = host
                            }
                            maybeAutoVerify(for: url)
                        },
                        onLoadingChanged: { loading in
                            isLoadingPage = loading
                        },
                        onPopupStateChanged: { active in
                            isPopupActive = active
                            if !active {
                                // Popup just closed (e.g. Google OAuth finished postMessage -> window.close()).
                                // Poll session cookies cleanly over the next few seconds as Pinterest finishes sign-in.
                                schedulePostPopupVerify()
                            }
                        },
                        onAuthCookiesDetected: {
                            triggerAutoVerifyFromCookies()
                        }
                    )
                    .ignoresSafeArea(edges: .bottom)

                    if isLoadingPage {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(MobileTheme.accent(for: colorScheme))
                    }
                }

                if let statusHint {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(MobileTheme.accent(for: colorScheme))
                        Text(statusHint)
                            .font(.system(size: 12.5))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(MobileTheme.surfaceSubtle(for: colorScheme))
                }
            }
            .navigationTitle("登录 Pinterest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { onDismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        webCommand = WebCommand(action: .goBack)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    Button {
                        webCommand = WebCommand(action: .reload)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    Button {
                        triggerManualVerify()
                    } label: {
                        if isVerifying {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("已完成")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(isVerifying)
                }
            }
        }
        .onDisappear {
            postPopupVerifyTask?.cancel()
            postPopupVerifyTask = nil
            autoVerifyTask?.cancel()
            autoVerifyTask = nil
        }
    }

    private func maybeAutoVerify(for url: URL) {
        guard !isVerifying, !isPopupActive else { return }
        let host = url.host()?.lowercased() ?? ""
        let path = url.path.lowercased()
        guard host.contains("pinterest."),
              !path.contains("/login"),
              !path.contains("/signup"),
              !path.contains("/oauth"),
              !path.contains("/password") else {
            return
        }
        triggerAutoVerifyFromCookies()
    }

    private func schedulePostPopupVerify() {
        postPopupVerifyTask?.cancel()
        postPopupVerifyTask = Task {
            for delayMs in [600, 1400, 2600] {
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard !Task.isCancelled, !isVerifying else { return }
                let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                guard !Task.isCancelled else { return }
                let hasAuth = cookies.contains {
                    $0.domain.lowercased().contains("pinterest") && $0.name == "_auth" && $0.value == "1"
                }
                if hasAuth {
                    isVerifying = true
                    let ok = await onVerifySession()
                    isVerifying = false
                    if ok { return }
                    cookieRetryGeneration &+= 1
                }
            }
        }
    }

    private func triggerAutoVerifyFromCookies() {
        guard !isVerifying else { return }
        autoVerifyTask?.cancel()
        autoVerifyTask = Task {
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            guard !Task.isCancelled else { return }
            let hasAuth = cookies.contains {
                $0.domain.lowercased().contains("pinterest") && $0.name == "_auth" && $0.value == "1"
            }
            guard hasAuth else {
                cookieRetryGeneration &+= 1
                return
            }
            isVerifying = true
            let ok = await onVerifySession()
            isVerifying = false
            if !ok {
                cookieRetryGeneration &+= 1
                statusHint = "若已完成登录，可点击右上角「已完成」同步会话。"
            }
        }
    }

    private func triggerManualVerify() {
        guard !isVerifying else { return }
        isVerifying = true
        statusHint = nil
        Task {
            let ok = await onVerifySession()
            isVerifying = false
            if !ok {
                cookieRetryGeneration &+= 1
                statusHint = "暂未检测到已登录的 Pinterest 会话，请先在网页内完成登录。"
            }
        }
    }
}

private struct PinterestLoginWebViewMobile: UIViewRepresentable {
    let command: PinterestLoginSheetMobile.WebCommand
    let cookieRetryGeneration: Int
    let onURLChanged: (URL) -> Void
    let onLoadingChanged: (Bool) -> Void
    let onPopupStateChanged: (Bool) -> Void
    let onAuthCookiesDetected: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onURLChanged: onURLChanged,
            onLoadingChanged: onLoadingChanged,
            onPopupStateChanged: onPopupStateChanged,
            onAuthCookiesDetected: onAuthCookiesDetected
        )
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.backgroundColor = .systemBackground

        let config = PinterestSessionBridge.shared.makeLoginWebViewConfiguration()
        let webView = WKWebView(frame: container.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        container.addSubview(webView)

        context.coordinator.containerView = container
        context.coordinator.primaryWebView = webView
        context.coordinator.startObservingCookies()
        webView.load(URLRequest(url: PinterestSessionBridge.loginURL))
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if context.coordinator.lastRetryGeneration != cookieRetryGeneration {
            context.coordinator.lastRetryGeneration = cookieRetryGeneration
            context.coordinator.resetAuthCookieTrigger()
        }
        guard context.coordinator.lastCommandID != command.id else { return }
        context.coordinator.lastCommandID = command.id
        switch command.action {
        case .none:
            break
        case .reload:
            context.coordinator.activeWebView?.reload()
        case .goBack:
            context.coordinator.goBackOrClosePopup()
        case .closePopup:
            context.coordinator.closeTopPopup()
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stopObservingCookies()
        coordinator.closeAllPopups()
        if let primary = coordinator.primaryWebView {
            primary.stopLoading()
            primary.navigationDelegate = nil
            primary.uiDelegate = nil
            primary.removeFromSuperview()
        }
        coordinator.primaryWebView = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        let onURLChanged: (URL) -> Void
        let onLoadingChanged: (Bool) -> Void
        let onPopupStateChanged: (Bool) -> Void
        let onAuthCookiesDetected: () -> Void

        weak var containerView: UIView?
        weak var primaryWebView: WKWebView?
        var popupStack: [WKWebView] = []
        var lastCommandID: UUID?
        var lastRetryGeneration: Int = 0
        private var didFireAuthCookieCallback = false

        func resetAuthCookieTrigger() {
            didFireAuthCookieCallback = false
        }

        var activeWebView: WKWebView? {
            popupStack.last ?? primaryWebView
        }

        init(
            onURLChanged: @escaping (URL) -> Void,
            onLoadingChanged: @escaping (Bool) -> Void,
            onPopupStateChanged: @escaping (Bool) -> Void,
            onAuthCookiesDetected: @escaping () -> Void
        ) {
            self.onURLChanged = onURLChanged
            self.onLoadingChanged = onLoadingChanged
            self.onPopupStateChanged = onPopupStateChanged
            self.onAuthCookiesDetected = onAuthCookiesDetected
        }

        func startObservingCookies() {
            WKWebsiteDataStore.default().httpCookieStore.add(self)
        }

        func stopObservingCookies() {
            WKWebsiteDataStore.default().httpCookieStore.remove(self)
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            guard !didFireAuthCookieCallback else { return }
            cookieStore.getAllCookies { [weak self] cookies in
                let hasAuth = cookies.contains {
                    $0.domain.lowercased().contains("pinterest") && $0.name == "_auth" && $0.value == "1"
                }
                guard hasAuth, let self, !self.didFireAuthCookieCallback else { return }
                self.didFireAuthCookieCallback = true
                // If a Google/Apple OAuth popup finished setting Pinterest auth cookies but
                // lingered on a blank callback page, dismiss it cleanly.
                if !self.popupStack.isEmpty {
                    self.closeAllPopups()
                }
                self.onAuthCookiesDetected()
            }
        }

        func goBackOrClosePopup() {
            if let topPopup = popupStack.last {
                if topPopup.canGoBack {
                    topPopup.goBack()
                } else {
                    closeTopPopup()
                }
            } else if let primary = primaryWebView, primary.canGoBack {
                primary.goBack()
            }
        }

        func closeTopPopup() {
            guard let top = popupStack.popLast() else { return }
            top.stopLoading()
            top.navigationDelegate = nil
            top.uiDelegate = nil
            top.removeFromSuperview()
            onPopupStateChanged(!popupStack.isEmpty)
            if let url = activeWebView?.url {
                onURLChanged(url)
            }
        }

        func closeAllPopups() {
            for popup in popupStack {
                popup.stopLoading()
                popup.navigationDelegate = nil
                popup.uiDelegate = nil
                popup.removeFromSuperview()
            }
            let hadPopups = !popupStack.isEmpty
            popupStack.removeAll()
            if hadPopups {
                onPopupStateChanged(false)
            }
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onLoadingChanged(true)
            if let url = webView.url { onURLChanged(url) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadingChanged(false)
            if let url = webView.url {
                onURLChanged(url)
                // If an OAuth popup redirected all the way back to a signed-in Pinterest home page
                // instead of calling window.close(), close the popup and reload primary cleanly.
                if popupStack.contains(where: { $0 === webView }) {
                    let host = url.host()?.lowercased() ?? ""
                    let path = url.path.lowercased()
                    if host.contains("pinterest."),
                       !path.contains("/login"),
                       !path.contains("/oauth"),
                       !path.contains("/connect") {
                        closeAllPopups()
                        primaryWebView?.load(URLRequest(url: url))
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadingChanged(false)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoadingChanged(false)
        }

        // MARK: - WKUIDelegate (True Child Popup Support for Google / Apple OAuth)

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard let container = containerView else { return nil }
            // MUST initialize popup with the exact `configuration` passed by WebKit so `window.opener`
            // and `postMessage` stay connected to Pinterest's parent login page!
            let popup = WKWebView(frame: container.bounds, configuration: configuration)
            popup.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            popup.navigationDelegate = self
            popup.uiDelegate = self
            popup.allowsBackForwardNavigationGestures = true
            container.addSubview(popup)
            popupStack.append(popup)
            onPopupStateChanged(true)
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            guard let idx = popupStack.firstIndex(where: { $0 === webView }) else { return }
            let closed = popupStack.remove(at: idx)
            closed.stopLoading()
            closed.navigationDelegate = nil
            closed.uiDelegate = nil
            closed.removeFromSuperview()
            onPopupStateChanged(!popupStack.isEmpty)
            if let url = activeWebView?.url {
                onURLChanged(url)
            }
        }
    }
}
