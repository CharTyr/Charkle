import CharkleCore
import Foundation

/// Domain store for Google Drive + `gdirect` dual-channel sync, hybrid local/cloud AI configuration,
/// and two-tier thumbnail/original LRU cache telemetry.
@Observable
public final class SyncAndAIStore {
    public let engine: any CharkleEngineProtocol

    public var syncConfig: DriveSyncConfig = DriveSyncConfig()
    public var syncStatus: SyncStatus = SyncStatus()
    public var gdirectSnapshot: GDirectEnvironmentSnapshot = GDirectEnvironmentSnapshot()
    public var aiConfig: AIProviderConfig = AIProviderConfig()
    public var aiUsage: CloudAIUsageSummary = CloudAIUsageStore.shared.snapshot()
    public var hasStoredAIKey: Bool = false
    public var typeSafeConfig: TypeSafeExperimentalConfig = TypeSafeExperimentalConfig()
    public var hasStoredTypeSafeKey: Bool = false
    public var typeSafeModels: [TypeSafeModelInfo] = []
    public var isTestingAI: Bool = false
    public var isTestingTypeSafe: Bool = false
    public var isRebuildingVisualIndex: Bool = false
    public var rebuildVisualIndexProgress: (completed: Int, total: Int)? = nil
    public var cliLinkRevision: Int = 0
    public var isRunningExternalAgentSelfCheck: Bool = false
    public var externalAgentSelfCheckPassed: Bool? = nil
    public var externalAgentSelfCheckSummary: String? = nil
    public var chatGPTSession: ChatGPTAccountSession = ChatGPTAccountSession()
    public var chatGPTModels: [ChatGPTModelInfo] = []
    public var isSigningInChatGPT: Bool = false
    public var isLoadingChatGPTModels: Bool = false
    public var hasGoogleOAuthClient: Bool = false
    public var hasWebDAVPassword: Bool = false
    public var cacheStats: CacheStats = CacheStats()
    public var externalAgentConfig: ExternalAgentConfig = ExternalAgentConfig()

    public var lastSyncReport: SyncReport?
    public var lastMigrationReport: StorageMigrationReport?
    public var sharedFolders: [RemoteDriveFile] = []
    public var isLoadingSharedFolders: Bool = false
    public var statusMessage: String?
    public var errorMessage: String?
    public var isBusy: Bool = false
    public var isMigrating: Bool = false

    @ObservationIgnored
    private nonisolated(unsafe) var syncProgressObserver: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var aiUsageObserver: NSObjectProtocol?

    public init(engine: any CharkleEngineProtocol) {
        self.engine = engine

        syncProgressObserver = NotificationCenter.default.addObserver(
            forName: CharkleSyncNotifications.didUpdateSyncStatus,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let data = notification.userInfo?[CharkleSyncNotifications.statusDataKey] as? Data,
                  let decoded = try? JSONDecoder().decode(SyncStatus.self, from: data) else {
                return
            }
            Task { @MainActor [weak self] in
                self?.syncStatus = decoded
            }
        }

        aiUsageObserver = NotificationCenter.default.addObserver(
            forName: CloudAIUsageNotifications.didUpdateUsage,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let latest = CloudAIUsageStore.shared.snapshot()
            Task { @MainActor [weak self] in
                self?.aiUsage = latest
            }
        }
    }

