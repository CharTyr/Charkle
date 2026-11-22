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
    public var cacheStats: CacheStats = CacheStats()

    public var lastSyncReport: SyncReport?
    public var statusMessage: String?
    public var errorMessage: String?
    public var isBusy: Bool = false

    public init(engine: any CharkleEngineProtocol) {
        self.engine = engine
    }

    public func loadAll() async {
        async let cfg = engine.syncConfig()
        async let status = engine.syncStatus()
        async let gd = engine.probeGDirectEnvironment()
        async let ai = engine.aiConfig()
        async let stats = engine.cacheStats()

        let (sCfg, sStatus, gdSnap, aiCfg, cStats) = await (cfg, status, gd, ai, stats)
        syncConfig = sCfg
        syncStatus = sStatus
        gdirectSnapshot = gdSnap
        aiConfig = aiCfg
        cacheStats = cStats
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

    public func saveSyncConfig(_ config: DriveSyncConfig) async {
        errorMessage = nil
        do {
            try await engine.saveSyncConfig(config)
            syncConfig = config
            syncStatus = await engine.syncStatus()
            statusMessage = "已保存 Google Drive 同步配置"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func importGoogleOAuthSecret(from url: URL) async {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            try await engine.importGoogleOAuthSecret(from: url)
            statusMessage = "已导入 OAuth 凭据文件：\(url.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func signInGoogleDrive() async {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            let account = try await engine.signInGoogleDrive()
            syncStatus = await engine.syncStatus()
            statusMessage = "已连接 Google Drive 账号：\(account.email)"
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

    public func saveAIConfig(_ config: AIProviderConfig, apiKey: String?) async {
        errorMessage = nil
        do {
            try await engine.saveAIConfig(config, apiKey: apiKey)
            aiConfig = config
            hasStoredAIKey = await engine.hasStoredAIKey(for: config.provider)
            statusMessage = "已保存 AI 配置（密钥仅存于 macOS 钥匙串）"
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
            statusMessage = "已清理可淘汰原文件缓存（钉选离线内容已保留）"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
