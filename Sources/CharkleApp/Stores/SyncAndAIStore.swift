import CharkleCore
import Foundation

/// Domain store for Google Drive + `gdirect` dual-channel sync, hybrid local/cloud AI configuration,
/// and two-tier thumbnail/original LRU cache telemetry.
@Observable
public final class SyncAndAIStore {
    public let engine: any CharkleEngineProtocol

    public var syncConfig: DriveSyncConfig = DriveSyncConfig()
    public var syncStatus: SyncStatus = SyncStatus()
    public var iCloudAvailability: ICloudDriveAvailability = ICloudDriveAvailability()
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
    public var isRunningExternalAgentSelfCheck: Bool = false
    public var externalAgentSelfCheckPassed: Bool? = nil
    public var externalAgentSelfCheckSummary: String? = nil
    public var lastCreatedAgentTokenPlaintext: String? = nil
    public var lastCreatedAgentTokenName: String? = nil
    public var chatGPTSession: ChatGPTAccountSession = ChatGPTAccountSession()
    public var chatGPTModels: [ChatGPTModelInfo] = []
    public var isSigningInChatGPT: Bool = false
    public var isLoadingChatGPTModels: Bool = false
    public var hasGoogleOAuthClient: Bool = false
    public var hasWebDAVPassword: Bool = false
    public var cacheStats: CacheStats = CacheStats()
    public var externalAgentConfig: ExternalAgentConfig = ExternalAgentConfig()

    public struct SettingsFeedbackEvent: Equatable, Sendable {
        public let id: UInt64
        public let message: String
        public let isError: Bool
    }

