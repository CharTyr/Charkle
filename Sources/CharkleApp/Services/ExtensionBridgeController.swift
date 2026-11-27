import AppKit
import CharkleCore
import Darwin
import Foundation
import SafariServices
import os

private let bridgeLogger = Logger(subsystem: "com.charkle.app", category: "ExtensionBridge")

/// Main-actor controller managing Charkle's embedded HTTP server (`port 41937+`) powering BOTH:
/// 1. Same-machine loopback browser extension bridge (`Chrome / Edge / Arc / Safari`)
/// 2. Streamable HTTP MCP endpoint (`/api/v1/mcp` + `/api/v1/mcp/download/<ticket>`) for local & cross-machine AI Agents.
@Observable
public final class ExtensionBridgeController {
    private static let enabledKey = "charkle.extensionBridge.enabled"
    private static let autoPairKey = "charkle.extensionBridge.allowLocalAutoPair"
    private static let tokenKey = "charkle.extensionBridge.token"
    public static let safariExtensionBundleIdentifier = "com.charkle.app.SafariExtension"

    public var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            syncServerLifecycle()
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
    public private(set) var httpMCPEnabled: Bool
    public private(set) var allowsRemoteMCP: Bool
    public private(set) var accessToken: String
    public private(set) var lastError: String?

    public var mcpLocalEndpointURL: String {
        "\(baseURL)/api/v1/mcp"
    }

    public var mcpRemoteEndpointURL: String? {
        guard allowsRemoteMCP, port > 0, let ip = Self.localLANIPv4Address() else { return nil }
        return "http://\(ip):\(port)/api/v1/mcp"
    }

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
    private var pendingMCPMutation: Bool = false
    @ObservationIgnored
    private let onRefreshLibrary: @MainActor (_ createdCount: Int, _ targetBoardID: UUID?, _ isMCPMutation: Bool) async -> Void

