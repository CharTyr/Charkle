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
    public var hasStoredAIKey: Bool = false
    public var hasGoogleOAuthClient: Bool = false
    public var hasWebDAVPassword: Bool = false
    public var cacheStats: CacheStats = CacheStats()

    public var lastSyncReport: SyncReport?
    public var lastMigrationReport: StorageMigrationReport?
    public var statusMessage: String?
    public var errorMessage: String?
    public var isBusy: Bool = false
    public var isMigrating: Bool = false

    public init(engine: any CharkleEngineProtocol) {
        self.engine = engine
    }

    public func loadAll() async {
        async let cfg = engine.syncConfig()
        async let status = engine.syncStatus()
        async let gd = engine.probeGDirectEnvironment()
        async let ai = engine.aiConfig()
        async let stats = engine.cacheStats()
        async let oauthConfigured = engine.hasGoogleOAuthClientConfig()
        async let webdavPwd = engine.hasWebDAVPassword()

        let (sCfg, sStatus, gdSnap, aiCfg, cStats, hasOAuth, hasWebDAV) = await (
            cfg, status, gd, ai, stats, oauthConfigured, webdavPwd
        )
        syncConfig = sCfg
        syncStatus = sStatus
        gdirectSnapshot = gdSnap
        aiConfig = aiCfg
        cacheStats = cStats
        hasGoogleOAuthClient = hasOAuth
        hasWebDAVPassword = hasWebDAV
        hasStoredAIKey = await engine.hasStoredAIKey(for: aiCfg.provider)
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
}