    deinit {
        if let observer = syncProgressObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = aiUsageObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public func refreshSyncStatus() async {
        syncStatus = await engine.syncStatus()
    }

    public func refreshAIUsage() {
        aiUsage = CloudAIUsageStore.shared.snapshot()
    }

    public func resetAIUsage(category: CloudAIUsageCategory? = nil) {
        CloudAIUsageStore.shared.reset(category: category)
        aiUsage = CloudAIUsageStore.shared.snapshot()
        switch category {
        case .standard:
            statusMessage = "已清零普通云端模型用量统计"
        case .jev:
            statusMessage = "已清零 Jev 判断模型用量统计"
        case nil:
            statusMessage = "已清零全部云端模型用量统计"
        }
    }

    public private(set) var hasLoadedInitialState: Bool = false

    public func loadAll() async {
        async let cfg = engine.syncConfig()
        async let status = engine.syncStatus()
        async let gd = engine.probeGDirectEnvironment()
        async let ai = engine.aiConfig()
        async let stats = engine.cacheStats()
        async let oauthConfigured = engine.hasGoogleOAuthClientConfig()
        async let webdavPwd = engine.hasWebDAVPassword()
        async let gptSession = engine.chatGPTSession()
        async let tsCfg = engine.typeSafeConfig()
        async let tsHasKey = engine.hasStoredTypeSafeKey()

        let (sCfg, sStatus, gdSnap, aiCfg, cStats, hasOAuth, hasWebDAV, chatGPT, loadedTS, loadedTSKey) = await (
            cfg, status, gd, ai, stats, oauthConfigured, webdavPwd, gptSession, tsCfg, tsHasKey
        )
        let loadedAgentCfg = ExternalAgentConfigStore.load()
        let loadedUsage = CloudAIUsageStore.shared.snapshot()
        let loadedAIKey = await engine.hasStoredAIKey(for: aiCfg.provider)

        if syncConfig != sCfg { syncConfig = sCfg }
        if syncStatus != sStatus { syncStatus = sStatus }
        if gdirectSnapshot != gdSnap { gdirectSnapshot = gdSnap }
        if aiConfig != aiCfg { aiConfig = aiCfg }
        if typeSafeConfig != loadedTS { typeSafeConfig = loadedTS }
        if hasStoredTypeSafeKey != loadedTSKey { hasStoredTypeSafeKey = loadedTSKey }
        if cacheStats != cStats { cacheStats = cStats }
        if hasGoogleOAuthClient != hasOAuth { hasGoogleOAuthClient = hasOAuth }
        if hasWebDAVPassword != hasWebDAV { hasWebDAVPassword = hasWebDAV }
        if chatGPTSession != chatGPT { chatGPTSession = chatGPT }
        if externalAgentConfig != loadedAgentCfg { externalAgentConfig = loadedAgentCfg }
        if aiUsage != loadedUsage { aiUsage = loadedUsage }
        if hasStoredAIKey != loadedAIKey { hasStoredAIKey = loadedAIKey }
        hasLoadedInitialState = true

        if chatGPT.status == .connected && chatGPT.sharingEnabled && chatGPTModels.isEmpty {
            await refreshChatGPTModels(quiet: true)
        }
    }

    public func probeGDirect() async {
        isBusy = true
        defer { isBusy = false }
        gdirectSnapshot = await engine.probeGDirectEnvironment()
        statusMessage = "已刷新本机 gdirect 环境状态"
        errorMessage = nil
    }

    public func runGDirectScan() async {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            gdirectSnapshot = try await engine.runGDirectScan()
            statusMessage = "已完成直连 IP 扫描，发现 \(gdirectSnapshot.endpoints.count) 个可用节点"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func runGDirectMount(path: String?) async {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            gdirectSnapshot = try await engine.runGDirectMount(path: path)
            statusMessage = gdirectSnapshot.isMountActive
                ? "Google Drive 挂载成功：\(gdirectSnapshot.mountPath)"
                : "已执行挂载命令，请检查挂载状态"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func runGDirectUnmount() async {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            gdirectSnapshot = try await engine.runGDirectUnmount()
            syncStatus = await engine.syncStatus()
            statusMessage = "已卸载本机 GoogleDrive NFS 挂载，不再弹出系统断连提示"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func saveSyncConfig(_ config: DriveSyncConfig, quiet: Bool = true) async {
        errorMessage = nil
        do {
            try await engine.saveSyncConfig(config)
            syncConfig = config
            syncStatus = await engine.syncStatus()
            if !quiet {
                statusMessage = "已更新云同步设置"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    public func importGoogleOAuthSecret(from url: URL) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            try await engine.importGoogleOAuthSecret(from: url)
            hasGoogleOAuthClient = await engine.hasGoogleOAuthClientConfig()
            statusMessage = "已保存 Google 登录配置"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func importGoogleOAuthFromGDirect() async -> Bool {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            try await engine.importGoogleOAuthFromGDirect()
            hasGoogleOAuthClient = await engine.hasGoogleOAuthClientConfig()
            statusMessage = "已从本机 gdirect 自动导入 Google 登录凭据"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func saveWebDAVPassword(_ password: String) async -> Bool {
        errorMessage = nil
        do {
            try await engine.saveWebDAVPassword(password)
            hasWebDAVPassword = await engine.hasWebDAVPassword()
            statusMessage = "已保存 WebDAV 密码到 macOS 钥匙串"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func testWebDAVConnection(config: DriveSyncConfig, password: String?) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            if let password, !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await engine.saveWebDAVPassword(password)
                hasWebDAVPassword = await engine.hasWebDAVPassword()
            }
            try await engine.saveSyncConfig(config)
            syncConfig = config
            let info = try await engine.testWebDAVConnection(config: config, password: password)
            syncStatus = await engine.syncStatus()
            statusMessage = "WebDAV 连接成功：\(info.email)"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func migrateLibraryStorage(to targetConfig: DriveSyncConfig, webDAVPassword: String?) async -> StorageMigrationReport? {
        isBusy = true
        isMigrating = true
        defer {
            isBusy = false
            isMigrating = false
        }
        errorMessage = nil
        do {
            let report = try await engine.migrateLibraryStorage(to: targetConfig, webDAVPassword: webDAVPassword)
            lastMigrationReport = report
            syncConfig = await engine.syncConfig()
            syncStatus = await engine.syncStatus()
            cacheStats = await engine.cacheStats()
            hasWebDAVPassword = await engine.hasWebDAVPassword()
            statusMessage = "素材库已迁移至「\(report.targetLocation)」· 共 \(report.migratedAssets) 项素材、\(report.migratedFolders) 个文件夹、\(report.migratedBoards) 块情绪板"
            return report
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func saveGoogleOAuthClientConfig(clientID: String, clientSecret: String) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            try await engine.saveGoogleOAuthClientConfig(clientID: clientID, clientSecret: clientSecret)
            hasGoogleOAuthClient = await engine.hasGoogleOAuthClientConfig()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func signInGoogleDrive() async -> Bool {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            let account = try await engine.signInGoogleDrive()
            syncConfig = await engine.syncConfig()
            syncStatus = await engine.syncStatus()
            statusMessage = "已登录 Google 账号：\(account.email)"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func signOutGoogleDrive() async {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            try await engine.signOutGoogleDrive()
            syncStatus = await engine.syncStatus()
            statusMessage = "已退出 Google 账号"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    public func syncNow() async -> SyncReport? {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            let report = try await engine.syncNow()
            lastSyncReport = report
            syncStatus = await engine.syncStatus()
            cacheStats = await engine.cacheStats()
            statusMessage = "同步完成 · 上传 \(report.uploadedOps) / 拉取 \(report.downloadedOps) / 新发现 \(report.discoveredRemoteAssets) 项"
            return report
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = await engine.syncStatus()
            return nil
        }
    }

    /// Background sync on app launch / foreground return that discovers newly dropped files in Google Drive
    /// without flashing noisy error banners when offline or not signed in yet.
    @discardableResult
    public func syncQuietlyIfReady() async -> SyncReport? {
        guard !isBusy, !isMigrating else { return nil }
        let cfg = await engine.syncConfig()
        guard cfg.mode != .localOnly else { return nil }
        do {
            let report = try await engine.syncNow()
            lastSyncReport = report
            syncStatus = await engine.syncStatus()
            cacheStats = await engine.cacheStats()
            return report
        } catch {
            return nil
        }
    }

    public func loadSharedFolders() async {
        isLoadingSharedFolders = true
        defer { isLoadingSharedFolders = false }
        errorMessage = nil
        do {
            sharedFolders = try await engine.listGoogleDriveSharedFolders()
            if sharedFolders.isEmpty {
                statusMessage = "暂未在「与我共享」中发现共享文件夹，可直接粘贴 Google Drive 共享目录链接或 ID"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func saveAIConfig(_ config: AIProviderConfig, apiKey: String?, quiet: Bool = false) async {
        errorMessage = nil
        do {
            try await engine.saveAIConfig(config, apiKey: apiKey)
            aiConfig = config
            hasStoredAIKey = await engine.hasStoredAIKey(for: config.provider)
            if !quiet {
                statusMessage = "已保存 AI 配置（密钥仅存于 macOS 钥匙串）"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func refreshAIKeyPresence(for provider: CloudAIProviderKind) async {
        hasStoredAIKey = await engine.hasStoredAIKey(for: provider)
        if provider == .chatGPTSubscription {
            chatGPTSession = await engine.chatGPTSession()
            if chatGPTSession.status == .connected && chatGPTSession.sharingEnabled && chatGPTModels.isEmpty {
                await refreshChatGPTModels(quiet: true)
            }
        }
    }

    @discardableResult
    public func testAIConnection(config: AIProviderConfig, apiKey: String?) async -> Bool {
        isTestingAI = true
        defer { isTestingAI = false }
        errorMessage = nil
        do {
            let summary = try await engine.testAIConnection(config: config, apiKey: apiKey)
            if config.provider == .chatGPTSubscription {
                chatGPTSession = await engine.chatGPTSession()
                await refreshChatGPTModels(quiet: true)
            }
            statusMessage = summary
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func rebuildLocalVisualIndex(assetIDs: [UUID]) async -> Int {
        guard !assetIDs.isEmpty else {
            statusMessage = "当前素材库暂无需要扫描的素材"
            return 0
        }
        isRebuildingVisualIndex = true
        rebuildVisualIndexProgress = (0, assetIDs.count)
        defer {
            isRebuildingVisualIndex = false
            rebuildVisualIndexProgress = nil
        }
        errorMessage = nil
        let batchSize = 16
        var processed = 0
        do {
            var idx = 0
            while idx < assetIDs.count {
                let end = min(assetIDs.count, idx + batchSize)
                let slice = Array(assetIDs[idx..<end])
                let updated = try await engine.analyzeAssetsLocally(ids: slice)
                processed += updated.count
                rebuildVisualIndexProgress = (end, assetIDs.count)
                idx = end
            }
            statusMessage = "已完成本机视觉与文字索引扫描（共更新 \(processed) 项素材）"
            return processed
        } catch {
            errorMessage = "重建视觉索引失败：\(error.localizedDescription)"
            return processed
        }
    }

    @discardableResult
    public func signInWithChatGPT(reconsent: Bool = false, switchAccount: Bool = false) async -> Bool {
        isSigningInChatGPT = true
        defer { isSigningInChatGPT = false }
        errorMessage = nil
        do {
            let session = try await engine.signInWithChatGPT(reconsent: reconsent, switchAccount: switchAccount)
            chatGPTSession = session
            aiConfig = await engine.aiConfig()
            hasStoredAIKey = await engine.hasStoredAIKey(for: .chatGPTSubscription)
            if session.sharingEnabled {
                await refreshChatGPTModels(quiet: true)
                statusMessage = "已连接 ChatGPT 订阅账号：\(session.displayName)"
            } else {
                statusMessage = "已登录 ChatGPT（\(session.displayName)），如需使用订阅额度请重新授权额度共享"
            }
            return true
        } catch {
            chatGPTSession = await engine.chatGPTSession()
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func disconnectChatGPT(resetRegistration: Bool = false) async {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            try await engine.disconnectChatGPT(resetRegistration: resetRegistration)
            chatGPTSession = await engine.chatGPTSession()
            chatGPTModels = []
            hasStoredAIKey = await engine.hasStoredAIKey(for: aiConfig.provider)
            statusMessage = "已退出 ChatGPT 账号连接"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func refreshChatGPTModels(quiet: Bool = false) async {
        isLoadingChatGPTModels = true
        defer { isLoadingChatGPTModels = false }
        if !quiet { errorMessage = nil }
        do {
            let models = try await engine.listChatGPTModels()
            chatGPTModels = models
            chatGPTSession = await engine.chatGPTSession()
            if !quiet {
                statusMessage = "已获取 \(models.count) 个可用的 ChatGPT 订阅模型"
            }
        } catch {
            chatGPTSession = await engine.chatGPTSession()
            if !quiet {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Experimental TypeSafe System One (Jev)

    public func saveTypeSafeConfig(
        _ config: TypeSafeExperimentalConfig,
        apiKey: String?,
        quiet: Bool = false
    ) async {
        errorMessage = nil
        do {
            try await engine.saveTypeSafeConfig(config, apiKey: apiKey)
            typeSafeConfig = await engine.typeSafeConfig()
            hasStoredTypeSafeKey = await engine.hasStoredTypeSafeKey()
            if !quiet {
                statusMessage = "已保存 TypeSafe (Jev) 实验配置（密钥仅存于 macOS 钥匙串）"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    public func testTypeSafeConnection(
        config: TypeSafeExperimentalConfig,
        apiKey: String?
    ) async -> Bool {
        isTestingTypeSafe = true
        defer { isTestingTypeSafe = false }
        errorMessage = nil
        do {
            let models = try await engine.testTypeSafeConnection(config: config, apiKey: apiKey)
            typeSafeModels = models
            let names = models.map(\.name).joined(separator: "、")
            statusMessage = models.isEmpty
                ? "TypeSafe API 连接成功"
                : "TypeSafe 连接成功 · 可用模型：\(names)"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func setCacheBudgetGB(_ gb: Double) async {
        let bytes = Int64(max(2, min(100, gb)) * 1024 * 1024 * 1024)
        await engine.setCacheBudgetBytes(bytes)
        cacheStats = await engine.cacheStats()
    }

    public func evictCacheNow() async {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            cacheStats = try await engine.evictCacheNow()
            statusMessage = "已释放临时本地缓存（已保留在本地的内容未受影响）"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - External Agent (MCP & CLI) Configuration

    public func saveExternalAgentConfig(_ config: ExternalAgentConfig, quiet: Bool = false) {
        do {
            try ExternalAgentConfigStore.save(config)
            externalAgentConfig = config
            errorMessage = nil
            if !quiet {
                switch (config.mcpEnabled, config.cliEnabled) {
                case (true, true):
                    statusMessage = "MCP 与 CLI 服务均已开启 · 权限：\(config.accessLevel.displayTitle)"
                case (true, false):
                    statusMessage = "已开启 MCP 服务（CLI 已关闭）· 权限：\(config.accessLevel.displayTitle)"
                case (false, true):
                    statusMessage = "已开启 CLI 命令行服务（MCP 已关闭）· 权限：\(config.accessLevel.displayTitle)"
                case (false, false):
                    statusMessage = "已关闭 MCP 与 CLI 外部接入服务"
                }
            }
        } catch {
            errorMessage = "保存外部 Agent 配置失败：\(error.localizedDescription)"
        }
    }

    public func resolvedHelperCLIPath() -> String {
        let bundled = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/charkle")
            .path
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let appApplications = "/Applications/Charkle.app/Contents/Helpers/charkle"
        if FileManager.default.isExecutableFile(atPath: appApplications) {
            return appApplications
        }
        return bundled
    }

    public var isBundledHelperAvailable: Bool {
        _ = cliLinkRevision
        return FileManager.default.isExecutableFile(atPath: resolvedHelperCLIPath())
    }

    public enum CLILinkStatus: Equatable, Sendable {
        case notLinked
        case linkedCurrent
        case linkedStale(target: String)
        case broken
    }

    public var cliLinkStatus: CLILinkStatus {
        _ = cliLinkRevision
        let fm = FileManager.default
        let linkPath = URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: ".local/bin/charkle").path
        let currentHelper = URL(fileURLWithPath: resolvedHelperCLIPath()).resolvingSymlinksInPath().path

        if let dest = try? fm.destinationOfSymbolicLink(atPath: linkPath) {
            guard fm.isExecutableFile(atPath: linkPath) else {
                return .broken
            }
            let resolvedDest = URL(fileURLWithPath: dest).resolvingSymlinksInPath().path
            if fm.isExecutableFile(atPath: currentHelper) && resolvedDest != currentHelper {
                return .linkedStale(target: dest)
            }
            return .linkedCurrent
        }
        return fm.isExecutableFile(atPath: linkPath) ? .linkedCurrent : .notLinked
    }

    public var isCLILinkedInLocalBin: Bool {
        switch cliLinkStatus {
        case .linkedCurrent, .linkedStale: true
        case .notLinked, .broken: false
        }
    }

    public func installCLIInLocalBin() {
        let sourcePath = resolvedHelperCLIPath()
        guard FileManager.default.isExecutableFile(atPath: sourcePath) else {
            errorMessage = "未在当前应用包中找到 charkle 助手程序，请先使用正式打包后的 Charkle.app 运行。"
            return
        }
        let localBin = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".local/bin", directoryHint: .isDirectory)
        let targetURL = localBin.appending(path: "charkle")
        do {
            try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: targetURL.path) || (try? FileManager.default.attributesOfItem(atPath: targetURL.path)) != nil {
                try FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.createSymbolicLink(atPath: targetURL.path, withDestinationPath: sourcePath)
            cliLinkRevision &+= 1
            errorMessage = nil
            statusMessage = "已链接终端命令至 ~/.local/bin/charkle，可直接运行 charkle doctor"
        } catch {
            errorMessage = "创建命令行链接失败：\(error.localizedDescription)"
        }
    }

    public func runExternalAgentSelfCheck() async {
        guard !isRunningExternalAgentSelfCheck else { return }
        isRunningExternalAgentSelfCheck = true
        defer { isRunningExternalAgentSelfCheck = false }

        let helperPath = resolvedHelperCLIPath()
        let helperExists = FileManager.default.isExecutableFile(atPath: helperPath)
        cliLinkRevision &+= 1

        if helperExists {
            let outcome: (ok: Bool, summary: String) = await Task.detached(priority: .userInitiated) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: helperPath)
                proc.arguments = ["doctor", "--json"]
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                proc.standardOutput = stdoutPipe
                proc.standardError = stderrPipe
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    if proc.terminationStatus == 0,
                       let obj = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
                       (obj["ok"] as? Bool) == true {
                        let caps = obj["capabilities"] as? [String: Any]
                        let lib = obj["library"] as? [String: Any]
                        let tools = (caps?["toolCount"] as? Int) ?? 0
                        let prompts = (caps?["promptCount"] as? Int) ?? 0
                        let assets = (lib?["totalAssets"] as? Int) ?? 0
                        let boards = (lib?["boardCount"] as? Int) ?? 0
                        return (true, "自检通过 · 原生助手响应正常（\(tools) 工具 / \(prompts) 工作流 / \(assets) 素材 / \(boards) 情绪板）")
                    }
                    let errStr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return (false, errStr.isEmpty ? "原生助手返回异常退出码 \(proc.terminationStatus)" : "自检失败：\(errStr)")
                } catch {
                    return (false, "无法启动原生助手：\(error.localizedDescription)")
                }
            }.value

            externalAgentSelfCheckPassed = outcome.ok
            externalAgentSelfCheckSummary = outcome.summary
            if outcome.ok {
                statusMessage = outcome.summary
                errorMessage = nil
            } else {
                errorMessage = outcome.summary
            }
            return
        }

        // Fallback when running unbundled during local SwiftPM development: check in-process service.
        if let liveEngine = engine as? LiveCharkleEngine {
            let service = CharkleExternalAgentService(engine: liveEngine, notifyOnWrite: false)
            let report = await service.runDiagnostics()
            let ok = (report["ok"] as? Bool) == true
            let caps = report["capabilities"] as? [String: Any]
            let tools = (caps?["toolCount"] as? Int) ?? 0
            let prompts = (caps?["promptCount"] as? Int) ?? 0
            externalAgentSelfCheckPassed = ok
            externalAgentSelfCheckSummary = ok
                ? "开发态内核自检通过（\(tools) 工具 / \(prompts) 工作流），打包为 Charkle.app 后即内嵌独立原生助手"
                : "内核自检未通过"
        } else {
            externalAgentSelfCheckPassed = false
            externalAgentSelfCheckSummary = "未找到原生 charkle 助手程序"
        }
    }
}
