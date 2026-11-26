import AppKit
import CharkleCore
import SwiftUI
import WebKit

/// Visible macOS WebKit login sheet sharing `PinterestSessionBridge.shared`'s persistent cookie store.
///
/// Properly supports real child popup `WKWebView`s (`createWebViewWith` + `webViewDidClose`) so
/// "Continue with Google" / Apple OAuth popups preserve `window.opener.postMessage()`, close cleanly
/// back into Pinterest's parent page instead of stranding on a blank OAuth callback page, and auto-detect
/// authenticated Pinterest cookies even on SPA redirects.
struct PinterestLoginSheetMac: View {
    @Environment(\.colorScheme) private var colorScheme

    let onVerifySession: () async -> Bool
    let onDismiss: () -> Void

    @State private var currentURLString: String = PinterestSessionBridge.loginURL.absoluteString
    @State private var isLoadingPage: Bool = true
    @State private var isPopupActive: Bool = false
    @State private var isVerifying: Bool = false
    @State private var statusHint: String? = nil
    @State private var webCommand = WebNavigationCommand()

    struct WebNavigationCommand: Equatable {
        enum Action { case none, reload, goBack, closePopup }
        var id = UUID()
        var action: Action = .none
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            CharkleHairlineDivider()

            if isPopupActive {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(CharkleTheme.accent(for: colorScheme))
                    Text("正在第三方账号验证窗口（\(URL(string: currentURLString)?.host() ?? "OAuth")）")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        .lineLimit(1)
                    Spacer()
                    Button("返回登录页") {
                        webCommand = WebNavigationCommand(action: .closePopup)
                    }
                    .buttonStyle(CharkleButtonStyle(.subtle, size: .xs, cornerRadius: 999))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(CharkleTheme.surfaceSubtle(for: colorScheme))
                CharkleHairlineDivider()
            }

            ZStack(alignment: .top) {
                PinterestLoginWebViewMac(
                    command: webCommand,
                    onURLChanged: { url in
                        currentURLString = url.absoluteString
                        maybeAutoVerify(for: url)
                    },
                    onLoadingChanged: { loading in
                        isLoadingPage = loading
                    },
                    onPopupStateChanged: { active in
                        isPopupActive = active
                        if !active {
                            schedulePostPopupVerify()
                        }
                    },
                    onAuthCookiesDetected: {
                        triggerAutoVerifyFromCookies()
                    }
                )

                if isLoadingPage {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(CharkleTheme.accent(for: colorScheme))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let statusHint {
                CharkleHairlineDivider()
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CharkleTheme.accent(for: colorScheme))
                    Text(statusHint)
                        .font(.system(size: 12))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(CharkleTheme.surfaceSubtle(for: colorScheme))
            }
        }
        .frame(width: 560, height: 700)
        .background(CharkleTheme.surfaceElevated(for: colorScheme))
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    webCommand = WebNavigationCommand(action: .goBack)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(CharkleButtonStyle(.subtle, size: .icon, iconDimension: 28))
                .help("返回上一页")

                Button {
                    webCommand = WebNavigationCommand(action: .reload)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(CharkleButtonStyle(.subtle, size: .icon, iconDimension: 28))
                .help("刷新页面")
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("登录 Pinterest 账号")
                    .font(.system(size: 13.5, weight: .semibold))
                Text(URL(string: currentURLString)?.host() ?? "www.pinterest.com")
                    .font(.system(size: 11))
                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                    .lineLimit(1)
            }

            Spacer()

            Button {
                triggerManualVerify()
            } label: {
                HStack(spacing: 5) {
                    if isVerifying {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(isVerifying ? "验证中…" : "已完成登录")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .buttonStyle(CharkleButtonStyle(.accent, size: .sm, cornerRadius: 999))
            .disabled(isVerifying)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(CharkleButtonStyle(.subtle, size: .icon, iconDimension: 28))
            .help("关闭")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        Task {
            for delayMs in [600, 1400, 2600] {
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard !isVerifying else { return }
                let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                let hasAuth = cookies.contains {
                    $0.domain.lowercased().contains("pinterest") && $0.name == "_auth" && $0.value == "1"
                }
                if hasAuth {
                    isVerifying = true
                    let ok = await onVerifySession()
                    isVerifying = false
                    if ok { return }
                }
            }
        }
    }

    private func triggerAutoVerifyFromCookies() {
        guard !isVerifying else { return }
        Task {
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            let hasAuth = cookies.contains {
                $0.domain.lowercased().contains("pinterest") && $0.name == "_auth" && $0.value == "1"
            }
            guard hasAuth else { return }
            isVerifying = true
            let ok = await onVerifySession()
            isVerifying = false
            if !ok {
                statusHint = "若页面已完成登录，可点击右上角「已完成登录」手动同步状态。"
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
                statusHint = "暂未检测到已登录的 Pinterest 会话，请先在下方网页完成登录后再点击验证。"
            }
        }
    }
}

private struct PinterestLoginWebViewMac: NSViewRepresentable {
    let command: PinterestLoginSheetMac.WebNavigationCommand
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

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        let config = PinterestSessionBridge.shared.makeLoginWebViewConfiguration()
        let webView = WKWebView(frame: container.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
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

    func updateNSView(_ nsView: NSView, context: Context) {
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

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopObservingCookies()
        coordinator.closeAllPopups()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        let onURLChanged: (URL) -> Void
        let onLoadingChanged: (Bool) -> Void
        let onPopupStateChanged: (Bool) -> Void
        let onAuthCookiesDetected: () -> Void

        weak var containerView: NSView?
        weak var primaryWebView: WKWebView?
        var popupStack: [WKWebView] = []
        var lastCommandID: UUID?
        private var didFireAuthCookieCallback = false

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
            let popup = WKWebView(frame: container.bounds, configuration: configuration)
            popup.autoresizingMask = [.width, .height]
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