    public init(
        engine: any CharkleEngineProtocol,
        onRefreshLibrary: @escaping @MainActor (_ createdCount: Int, _ targetBoardID: UUID?, _ isMCPMutation: Bool) async -> Void
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

        let agentCfg = ExternalAgentConfigStore.load()
        self.httpMCPEnabled = agentCfg.httpMCPEnabled
        self.allowsRemoteMCP = agentCfg.allowRemoteHTTPMCP

        let keychain = KeychainStore()
        self.keychain = keychain
        let resolvedToken = Self.loadOrMigrateToken(keychain: keychain, defaults: defaults)
        self.accessToken = resolvedToken
        self.onRefreshLibrary = onRefreshLibrary

        let mcpService: CharkleExternalAgentService? = (engine as? LiveCharkleEngine).map {
            CharkleExternalAgentService(engine: $0, notifyOnWrite: false)
        }

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
            mcpService: mcpService,
            allowRemoteMCP: agentCfg.allowRemoteHTTPMCP,
            onLibraryMutated: mutationHandler
        )
        box.value = self
    }

    private var shouldRunHTTPServer: Bool {
        isEnabled || httpMCPEnabled
    }

    private static func loadOrMigrateToken(keychain: KeychainStore, defaults: UserDefaults) -> String {
        if let data = try? keychain.read(Self.tokenKey),
           let stored = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           stored.count >= 24 {
            if defaults.object(forKey: Self.tokenKey) != nil {
                defaults.removeObject(forKey: Self.tokenKey)
            }
            return stored
        }

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

        let fresh = LocalExtensionBridgeServer.generateToken()
        do {
            try keychain.save(Data(fresh.utf8), for: Self.tokenKey)
            defaults.removeObject(forKey: Self.tokenKey)
        } catch {
            bridgeLogger.error("Failed to store new extension bridge token in Keychain: \(error.localizedDescription, privacy: .public)")
        }
        return fresh
    }

    public func applyHTTPMCPConfig(_ config: ExternalAgentConfig) {
        let remoteChanged = allowsRemoteMCP != config.allowRemoteHTTPMCP
        httpMCPEnabled = config.httpMCPEnabled
        allowsRemoteMCP = config.allowRemoteHTTPMCP

        if !shouldRunHTTPServer {
            stop()
            return
        }

        if remoteChanged {
            let allowRemote = config.allowRemoteHTTPMCP
            lifecycleGeneration &+= 1
            let generation = lifecycleGeneration
            startTask?.cancel()
            startTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let status = try await self.server.updateAllowRemoteMCP(allowRemote)
                    let finalStatus: LocalExtensionBridgeServer.StatusSnapshot
                    if status.isRunning {
                        finalStatus = status
                    } else {
                        finalStatus = try await self.server.start()
                    }
                    guard !Task.isCancelled, self.shouldRunHTTPServer, self.lifecycleGeneration == generation else { return }
                    self.isRunning = finalStatus.isRunning
                    self.port = finalStatus.port
                    self.baseURL = finalStatus.baseURL
                    self.lastError = nil
                } catch {
                    guard !Task.isCancelled, self.lifecycleGeneration == generation else { return }
                    self.isRunning = false
                    self.lastError = error.localizedDescription
                }
            }
        } else if !isRunning {
            startIfEnabled()
        }
    }

    private func syncServerLifecycle() {
        if shouldRunHTTPServer {
            startIfEnabled()
        } else {
            stop()
        }
    }

    public func startIfEnabled() {
        guard shouldRunHTTPServer else { return }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await self.server.start()
                guard !Task.isCancelled, self.shouldRunHTTPServer, self.lifecycleGeneration == generation else {
                    await self.server.stop()
                    return
                }
                self.isRunning = status.isRunning
                self.port = status.port
                self.baseURL = status.baseURL
                self.lastError = nil
                bridgeLogger.info("Embedded HTTP bridge & MCP listening on \(status.baseURL, privacy: .public) (remoteMCP=\(status.allowsRemoteMCP, privacy: .public))")
            } catch {
                guard !Task.isCancelled, self.lifecycleGeneration == generation else { return }
                self.isRunning = false
                self.lastError = error.localizedDescription
                bridgeLogger.error("Embedded HTTP bridge failed to start: \(error.localizedDescription, privacy: .public)")
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

    public static func bundledBrowserExtensionDirectoryURL() -> URL? {
        let fm = FileManager.default
        if let bundleRes = Bundle.main.resourceURL {
            let bundled = bundleRes.appending(path: "BrowserExtension", directoryHint: .isDirectory)
            if fm.fileExists(atPath: bundled.appending(path: "manifest.json").path) {
                return bundled
            }
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let devCandidate = cwd.appending(path: "Resources/BrowserExtension", directoryHint: .isDirectory)
        if fm.fileExists(atPath: devCandidate.appending(path: "manifest.json").path) {
            return devCandidate
        }
        return nil
    }

    public static func isSafariExtensionEmbedded() -> Bool {
        guard let plugInsURL = Bundle.main.builtInPlugInsURL else { return false }
        let appex = plugInsURL.appending(path: "CharkleSafariExtension.appex", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: appex.path)
    }

    /// Detects the primary non-loopback IPv4 interface address (LAN or Tailscale) for display in Settings.
    public static func localLANIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var preferred: String?
        var fallback: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if isUp && !isLoopback, let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let res = getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if res == 0 {
                    let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    let ifName = String(cString: current.pointee.ifa_name)
                    if ifName.hasPrefix("en") && preferred == nil {
                        preferred = ip
                    } else if fallback == nil {
                        fallback = ip
                    }
                }
            }
            cursor = current.pointee.ifa_next
        }
        return preferred ?? fallback
    }

    private func handleMutation(kind: LocalExtensionBridgeServer.MutationKind, count: Int, targetBoardID: UUID?) {
        if kind == .ingest {
            pendingIngestCount += max(1, count)
        } else if kind == .mcpMutation {
            pendingMCPMutation = true
        }
        if let targetBoardID, !pendingBoardRefreshIDs.contains(targetBoardID) {
            pendingBoardRefreshIDs.append(targetBoardID)
        }
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled else { return }
            let countToReport = self.pendingIngestCount
            let boardsToRefresh = self.pendingBoardRefreshIDs
            let wasMCP = self.pendingMCPMutation
            self.pendingIngestCount = 0
            self.pendingBoardRefreshIDs.removeAll()
            self.pendingMCPMutation = false
            if boardsToRefresh.isEmpty {
                await self.onRefreshLibrary(countToReport, nil, wasMCP)
            } else {
                for (index, boardID) in boardsToRefresh.enumerated() {
                    await self.onRefreshLibrary(index == 0 ? countToReport : 0, boardID, wasMCP)
                }
            }
        }
    }
}

private final class WeakControllerBox: @unchecked Sendable {
    weak var value: ExtensionBridgeController?
}
