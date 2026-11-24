import AppKit
import CharkleCore
import SwiftUI

/// Tab 9: 高级与关于 (Advanced & About) — Houses lower-level `gdirect` routing, mount mode,
/// OAuth credential management, local visual index rebuild, data directory access, and app info.
public struct AdvancedAboutSettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme

    public let library: LibraryStore
    public let syncAndAI: SyncAndAIStore

    @State private var draftSyncConfig: DriveSyncConfig = DriveSyncConfig()
    @State private var didLoadDraft: Bool = false
    @State private var showOAuthSetupSheet: Bool = false
    @State private var showGDirectMountSheet: Bool = false

    public init(library: LibraryStore, syncAndAI: SyncAndAIStore) {
        self.library = library
        self.syncAndAI = syncAndAI
    }

    public var body: some View {
        let snap = syncAndAI.gdirectSnapshot
        let healthyNodeCount = snap.endpoints.filter(\.healthy).count
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "5"

        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Google Drive 高级通道（gdirect）") {
                SettingsRow(
                    title: "Google 登录凭据（OAuth Client）",
                    subtitle: syncAndAI.hasGoogleOAuthClient
                        ? "已配置桌面端凭据，可直接用于 Google Drive 直连登录"
                        : "尚未配置，可从本机 gdirect 导入或粘贴桌面端凭据",
                    subtitleColor: syncAndAI.hasGoogleOAuthClient
                        ? SettingsPalette.positiveInk(for: colorScheme)
                        : .secondary
                ) {
                    HStack(spacing: 8) {
                        if snap.cliPath != nil && !syncAndAI.hasGoogleOAuthClient {
                            Button("从 gdirect 导入") {
                                Task { _ = await syncAndAI.importGoogleOAuthFromGDirect() }
                            }
                            .buttonStyle(SettingsSecondaryButtonStyle())
                            .fixedSize()
                        }

                        Button(syncAndAI.hasGoogleOAuthClient ? "管理凭据…" : "配置凭据…") {
                            showOAuthSetupSheet = true
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .fixedSize()
                    }
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "网络受限时使用本机 gdirect 兜底",
                    subtitle: snap.cliPath == nil
                        ? "未检测到本机 gdirect CLI；安装后可在网络受限时自动回退优选节点"
                        : (draftSyncConfig.useGDirectIPAcceleration
                            ? (healthyNodeCount > 0
                                ? "已开启 · 检测到 \(healthyNodeCount) 个健康节点（仅当标准 HTTPS 直连受阻时自动启用）"
                                : "已开启 · 当无法直连 googleapis.com 时自动尝试本机 gdirect")
                            : "已关闭 · 仅使用标准 Google Drive HTTPS 直连")
                ) {
                    Toggle("", isOn: $draftSyncConfig.useGDirectIPAcceleration)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(snap.cliPath == nil)
                        .onChange(of: draftSyncConfig.useGDirectIPAcceleration) { _, _ in
                            persistSyncIfReady()
                        }
                }

                if snap.cliPath != nil {
                    SettingsCardDivider()

                    SettingsRow(
                        title: "gdirect 优选节点与环境诊断",
                        subtitle: healthyNodeCount > 0
                            ? "当前有 \(healthyNodeCount) 个可用直连节点"
                            : "可手动测速扫描优选节点，或刷新本机 gdirect 状态"
                    ) {
                        HStack(spacing: 8) {
                            Button("重新测速") {
                                Task { await syncAndAI.runGDirectScan() }
                            }
                            .buttonStyle(SettingsSecondaryButtonStyle())
                            .fixedSize()
                            .disabled(syncAndAI.isBusy)

                            Button("刷新状态") {
                                Task { await syncAndAI.probeGDirect() }
                            }
                            .buttonStyle(SettingsSecondaryButtonStyle())
                            .fixedSize()
                            .disabled(syncAndAI.isBusy)
                        }
                    }
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "gdirect 本地挂载模式",
                    subtitle: draftSyncConfig.mode == .gdirectMount
                        ? (snap.isMountActive
                            ? "当前已启用 · 挂载目录：\(draftSyncConfig.mountPath)"
                            : "当前已选择挂载模式，但尚未挂载卷")
                        : "默认推荐使用免挂载直连 API；仅限习惯在访达 ~/GoogleDrive 挂载访问的用户",
                    subtitleColor: draftSyncConfig.mode == .gdirectMount && snap.isMountActive
                        ? SettingsPalette.positiveInk(for: colorScheme)
                        : .secondary
                ) {
                    Button("挂载与切换…") {
                        showGDirectMountSheet = true
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .fixedSize()
                }
            }

            SettingsSection("索引与数据维护") {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsRow(
                        title: "重建本机视觉与文字索引",
                        subtitle: rebuildSubtitle
                    ) {
                        Button {
                            let ids = Array(library.allAssetsByID.keys)
                            Task {
                                _ = await syncAndAI.rebuildLocalVisualIndex(assetIDs: ids)
                                await library.refreshAll()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                if syncAndAI.isRebuildingVisualIndex {
                                    ProgressView().controlSize(.mini)
                                }
                                Text(syncAndAI.isRebuildingVisualIndex ? "扫描中…" : "开始扫描")
                            }
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .fixedSize()
                        .disabled(syncAndAI.isRebuildingVisualIndex || library.allAssetsByID.isEmpty)
                    }

                    if let progress = syncAndAI.rebuildVisualIndexProgress, progress.total > 0 {
                        ProgressView(value: Double(progress.completed) / Double(progress.total))
                            .progressViewStyle(.linear)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "打开应用数据目录",
                    subtitle: "~/Library/Application Support/Charkle（包含本地数据库、缓存与外部 Agent 配置）"
                ) {
                    Button("在访达中打开") {
                        let dir = ExternalAgentConfigStore.defaultDirectory()
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .fixedSize()
                }
            }

            SettingsSection("关于 Charkle") {
                HStack(spacing: 14) {
                    if let icon = CharkleAppIconManager.shared.previewImage(for: CharkleAppIconManager.shared.currentVariant) {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        CharkleBrandMark(size: 36)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("Charkle")
                                .font(.system(size: 14, weight: .semibold))
                            Text("v\(appVersion) (\(buildNumber))")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text("面向设计师的视觉素材库与 10 秒情绪板创作台 · Apple Vision 离线引擎 + 可读云端存储")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .onAppear {
            draftSyncConfig = syncAndAI.syncConfig
            didLoadDraft = true
        }
        .onChange(of: syncAndAI.syncConfig) { _, latest in
            draftSyncConfig = latest
        }
        .sheet(isPresented: $showOAuthSetupSheet) {
            GoogleOAuthSetupSheet(syncAndAI: syncAndAI, autoSignInAfterSave: false)
        }
        .sheet(isPresented: $showGDirectMountSheet) {
            gdirectMountSheet
        }
    }

    private var rebuildSubtitle: String {
        if let progress = syncAndAI.rebuildVisualIndexProgress {
            return "正在离线重建配色、OCR 与视觉相似特征（\(progress.completed) / \(progress.total)）…"
        }
        return "升级 macOS 或发现部分素材缺少配色、文字识别或相似推荐时，可离线重新扫描全库（共 \(library.allAssetsByID.count) 项）"
    }

    // MARK: - gdirect Mount Management Sheet

    private var gdirectMountSheet: some View {
        let snap = syncAndAI.gdirectSnapshot
        let gdirectEmail = draftSyncConfig.selectedGDirectAccount ?? snap.defaultAccount ?? snap.accounts.first
        let isMountMode = draftSyncConfig.mode == .gdirectMount

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.checkmark")
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    Text("gdirect 本地挂载管理")
                        .font(.system(size: 15, weight: .semibold))
                    Text("通过本机 gdirect 将 Google Drive 挂载为本地目录，与正常直连 OAuth 账号可共存。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Google Drive 接入模式")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("休眠唤醒若遇 NFS 断连提示，可随时切回「正常直连（推荐）」")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: Binding<DriveTransportMode>(
                    get: { draftSyncConfig.mode == .gdirectMount ? .gdirectMount : .directAPIWithGDirect },
                    set: { newMode in
                        draftSyncConfig.mode = newMode
                        persistSyncIfReady()
                    }
                )) {
                    Text("正常直连（推荐）").tag(DriveTransportMode.directAPIWithGDirect)
                    Text("gdirect 挂载").tag(DriveTransportMode.gdirectMount)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 224)
            }
            .padding(12)
            .background(SettingsPalette.subtleFill(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if snap.accounts.count > 1 {
                HStack {
                    Text("本机 gdirect 账号")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { gdirectEmail ?? snap.accounts.first ?? "" },
                        set: { newEmail in
                            draftSyncConfig.selectedGDirectAccount = newEmail
                            persistSyncIfReady()
                        }
                    )) {
                        ForEach(snap.accounts, id: \.self) { email in
                            Text(email).tag(email)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 230)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("本地挂载目录")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(NSHomeDirectory() + "/GoogleDrive", text: $draftSyncConfig.mountPath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { persistSyncIfReady() }
            }

            HStack(spacing: 8) {
                if snap.isMountActive {
                    Button("卸载挂载卷") {
                        Task { await syncAndAI.runGDirectUnmount() }
                    }
                    .buttonStyle(SettingsDestructiveButtonStyle())
                    .disabled(syncAndAI.isBusy)
                } else if snap.cliPath != nil, gdirectEmail != nil {
                    Button("立即挂载") {
                        persistSyncIfReady()
                        Task { await syncAndAI.runGDirectMount(path: draftSyncConfig.mountPath) }
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .disabled(syncAndAI.isBusy)
                } else {
                    Text(snap.cliPath == nil ? "未检测到本机 gdirect CLI" : "未登录本机 gdirect 账号")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isMountMode && snap.isMountActive {
                    Button("立即同步") {
                        Task { _ = await syncAndAI.syncNow() }
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .disabled(syncAndAI.isBusy)
                }

                Button("完成") {
                    persistSyncIfReady()
                    showGDirectMountSheet = false
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 500)
    }

    private func persistSyncIfReady() {
        guard didLoadDraft else { return }
        let snapshot = draftSyncConfig
        Task { await syncAndAI.saveSyncConfig(snapshot, quiet: true) }
    }
}
