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
    private let keychain: KeychainStore
    @ObservationIgnored
    private var startTask: Task<Void, Never>?
    @ObservationIgnored
    private var lifecycleGeneration: UInt64 = 0
    @ObservationIgnored
    private var refreshDebounceTask: Task<Void, Never>?
    @ObservationIgnored
    private var pendingBoardRefreshIDs: [UUID] = []
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

        let keychain = KeychainStore()
        self.keychain = keychain
        let resolvedToken = Self.loadOrMigrateToken(keychain: keychain, defaults: defaults)
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

    private static func loadOrMigrateToken(keychain: KeychainStore, defaults: UserDefaults) -> String {
        // 1. Prefer Keychain-stored token and scrub any lingering legacy plaintext UserDefaults copy.
        if let data = try? keychain.read(Self.tokenKey),
           let stored = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           stored.count >= 24 {
            if defaults.object(forKey: Self.tokenKey) != nil {
                defaults.removeObject(forKey: Self.tokenKey)
            }
            return stored
        }

        // 2. Transparent one-time migration from legacy UserDefaults key so paired extensions stay connected.
        if let legacy = defaults.string(forKey: Self.tokenKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           legacy.count >= 24 {
            do {
                try keychain.save(Data(legacy.utf8), for: Self.tokenKey)
                defaults.removeObject(forKey: Self.tokenKey)
            } catch {
                bridgeLogger.error("Failed to migrate extension bridge token to Keychain: \(error.localizedDescription, privacy: .public)")
            }
            return legacy
        }

        // 3. Generate a fresh token and persist strictly to Keychain.
        let fresh = LocalExtensionBridgeServer.generateToken()
        do {
            try keychain.save(Data(fresh.utf8), for: Self.tokenKey)
            defaults.removeObject(forKey: Self.tokenKey)
        } catch {
            bridgeLogger.error("Failed to store new extension bridge token in Keychain: \(error.localizedDescription, privacy: .public)")
        }
        return fresh
    }

    public func startIfEnabled() {
        guard isEnabled else { return }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await self.server.start()
                guard !Task.isCancelled, self.isEnabled, self.lifecycleGeneration == generation else {
                    await self.server.stop()
                    return
                }
                self.isRunning = status.isRunning
                self.port = status.port
                self.baseURL = status.baseURL
                self.lastError = nil
                bridgeLogger.info("Browser extension bridge listening on \(status.baseURL, privacy: .public)")
            } catch {
                guard !Task.isCancelled, self.lifecycleGeneration == generation else { return }
                self.isRunning = false
                self.lastError = error.localizedDescription
                bridgeLogger.error("Browser extension bridge failed to start: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func stop() {
        lifecycleGeneration &+= 1
        startTask?.cancel()
        startTask = nil
        refreshDebounceTask?.cancel()
        refreshDebounceTask = nil
        let server = self.server
        Task {
            await server.stop()
        }
        isRunning = false
    }

    isolated deinit {
        startTask?.cancel()
        refreshDebounceTask?.cancel()
        let server = self.server
        Task.detached(priority: .utility) {
            await server.stop()
        }
    }

    @discardableResult
    public func regenerateToken() -> String {
        let fresh = LocalExtensionBridgeServer.generateToken()
        accessToken = fresh
        do {
            try keychain.save(Data(fresh.utf8), for: Self.tokenKey)
            UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        } catch {
            bridgeLogger.error("Failed to persist regenerated extension bridge token to Keychain: \(error.localizedDescription, privacy: .public)")
        }
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
        if let targetBoardID, !pendingBoardRefreshIDs.contains(targetBoardID) {
            pendingBoardRefreshIDs.append(targetBoardID)
        }
        // Coalesce rapid batch bookmark imports into smooth ~450ms UI refreshes without dropping multi-board targets.
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled else { return }
            let countToReport = self.pendingIngestCount
            let boardsToRefresh = self.pendingBoardRefreshIDs
            self.pendingIngestCount = 0
            self.pendingBoardRefreshIDs.removeAll()
            if boardsToRefresh.isEmpty {
                await self.onRefreshLibrary(countToReport, nil)
            } else {
                for (index, boardID) in boardsToRefresh.enumerated() {
                    await self.onRefreshLibrary(index == 0 ? countToReport : 0, boardID)
                }
            }
        }
    }
}

private final class WeakControllerBox: @unchecked Sendable {
    weak var value: ExtensionBridgeController?
}