    public var lastSyncReport: SyncReport?
    public var lastMigrationReport: StorageMigrationReport?
    public var sharedFolders: [RemoteDriveFile] = []
    public var isLoadingSharedFolders: Bool = false
    public private(set) var lastFeedbackEvent: SettingsFeedbackEvent?
    public var statusMessage: String? {
        didSet {
            if let message = statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                feedbackSequence &+= 1
                lastFeedbackEvent = SettingsFeedbackEvent(id: feedbackSequence, message: message, isError: false)
            }
        }
    }
    public var errorMessage: String? {
        didSet {
            if let message = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                feedbackSequence &+= 1
                lastFeedbackEvent = SettingsFeedbackEvent(id: feedbackSequence, message: message, isError: true)
            }
        }
    }
    public var isBusy: Bool = false
    public var isMigrating: Bool = false

    @ObservationIgnored
    private var feedbackSequence: UInt64 = 0

    @ObservationIgnored
    private static let syncStatusDecoder = JSONDecoder()
    @ObservationIgnored
    private var cachedHelperMCPPathValue: String?
    @ObservationIgnored
    private var cachedBundledHelperAvailableValue: Bool = false
    @ObservationIgnored
    public var onExternalAgentConfigChanged: (@MainActor (ExternalAgentConfig) -> Void)?

    @ObservationIgnored
    private nonisolated(unsafe) var syncProgressObserver: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var aiUsageObserver: NSObjectProtocol?
    @ObservationIgnored
    private var busyCount: Int = 0
    @ObservationIgnored
    private var isQuietSyncInFlight: Bool = false
    @ObservationIgnored
    private var isSyncingNow: Bool = false
    @ObservationIgnored
    private var isSigningInGoogleDrive: Bool = false

    public init(engine: any CharkleEngineProtocol) {
        self.engine = engine

        syncProgressObserver = NotificationCenter.default.addObserver(
            forName: CharkleSyncNotifications.didUpdateSyncStatus,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let data = notification.userInfo?[CharkleSyncNotifications.statusDataKey] as? Data else {
                return
            }
            MainActor.assumeIsolated {
                guard let self,
                      let decoded = try? Self.syncStatusDecoder.decode(SyncStatus.self, from: data) else {
                    return
                }
                if self.isQuietSyncInFlight && !self.isSyncingNow, case .error = decoded.phase {
                    return
                }
                if self.syncStatus != decoded {
                    self.syncStatus = decoded
                }
            }
        }

        aiUsageObserver = NotificationCenter.default.addObserver(
            forName: CloudAIUsageNotifications.didUpdateUsage,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let latest = CloudAIUsageStore.shared.snapshot()
            MainActor.assumeIsolated {
                guard let self, self.aiUsage != latest else { return }
                self.aiUsage = latest
            }
        }
    }

    private func beginBusy() {
        busyCount += 1
        if !isBusy { isBusy = true }
    }

    private func endBusy() {
        busyCount = max(0, busyCount - 1)
        if busyCount == 0 && isBusy { isBusy = false }
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
        let latest = await engine.syncStatus()
        if syncStatus != latest {
            syncStatus = latest
        }
    }

    public func refreshAIUsage() {
        let latest = CloudAIUsageStore.shared.snapshot()
        if aiUsage != latest {
            aiUsage = latest
        }
    }

    public func resetAIUsage(category: CloudAIUsageCategory? = nil) {
        CloudAIUsageStore.shared.reset(category: category)
        aiUsage = CloudAIUsageStore.shared.snapshot()
        errorMessage = nil
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
        async let icloud = engine.probeICloudDriveAvailability()
        async let gd = engine.probeGDirectEnvironment()
        async let ai = engine.aiConfig()
        async let stats = engine.cacheStats()
        async let oauthConfigured = engine.hasGoogleOAuthClientConfig()
        async let webdavPwd = engine.hasWebDAVPassword()
        async let gptSession = engine.chatGPTSession()
        async let tsCfg = engine.typeSafeConfig()
        async let tsHasKey = engine.hasStoredTypeSafeKey()

        let (sCfg, sStatus, icloudAvail, gdSnap, aiCfg, cStats, hasOAuth, hasWebDAV, chatGPT, loadedTS, loadedTSKey) = await (
            cfg, status, icloud, gd, ai, stats, oauthConfigured, webdavPwd, gptSession, tsCfg, tsHasKey
        )
        let loadedAgentCfg = ExternalAgentConfigStore.load()
        let loadedUsage = CloudAIUsageStore.shared.snapshot()
        let loadedAIKey = await engine.hasStoredAIKey(for: aiCfg.provider)

        if syncConfig != sCfg { syncConfig = sCfg }
        if syncStatus != sStatus { syncStatus = sStatus }
        if iCloudAvailability != icloudAvail { iCloudAvailability = icloudAvail }
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
        if !hasLoadedInitialState { hasLoadedInitialState = true }

        if chatGPT.status == .connected && chatGPT.sharingEnabled && chatGPTModels.isEmpty {
            await refreshChatGPTModels(quiet: true)
        }
    }

    public func probeGDirect() async {
        beginBusy()
        defer { endBusy() }
        gdirectSnapshot = await engine.probeGDirectEnvironment()
        statusMessage = "已刷新本机 gdirect 环境状态"
        errorMessage = nil
    }

    public func runGDirectScan() async {
        beginBusy()
        defer { endBusy() }
        errorMessage = nil
        do {
            gdirectSnapshot = try await engine.runGDirectScan()
            statusMessage = "已完成直连 IP 扫描，发现 \(gdirectSnapshot.endpoints.count) 个可用节点"
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    public func runGDirectMount(path: String?) async {
        beginBusy()
        defer { endBusy() }
        errorMessage = nil
        do {
            gdirectSnapshot = try await engine.runGDirectMount(path: path)
            statusMessage = gdirectSnapshot.isMountActive
                ? "Google Drive 挂载成功：\(gdirectSnapshot.mountPath)"
                : "已执行挂载命令，请检查挂载状态"
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    public func runGDirectUnmount() async {
        beginBusy()
        defer { endBusy() }
        errorMessage = nil
        do {
            gdirectSnapshot = try await engine.runGDirectUnmount()
            syncStatus = await engine.syncStatus()
            statusMessage = "已卸载本机 GoogleDrive NFS 挂载，不再弹出系统断连提示"
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    public func saveSyncConfig(
        _ config: DriveSyncConfig,
        quiet: Bool = true,
        successMessage: String? = nil
    ) async {
        errorMessage = nil
        do {
            try await engine.saveSyncConfig(config)
            syncConfig = config
            syncStatus = await engine.syncStatus()
            if let successMessage {
                statusMessage = successMessage
            } else if !quiet {
                statusMessage = "已更新云同步设置"
            }
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    public func importGoogleOAuthSecret(from url: URL) async -> Bool {
        beginBusy()
        defer { endBusy() }
        errorMessage = nil
        do {
            try await engine.importGoogleOAuthSecret(from: url)
            hasGoogleOAuthClient = await engine.hasGoogleOAuthClientConfig()
            statusMessage = "已保存 Google 登录配置"
            return true
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func importGoogleOAuthFromGDirect() async -> Bool {
        beginBusy()
        defer { endBusy() }
        errorMessage = nil
        do {
            try await engine.importGoogleOAuthFromGDirect()
            hasGoogleOAuthClient = await engine.hasGoogleOAuthClientConfig()
            statusMessage = "已从本机 gdirect 自动导入 Google 登录凭据"
            return true
        } catch {
            statusMessage = nil
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
            statusMessage = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func testWebDAVConnection(config: DriveSyncConfig, password: String?) async -> Bool {
        beginBusy()
        defer { endBusy() }
        errorMessage = nil
        do {
            // Validate connectivity BEFORE persisting credentials or overwriting active syncConfig
            // so a failed test never corrupts an already working sync configuration.
            let info = try await engine.testWebDAVConnection(config: config, password: password)
            if let password, !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await engine.saveWebDAVPassword(password)
                hasWebDAVPassword = await engine.hasWebDAVPassword()
            }
            try await engine.saveSyncConfig(config)
            syncConfig = config
            syncStatus = await engine.syncStatus()
            statusMessage = "WebDAV 连接成功：\(info.email)"
            return true
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func migrateLibraryStorage(to targetConfig: DriveSyncConfig, webDAVPassword: String?) async -> StorageMigrationReport? {
        guard !isMigrating else { return nil }
        beginBusy()
        isMigrating = true
        defer {
            endBusy()
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
            syncConfig = await engine.syncConfig()
            syncStatus = await engine.syncStatus()
            hasWebDAVPassword = await engine.hasWebDAVPassword()
            statusMessage = nil
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func saveGoogleOAuthClientConfig(clientID: String, clientSecret: String) async -> Bool {
        beginBusy()
        defer { endBusy() }
        errorMessage = nil
        do {
            try await engine.saveGoogleOAuthClientConfig(clientID: clientID, clientSecret: clientSecret)
            hasGoogleOAuthClient = await engine.hasGoogleOAuthClientConfig()
            return true
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func signInGoogleDrive() async -> Bool {
        guard !isSigningInGoogleDrive else { return false }
        isSigningInGoogleDrive = true
        beginBusy()
        defer {
            isSigningInGoogleDrive = false
            endBusy()
        }
        errorMessage = nil
        do {
            let account = try await engine.signInGoogleDrive()
            syncConfig = await engine.syncConfig()
            syncStatus = await engine.syncStatus()
            statusMessage = "已登录 Google 账号：\(account.email)"
            return true
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func signOutGoogleDrive() async {
        beginBusy()
        defer { endBusy() }
        errorMessage = nil
        do {
            try await engine.signOutGoogleDrive()
            syncStatus = await engine.syncStatus()
            statusMessage = "已退出 Google 账号"
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    public func syncNow() async -> SyncReport? {
        guard !isSyncingNow, !isMigrating else { return nil }
        isSyncingNow = true
        beginBusy()
        defer {
            isSyncingNow = false
            endBusy()
        }
        errorMessage = nil
        do {
            let report = try await engine.syncNow()
            lastSyncReport = report
            syncStatus = await engine.syncStatus()
            cacheStats = await engine.cacheStats()
            statusMessage = "同步完成 · 上传 \(report.uploadedOps) / 拉取 \(report.downloadedOps) / 新发现 \(report.discoveredRemoteAssets) 项"
            return report
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
            syncStatus = await engine.syncStatus()
            return nil
        }
    }

    /// Background sync on app launch / foreground return that discovers newly dropped files in Google Drive
    /// without flashing noisy error banners when offline or not signed in yet.
    @discardableResult
    public func syncQuietlyIfReady() async -> SyncReport? {
        guard !isBusy, !isMigrating, !isSyncingNow, !isQuietSyncInFlight else { return nil }
        let cfg = await engine.syncConfig()
        guard !cfg.enabledCloudBackends.isEmpty else { return nil }
        isQuietSyncInFlight = true
        defer { isQuietSyncInFlight = false }
        let previousStatus = syncStatus
        do {
            let report = try await engine.syncNow()
            lastSyncReport = report
            syncStatus = await engine.syncStatus()
            cacheStats = await engine.cacheStats()
            return report
        } catch {
            let latest = await engine.syncStatus()
            if case .error = latest.phase {
                syncStatus = previousStatus
            } else {
                syncStatus = latest
            }
            return nil
        }
    }

    // MARK: - Multi-Backend & iCloud Drive Management

    @discardableResult
    public func upsertBackend(
        _ profile: SyncBackendProfile,
        webDAVPassword: String? = nil,
        iCloudBookmarkData: Data? = nil
    ) async -> Bool {
        errorMessage = nil
        do {
            var next = syncConfig
            var list = next.resolvedBackends
            if let idx = list.firstIndex(where: { $0.id == profile.id }) {
                list[idx] = profile
            } else {
                var added = profile
                if list.isEmpty || (list.count == 1 && list[0].mode == .localOnly && profile.mode.isCloudBacked) {
                    added.isPrimary = true
                    for i in list.indices { list[i].isPrimary = false }
                }
                list.append(added)
            }
            next.backends = list
            next.synchronizePrimaryFields()
            if profile.mode == .webDAV, let webDAVPassword, !webDAVPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await engine.saveBackendWebDAVPassword(webDAVPassword, for: profile.id)
                hasWebDAVPassword = await engine.hasWebDAVPassword()
            }
            if profile.mode == .iCloudDrive, let iCloudBookmarkData {
                try await engine.saveICloudBookmark(iCloudBookmarkData, displayPath: profile.iCloudCustomFolderPath, for: profile.id)
            }
            try await engine.saveSyncConfig(next)
            syncConfig = await engine.syncConfig()
            syncStatus = await engine.syncStatus()
            statusMessage = "已保存同步后端「\(profile.name)」"
            return true
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func removeBackend(id: UUID) async {
        var next = syncConfig
        var list = next.resolvedBackends
        guard list.count > 1 else {
            errorMessage = "至少需要保留一个存储后端。"
            return
        }
        let removedName = list.first(where: { $0.id == id })?.name
        list.removeAll { $0.id == id }
        next.backends = list
        next.synchronizePrimaryFields()
        let message = removedName.map { "已移除同步后端「\($0)」" } ?? "已移除同步后端"
        await saveSyncConfig(next, quiet: false, successMessage: message)
    }

    public func setBackendEnabled(id: UUID, enabled: Bool) async {
        var next = syncConfig
        var list = next.resolvedBackends
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        let backendName = list[idx].name
        list[idx].isEnabled = enabled
        next.backends = list
        next.synchronizePrimaryFields()
        let message = enabled ? "已启用同步后端「\(backendName)」" : "已暂停同步后端「\(backendName)」"
        await saveSyncConfig(next, quiet: false, successMessage: message)
    }

    public func setPrimaryBackend(id: UUID) async {
        var next = syncConfig
        var list = next.resolvedBackends
        guard let target = list.first(where: { $0.id == id }) else { return }
        for idx in list.indices {
            list[idx].isPrimary = (list[idx].id == id)
            if list[idx].id == id { list[idx].isEnabled = true }
        }
        next.backends = list
        next.synchronizePrimaryFields()
        await saveSyncConfig(next, quiet: false, successMessage: "已将「\(target.name)」设为主同步后端")
    }

    @discardableResult
    public func testBackendConnection(_ profile: SyncBackendProfile, webDAVPassword: String? = nil) async -> Bool {
        beginBusy()
        defer { endBusy() }
        errorMessage = nil
        do {
            let info = try await engine.testBackendConnection(profile, webDAVPassword: webDAVPassword)
            statusMessage = "「\(profile.name)」连接正常：\(info.email)"
            return true
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func syncBackend(id: UUID) async -> SyncReport? {
        guard !isSyncingNow, !isMigrating else { return nil }
        isSyncingNow = true
        beginBusy()
        defer {
            isSyncingNow = false
            endBusy()
        }
        errorMessage = nil
        do {
            let report = try await engine.syncBackend(id: id)
            lastSyncReport = report
            syncStatus = await engine.syncStatus()
            cacheStats = await engine.cacheStats()
            statusMessage = "单后端同步完成 · ↑ \(report.uploadedOps) / ↓ \(report.downloadedOps)"
            return report
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
            syncStatus = await engine.syncStatus()
            return nil
        }
    }

    public func loadSharedFolders() async {
        guard !isLoadingSharedFolders else { return }
        isLoadingSharedFolders = true
        defer { isLoadingSharedFolders = false }
        errorMessage = nil
        do {
            sharedFolders = try await engine.listGoogleDriveSharedFolders()
            if sharedFolders.isEmpty {
                statusMessage = "暂未在「与我共享」中发现共享文件夹，可直接粘贴 Google Drive 共享目录链接或 ID"
            }
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    public func saveAIConfig(
        _ config: AIProviderConfig,
        apiKey: String?,
        quiet: Bool = false,
        successMessage: String? = nil
    ) async {
        errorMessage = nil
        do {
            try await engine.saveAIConfig(config, apiKey: apiKey)
            aiConfig = config
            hasStoredAIKey = await engine.hasStoredAIKey(for: config.provider)
            if let successMessage {
                statusMessage = successMessage
            } else if !quiet {
                statusMessage = "已保存 AI 配置（密钥仅存于 macOS 钥匙串）"
            }
        } catch {
            statusMessage = nil
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
        guard !isTestingAI else { return false }
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
            statusMessage = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func rebuildLocalVisualIndex(assetIDs: [UUID]) async -> Int {
        guard !isRebuildingVisualIndex else { return 0 }
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
                try Task.checkCancellation()
                let end = min(assetIDs.count, idx + batchSize)
                let slice = Array(assetIDs[idx..<end])
                let updated = try await engine.analyzeAssetsLocally(ids: slice)
                processed += updated.count
                rebuildVisualIndexProgress = (end, assetIDs.count)
                idx = end
            }
            statusMessage = "已完成本机视觉与文字索引扫描（共更新 \(processed) 项素材）"
            return processed
        } catch is CancellationError {
            return processed
        } catch {
            statusMessage = nil
            errorMessage = "重建视觉索引失败：\(error.localizedDescription)"
            return processed
        }
    }

    @discardableResult
    public func signInWithChatGPT(reconsent: Bool = false, switchAccount: Bool = false) async -> Bool {
        guard !isSigningInChatGPT else { return false }
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
            statusMessage = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func disconnectChatGPT(resetRegistration: Bool = false) async {
        beginBusy()
        defer { endBusy() }
        errorMessage = nil
        do {
            try await engine.disconnectChatGPT(resetRegistration: resetRegistration)
            chatGPTSession = await engine.chatGPTSession()
            chatGPTModels = []
            hasStoredAIKey = await engine.hasStoredAIKey(for: aiConfig.provider)
            statusMessage = "已退出 ChatGPT 账号连接"
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    public func refreshChatGPTModels(quiet: Bool = false) async {
        guard !isLoadingChatGPTModels else { return }
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
                statusMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Experimental TypeSafe System One (Jev)

    public func saveTypeSafeConfig(
        _ config: TypeSafeExperimentalConfig,
        apiKey: String?,
        quiet: Bool = false,
        successMessage: String? = nil
    ) async {
        errorMessage = nil
        do {
            try await engine.saveTypeSafeConfig(config, apiKey: apiKey)
            typeSafeConfig = await engine.typeSafeConfig()
            hasStoredTypeSafeKey = await engine.hasStoredTypeSafeKey()
            if let successMessage {
                statusMessage = successMessage
            } else if !quiet {
                statusMessage = "已保存 TypeSafe (Jev) 实验配置（密钥仅存于 macOS 钥匙串）"
            }
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    public func testTypeSafeConnection(
        config: TypeSafeExperimentalConfig,
        apiKey: String?
    ) async -> Bool {
        guard !isTestingTypeSafe else { return false }
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
            statusMessage = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func setCacheBudgetGB(_ gb: Double) async {
        let clamped = max(2, min(100, gb))
        let bytes = Int64(clamped * 1024 * 1024 * 1024)
        await engine.setCacheBudgetBytes(bytes)
        cacheStats = await engine.cacheStats()
        errorMessage = nil
        statusMessage = "临时原件缓存上限已调整为 \(Int(clamped.rounded())) GB"
    }

    public func evictCacheNow() async {
        beginBusy()
        defer { endBusy() }
        errorMessage = nil
        do {
            cacheStats = try await engine.evictCacheNow()
            statusMessage = "已释放临时本地缓存（已保留在本地的内容未受影响）"
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - External Agent (Pure MCP v2: stdio + Streamable HTTP) Configuration

    public func saveExternalAgentConfig(_ config: ExternalAgentConfig, quiet: Bool = false) {
        do {
            try ExternalAgentConfigStore.save(config)
            externalAgentConfig = config
            onExternalAgentConfigChanged?(config)
            errorMessage = nil
            if !quiet {
                switch (config.mcpEnabled, config.httpMCPEnabled) {
                case (true, true):
                    let remoteNote = config.allowRemoteHTTPMCP ? "（含跨机器远程）" : "（仅本机）"
                    statusMessage = "本机与 HTTP MCP\(remoteNote) 已开启 · 本机权限：\(config.accessLevel.displayTitle)"
                case (true, false):
                    statusMessage = "已开启本机 MCP（stdio）· 权限：\(config.accessLevel.displayTitle)"
                case (false, true):
                    statusMessage = "已开启 HTTP MCP 服务"
                case (false, false):
                    statusMessage = "已关闭所有外部 MCP 接入服务"
                }
            }
        } catch {
            statusMessage = nil
            errorMessage = "保存外部 Agent 配置失败：\(error.localizedDescription)"
        }
    }

    public func createExternalAgentToken(name: String, accessLevel: ExternalAgentAccessLevel) {
        let minted = ExternalAgentToken.mint(name: name, accessLevel: accessLevel)
        var updated = externalAgentConfig
        updated.tokens.insert(minted.record, at: 0)
        do {
            try ExternalAgentConfigStore.save(updated)
            externalAgentConfig = updated
            onExternalAgentConfigChanged?(updated)
            lastCreatedAgentTokenPlaintext = minted.plaintext
            lastCreatedAgentTokenName = minted.record.name
            errorMessage = nil
            statusMessage = "已生成远程 MCP 密钥「\(minted.record.name)」，请立即复制保存（明文仅显示一次）"
        } catch {
            statusMessage = nil
            errorMessage = "生成远程 MCP 密钥失败：\(error.localizedDescription)"
        }
    }

    public func revokeExternalAgentToken(id: UUID) {
        var updated = externalAgentConfig
        let removedName = updated.tokens.first(where: { $0.id == id })?.name
        updated.tokens.removeAll { $0.id == id }
        do {
            try ExternalAgentConfigStore.save(updated)
            externalAgentConfig = updated
            onExternalAgentConfigChanged?(updated)
            errorMessage = nil
            statusMessage = "已吊销 MCP 密钥\(removedName.map { "「\($0)」" } ?? "")"
        } catch {
            statusMessage = nil
            errorMessage = "吊销密钥失败：\(error.localizedDescription)"
        }
    }

    public func setExternalAgentTokenEnabled(id: UUID, enabled: Bool) {
        var updated = externalAgentConfig
        guard let idx = updated.tokens.firstIndex(where: { $0.id == id }) else { return }
        updated.tokens[idx].isEnabled = enabled
        saveExternalAgentConfig(updated, quiet: true)
        statusMessage = enabled
            ? "已启用密钥「\(updated.tokens[idx].name)」"
            : "已暂停密钥「\(updated.tokens[idx].name)」"
    }

    public func updateExternalAgentTokenScope(id: UUID, accessLevel: ExternalAgentAccessLevel) {
        var updated = externalAgentConfig
        guard let idx = updated.tokens.firstIndex(where: { $0.id == id }) else { return }
        updated.tokens[idx].accessLevel = accessLevel
        saveExternalAgentConfig(updated, quiet: true)
        statusMessage = "已更新密钥「\(updated.tokens[idx].name)」权限为：\(accessLevel.displayTitle)"
    }

    public func clearCreatedAgentTokenBanner() {
        lastCreatedAgentTokenPlaintext = nil
        lastCreatedAgentTokenName = nil
    }

    private func ensureHelperProbeCacheFresh() {
        guard cachedHelperMCPPathValue == nil else { return }
        let fm = FileManager.default
        let bundled = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/charkle")
            .path
        if fm.isExecutableFile(atPath: bundled) {
            cachedHelperMCPPathValue = bundled
            cachedBundledHelperAvailableValue = true
            return
        }
        let appApplications = "/Applications/Charkle.app/Contents/Helpers/charkle"
        if fm.isExecutableFile(atPath: appApplications) {
            cachedHelperMCPPathValue = appApplications
            cachedBundledHelperAvailableValue = true
            return
        }
        cachedHelperMCPPathValue = bundled
        cachedBundledHelperAvailableValue = false
    }

    public func resolvedHelperMCPPath() -> String {
        ensureHelperProbeCacheFresh()
        return cachedHelperMCPPathValue ?? Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/charkle")
            .path
    }

    public var isBundledHelperAvailable: Bool {
        ensureHelperProbeCacheFresh()
        return cachedBundledHelperAvailableValue
    }

    public func runExternalAgentSelfCheck() async {
        guard !isRunningExternalAgentSelfCheck else { return }
        isRunningExternalAgentSelfCheck = true
        defer { isRunningExternalAgentSelfCheck = false }

        cachedHelperMCPPathValue = nil
        let helperPath = resolvedHelperMCPPath()
        let helperExists = FileManager.default.isExecutableFile(atPath: helperPath)

        if helperExists {
            let outcome = await Self.runHelperDoctorProcess(helperPath: helperPath)
            externalAgentSelfCheckPassed = outcome.ok
            externalAgentSelfCheckSummary = outcome.summary
            if outcome.ok {
                statusMessage = outcome.summary
                errorMessage = nil
            } else {
                statusMessage = nil
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
                ? "开发态 MCP v2 内核自检通过（\(tools) 工具 / \(prompts) 工作流），打包为 Charkle.app 后即内嵌独立 stdio 助手"
                : "内核自检未通过"
        } else {
            externalAgentSelfCheckPassed = false
            externalAgentSelfCheckSummary = "未找到原生 charkle MCP 助手程序"
        }
    }

    private nonisolated static func runHelperDoctorProcess(
        helperPath: String,
        timeoutSeconds: TimeInterval = 15
    ) async -> (ok: Bool, summary: String) {
        if Task.isCancelled {
            return (false, "自检已取消")
        }

        let fm = FileManager.default
        let scratchDir = fm.temporaryDirectory.appending(path: "charkle-selfcheck-\(UUID().uuidString)", directoryHint: .isDirectory)
        let stdoutURL = scratchDir.appending(path: "stdout.json")
        let stderrURL = scratchDir.appending(path: "stderr.log")
        do {
            try fm.createDirectory(at: scratchDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            fm.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            fm.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        } catch {
            return (false, "无法创建自检临时文件：\(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: scratchDir) }

        guard let stdoutHandle = try? FileHandle(forWritingTo: stdoutURL),
              let stderrHandle = try? FileHandle(forWritingTo: stderrURL) else {
            return (false, "无法打开自检输出文件")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: helperPath)
        proc.arguments = ["doctor", "--json"]
        proc.standardOutput = stdoutHandle
        proc.standardError = stderrHandle

        let gate = HelperDoctorProcessGate(process: proc)

        let terminationStatus: Int32? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.installAndRun(
                    continuation: continuation,
                    timeoutSeconds: timeoutSeconds
                )
            }
        } onCancel: {
            gate.terminateAndComplete(timedOut: false)
        }

        try? stdoutHandle.close()
        try? stderrHandle.close()

        let failure = gate.failureSnapshot()
        if failure.timedOut {
            return (false, "原生助手自检超时（超过 \(Int(timeoutSeconds)) 秒未响应）")
        }
        if let launchError = failure.launchError {
            return (false, "无法启动原生助手：\(launchError)")
        }
        guard let status = terminationStatus else {
            return (false, "原生助手自检已取消")
        }

        let outData = (try? Data(contentsOf: stdoutURL)) ?? Data()
        if status == 0,
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

        let errData = (try? Data(contentsOf: stderrURL)) ?? Data()
        let errStr = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (false, errStr.isEmpty ? "原生助手返回异常退出码 \(status)" : "自检失败：\(errStr)")
    }
}

private nonisolated final class HelperDoctorProcessGate: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var finished = false
    private var resultStatus: Int32?
    private var timedOut = false
    private var launchError: String?
    private var timeoutItem: DispatchWorkItem?
    private var continuation: CheckedContinuation<Int32?, Never>?

    init(process: Process) {
        self.process = process
    }

    func installAndRun(
        continuation: CheckedContinuation<Int32?, Never>,
        timeoutSeconds: TimeInterval
    ) {
        lock.lock()
        if finished {
            let status = resultStatus
            lock.unlock()
            continuation.resume(returning: status)
            return
        }
        self.continuation = continuation
        let item = DispatchWorkItem { [weak self] in
            self?.terminateAndComplete(timedOut: true)
        }
        self.timeoutItem = item
        lock.unlock()

        process.terminationHandler = { [weak self] finishedProcess in
            self?.complete(status: finishedProcess.terminationStatus)
        }

        do {
            try process.run()
            lock.lock()
            let alreadyFinished = finished
            lock.unlock()
            if alreadyFinished {
                if process.isRunning {
                    process.terminate()
                }
            } else {
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + timeoutSeconds,
                    execute: item
                )
            }
        } catch {
            complete(status: nil, launchError: error.localizedDescription)
        }
    }

    func terminateAndComplete(timedOut: Bool) {
        if process.isRunning {
            process.terminate()
        }
        complete(status: nil, timedOut: timedOut)
    }

    func complete(status: Int32?, timedOut: Bool = false, launchError: String? = nil) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        resultStatus = status
        if timedOut { self.timedOut = true }
        if let launchError { self.launchError = launchError }
        let cont = continuation
        continuation = nil
        let pendingTimeout = timeoutItem
        timeoutItem = nil
        lock.unlock()
        pendingTimeout?.cancel()
        cont?.resume(returning: status)
    }

    func failureSnapshot() -> (timedOut: Bool, launchError: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (timedOut, launchError)
    }
}
