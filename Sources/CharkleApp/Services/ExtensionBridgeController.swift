import AppKit
import CharkleCore
import Foundation
import SafariServices
import os

private let bridgeLogger = Logger(subsystem: "com.charkle.app", category: "ExtensionBridge")

/// Main-actor controller managing the local loopback HTTP bridge (`http://127.0.0.1:41937`)
/// for Charkle's Safari and Chrome browser extensions.
@Observable
public final class ExtensionBridgeController {
    private static let enabledKey = "charkle.extensionBridge.enabled"
    private static let autoPairKey = "charkle.extensionBridge.allowLocalAutoPair"
    private static let tokenKey = "charkle.extensionBridge.token"
    public static let safariExtensionBundleIdentifier = "com.charkle.app.SafariExtension"

    public var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                startIfEnabled()
            } else {
                stop()
            }
        }
    }

    public var allowLocalAutoPair: Bool {
        didSet {
            UserDefaults.standard.set(allowLocalAutoPair, forKey: Self.autoPairKey)
            let enabled = allowLocalAutoPair
            Task { [server] in
                await server.updateAutoPairEnabled(enabled)
            }
        }
    }

    public private(set) var isRunning: Bool = false
    public private(set) var port: UInt16 = LocalExtensionBridgeServer.defaultPort
    public private(set) var baseURL: String = "http://127.0.0.1:\(LocalExtensionBridgeServer.defaultPort)"
    public private(set) var accessToken: String
    public private(set) var lastError: String?

    @ObservationIgnored
    private let server: LocalExtensionBridgeServer
    @ObservationIgnored
    private var startTask: Task<Void, Never>?
    @ObservationIgnored
    private var refreshDebounceTask: Task<Void, Never>?
    @ObservationIgnored
    private var pendingBoardRefreshID: UUID?
    @ObservationIgnored
    private var pendingIngestCount: Int = 0
    @ObservationIgnored
    private let onRefreshLibrary: @MainActor (_ createdCount: Int, _ targetBoardID: UUID?) async -> Void

    public init(
        engine: any CharkleEngineProtocol,
        onRefreshLibrary: @escaping @MainActor (_ createdCount: Int, _ targetBoardID: UUID?) async -> Void
    ) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.enabledKey) == nil {
            defaults.set(true, forKey: Self.enabledKey)
        }
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)

        if defaults.object(forKey: Self.autoPairKey) == nil {
            defaults.set(true, forKey: Self.autoPairKey)
        }
        let resolvedAutoPair = defaults.bool(forKey: Self.autoPairKey)
        self.allowLocalAutoPair = resolvedAutoPair

        let storedToken = defaults.string(forKey: Self.tokenKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedToken: String
        if storedToken.count >= 24 {
            resolvedToken = storedToken
        } else {
            let fresh = LocalExtensionBridgeServer.generateToken()
            defaults.set(fresh, forKey: Self.tokenKey)
            resolvedToken = fresh
        }
        self.accessToken = resolvedToken
        self.onRefreshLibrary = onRefreshLibrary

        let box = WeakControllerBox()
        let mutationHandler: @Sendable (LocalExtensionBridgeServer.MutationKind, Int, UUID?, UUID?) -> Void = { kind, count, _, boardID in
            Task { @MainActor in
                box.value?.handleMutation(kind: kind, count: count, targetBoardID: boardID)
            }
        }
        self.server = LocalExtensionBridgeServer(
            engine: engine,
            token: resolvedToken,
            allowLocalAutoPair: resolvedAutoPair,
            onLibraryMutated: mutationHandler
        )
        box.value = self
    }

    public func startIfEnabled() {
        guard isEnabled else { return }
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await self.server.start()
                self.isRunning = status.isRunning
                self.port = status.port
                self.baseURL = status.baseURL
                self.lastError = nil
                bridgeLogger.info("Browser extension bridge listening on \(status.baseURL, privacy: .public)")
            } catch {
                self.isRunning = false
                self.lastError = error.localizedDescription
                bridgeLogger.error("Browser extension bridge failed to start: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func stop() {
        startTask?.cancel()
        startTask = nil
        refreshDebounceTask?.cancel()
        refreshDebounceTask = nil
        Task { [server] in
            await server.stop()
        }
        isRunning = false
    }

    @discardableResult
    public func regenerateToken() -> String {
        let fresh = LocalExtensionBridgeServer.generateToken()
        accessToken = fresh
        UserDefaults.standard.set(fresh, forKey: Self.tokenKey)
        Task { [server] in
            await server.updateToken(fresh)
        }
        return fresh
    }

    /// Opens Safari's Extensions preferences directly on Charkle's embedded Safari Web Extension.
    public func openSafariExtensionPreferences() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: Self.safariExtensionBundleIdentifier) { error in
            if error != nil {
                Task { @MainActor in
                    if let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
                        NSWorkspace.shared.openApplication(at: safariURL, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
            }
        }
    }

    /// Locates the bundled Chrome/Edge/Arc unpacked browser extension folder (`BrowserExtension/`).
    public static func bundledBrowserExtensionDirectoryURL() -> URL? {
        let fm = FileManager.default
        if let bundleRes = Bundle.main.resourceURL {
            let bundled = bundleRes.appending(path: "BrowserExtension", directoryHint: .isDirectory)
            if fm.fileExists(atPath: bundled.appending(path: "manifest.json").path) {
                return bundled
            }
        }
        // Development fallback: walk up from executable or cwd to repo root `Resources/BrowserExtension`.
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let devCandidate = cwd.appending(path: "Resources/BrowserExtension", directoryHint: .isDirectory)
        if fm.fileExists(atPath: devCandidate.appending(path: "manifest.json").path) {
            return devCandidate
        }
        return nil
    }

    /// Returns whether the embedded Safari Web Extension `.appex` exists inside `Charkle.app/Contents/PlugIns/`.
    public static func isSafariExtensionEmbedded() -> Bool {
        guard let plugInsURL = Bundle.main.builtInPlugInsURL else { return false }
        let appex = plugInsURL.appending(path: "CharkleSafariExtension.appex", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: appex.path)
    }

    private func handleMutation(kind: LocalExtensionBridgeServer.MutationKind, count: Int, targetBoardID: UUID?) {
        if kind == .ingest {
            pendingIngestCount += max(1, count)
        }
        if let targetBoardID {
            pendingBoardRefreshID = targetBoardID
        }
        // Coalesce rapid batch bookmark imports into smooth ~450ms UI refreshes.
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled else { return }
            let countToReport = self.pendingIngestCount
            let boardToRefresh = self.pendingBoardRefreshID
            self.pendingIngestCount = 0
            self.pendingBoardRefreshID = nil
            await self.onRefreshLibrary(countToReport, boardToRefresh)
        }
    }
}

private final class WeakControllerBox: @unchecked Sendable {
    weak var value: ExtensionBridgeController?
}
