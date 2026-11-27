import AppKit
import CharkleCore
import SwiftUI

/// Tab 9: 高级与关于 (Advanced & About) — Houses lower-level `gdirect` routing, mount mode,
/// OAuth credential management, local visual index rebuild, data directory access, and app info.
public struct AdvancedAboutSettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.charkleAccentSource) private var accentSource
    @Environment(\.charkleAppUpdater) private var environmentAppUpdater

    public let library: LibraryStore
    public let syncAndAI: SyncAndAIStore
    public let appUpdater: AppUpdateStore?
    public let coordinator: AppCoordinatorStore?

    @State private var draftSyncConfig: DriveSyncConfig = DriveSyncConfig()
    @State private var didLoadDraft: Bool = false
    @State private var showOAuthSetupSheet: Bool = false
    @State private var showGDirectMountSheet: Bool = false

    public init(
        library: LibraryStore,
        syncAndAI: SyncAndAIStore,
        appUpdater: AppUpdateStore? = nil,
        coordinator: AppCoordinatorStore? = nil
    ) {
        self.library = library
        self.syncAndAI = syncAndAI
        self.appUpdater = appUpdater
        self.coordinator = coordinator
    }

    private var resolvedUpdater: AppUpdateStore {
        appUpdater ?? environmentAppUpdater ?? CharkleRuntime.shared.appUpdater
    }

    public var body: some View {
        let snap = syncAndAI.gdirectSnapshot
        let healthyNodeCount = snap.endpoints.filter(\.healthy).count
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.5.1"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "13"

        VStack(alignment: .leading, spacing: 18) {
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
                        ? "未检测到本机 gdirect，安装后可在直连受阻时自动回退"
                        : (draftSyncConfig.useGDirectIPAcceleration
                            ? (healthyNodeCount > 0
                                ? "已开启，检测到 \(healthyNodeCount) 个健康节点，直连受阻时自动启用"
                                : "已开启，无法直连 googleapis.com 时自动使用本机 gdirect")
                            : "已关闭，仅使用标准 Google Drive HTTPS 直连")
                ) {
                    Toggle("", isOn: $draftSyncConfig.useGDirectIPAcceleration)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(snap.cliPath == nil)
                        .onChange(of: draftSyncConfig.useGDirectIPAcceleration) { _, newVal in
                            persistSyncIfReady(message: newVal ? "已开启网络受限时 gdirect 兜底" : "已关闭 gdirect 网络兜底")
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
                            ? "已启用，挂载目录：\(draftSyncConfig.mountPath)"
                            : "当前已选择挂载模式，但尚未挂载卷")
                        : "默认推荐直连 API；适合需在访达 ~/GoogleDrive 挂载访问的用户",
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
                            .padding(.horizontal, 14)
                            .padding(.bottom, 11)
                    }
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "打开应用数据目录",
                    subtitle: "~/Library/Application Support/Charkle（数据库、缓存与 Agent 配置）"
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

            softwareUpdateSection(appVersion: appVersion, buildNumber: buildNumber)

            SettingsSection("关于 Charkle") {
                HStack(spacing: 14) {
                    if let icon = CharkleAppIconManager.shared.previewImage(for: CharkleAppIconManager.shared.currentVariant) {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverInner, style: .continuous))
                    } else {
                        CharkleBrandMark(size: 36)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("Charkle")
                                .font(CharkleTheme.text(.body, weight: .semibold))
                            Text("v\(appVersion) (\(buildNumber))")
                                .font(CharkleTheme.text(.caption, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Text("本地优先的视觉素材库与情绪板工作台，内置离线检索与可读云端同步")
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
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
        return "离线重新提取全库配色、OCR 与视觉相似特征（共 \(library.allAssetsByID.count) 项）"
    }

    // MARK: - Software Updates Section

    @ViewBuilder
    private func softwareUpdateSection(appVersion: String, buildNumber: String) -> some View {
        let updater = resolvedUpdater

        SettingsSection("软件更新") {
            SettingsRow(
                title: "当前版本 v\(appVersion) (\(buildNumber))",
                subtitle: updateStatusSubtitle(for: updater),
                subtitleColor: updateStatusColor(for: updater)
            ) {
                Button {
                    updater.checkForUpdatesManually(presentSheet: false)
                } label: {
                    HStack(spacing: 5) {
                        if updater.isChecking {
                            ProgressView().controlSize(.mini)
                        }
                        Text(updater.isChecking ? "检查中…" : "检查更新")
                    }
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .fixedSize()
                .disabled(updater.isBusy)
            }

            if updater.hasPendingUpdateBanner {
                SettingsCardDivider()
                inlineUpdateBannerRow(for: updater)
            }

            SettingsCardDivider()

            SettingsRow(
                title: "启动时自动检查更新",
                subtitle: "每 6 小时检查一次 GitHub Releases，有新版本时提示"
            ) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { updater.autoCheckUpdates },
                        set: { newVal in
                            guard updater.autoCheckUpdates != newVal else { return }
                            updater.autoCheckUpdates = newVal
                            coordinator?.showToast(
                                newVal ? "已开启启动时自动检查更新" : "已关闭启动时自动检查更新",
                                icon: "arrow.triangle.2.circlepath",
                                tone: .success
                            )
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if let skipped = updater.skippedVersion {
                SettingsCardDivider()
                SettingsRow(
                    title: "已跳过版本 v\(skipped)",
                    subtitle: "自动检查将忽略此版本，手动点击「检查更新」仍可查看"
                ) {
                    Button("恢复提醒") {
                        updater.clearSkippedVersion()
                        coordinator?.showToast(
                            "已恢复 v\(skipped) 更新提醒",
                            icon: "bell.badge",
                            tone: .success
                        )
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .fixedSize()
                }
            }
        }
    }

    private func updateStatusSubtitle(for updater: AppUpdateStore) -> String {
        switch updater.state {
        case .checking:
            return "正在连接 GitHub Releases 检查最新版本…"
        case .upToDate(let checkedAt):
            return "已是最新版本，上次检查：\(SettingsHelpers.relativeTimeText(checkedAt))"
        case .available(let update):
            return "发现新版本 \(update.tagName) 可供下载"
        case .downloading(let update, let progress, _, _):
            let pct = Int((min(1.0, max(0.0, progress)) * 100).rounded())
            return "正在下载 \(update.tagName)（\(pct)%）…"
        case .verifying(let update):
            return "正在校验 \(update.tagName) 的 SHA-256 摘要与代码签名…"
        case .readyToInstall(let update, _, _):
            return "\(update.tagName) 已校验通过并准备就绪"
        case .installing(let update):
            return "正在安装 \(update.tagName) 并重启…"
        case .manualInstallRequired(let update, _):
            return "\(update.tagName) 安装包已校验通过，请手动打开完成安装"
        case .failed(let message):
            return message
        case .idle:
            if let last = updater.lastUpdateCheckAt {
                return "上次检查：\(SettingsHelpers.relativeTimeText(last))"
            }
            return "通过 GitHub Releases 自动获取已签名的 macOS 更新包"
        }
    }

    private func updateStatusColor(for updater: AppUpdateStore) -> Color? {
        switch updater.state {
        case .available:
            return CharkleTheme.accent(for: colorScheme, source: accentSource)
        case .readyToInstall, .upToDate:
            return SettingsPalette.positiveInk(for: colorScheme)
        case .manualInstallRequired:
            return SettingsPalette.warningInk(for: colorScheme)
        case .failed:
            return SettingsPalette.destructiveInk(for: colorScheme)
        default:
            return nil
        }
    }

    @ViewBuilder
    private func inlineUpdateBannerRow(for updater: AppUpdateStore) -> some View {
        let activeAccent = CharkleTheme.accent(for: colorScheme, source: accentSource)

        switch updater.state {
        case .available(let update):
            SettingsRow(
                title: "新版本 \(update.tagName) 已发布",
                subtitle: update.assetName
            ) {
                HStack(spacing: 8) {
                    Button("更新说明") {
                        updater.isUpdateSheetPresented = true
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .fixedSize()

                    Button("立即下载并更新") {
                        updater.downloadAndPrepareUpdate()
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .fixedSize()
                }
            }

        case .downloading(let update, let progress, let downloadedBytes, let totalBytes):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("正在下载 \(update.tagName)")
                            .font(CharkleTheme.text(.body, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(inlineDownloadBytesText(downloaded: downloadedBytes, total: totalBytes, progress: progress))
                            .font(CharkleTheme.text(.caption))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 10)
                    Button("查看详情") {
                        updater.isUpdateSheetPresented = true
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .fixedSize()

                    Button("取消") {
                        updater.cancelDownload()
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .fixedSize()
                }

                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(activeAccent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

        case .verifying(let update):
            SettingsRow(
                title: "正在校验 \(update.tagName) 安装包",
                subtitle: "核对 SHA-256 校验和与严格代码签名"
            ) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Button("查看详情") {
                        updater.isUpdateSheetPresented = true
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .fixedSize()
                }
            }

        case .readyToInstall(let update, _, _):
            SettingsRow(
                title: "\(update.tagName) 已验证就绪",
                subtitle: "已完成 SHA-256 与严格代码签名校验，重启后自动替换应用包",
                subtitleColor: SettingsPalette.positiveInk(for: colorScheme)
            ) {
                HStack(spacing: 8) {
                    Button("查看详情") {
                        updater.isUpdateSheetPresented = true
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .fixedSize()

                    Button("重启并安装") {
                        updater.installAndRelaunch {
                            CharkleRuntime.shared.markTerminating()
                        }
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .fixedSize()
                }
            }

        case .installing(let update):
            SettingsRow(
                title: "正在安装 \(update.tagName)…",
                subtitle: "正在保存数据并准备重启"
            ) {
                ProgressView().controlSize(.small)
            }

        case .manualInstallRequired(let update, let dmgURL):
            SettingsRow(
                title: "\(update.tagName) 需手动安装",
                subtitle: updater.manualInstallReason ?? dmgURL.lastPathComponent,
                subtitleColor: SettingsPalette.warningInk(for: colorScheme)
            ) {
                HStack(spacing: 8) {
                    Button("在访达中显示") {
                        updater.revealDownloadedDMG()
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .fixedSize()

                    Button("打开安装包") {
                        updater.openDownloadedDMG()
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .fixedSize()
                }
            }

        default:
            EmptyView()
        }
    }

    private static let downloadByteFormatter: ByteCountFormatter = {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useMB, .useKB]
        fmt.countStyle = .file
        fmt.includesUnit = true
        return fmt
    }()

    private func inlineDownloadBytesText(downloaded: Int64, total: Int64, progress: Double) -> String {
        let fmt = Self.downloadByteFormatter
        let pct = Int((min(1.0, max(0.0, progress)) * 100).rounded())
        let down = fmt.string(fromByteCount: max(0, downloaded))
        if total > 0 {
            return "\(down) / \(fmt.string(fromByteCount: total))（\(pct)%）"
        }
        return "\(down)（\(pct)%）"
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
                        .font(CharkleTheme.text(.headline, weight: .semibold))
                    Text("通过 gdirect 将 Google Drive 挂载为本地目录，可与直连 OAuth 共存。")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Google Drive 接入模式")
                        .font(CharkleTheme.text(.body, weight: .medium))
                    Text("休眠唤醒若遇 NFS 断连提示，可随时切回「正常直连（推荐）」")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: Binding<DriveTransportMode>(
                    get: { draftSyncConfig.mode == .gdirectMount ? .gdirectMount : .directAPIWithGDirect },
                    set: { newMode in
                        draftSyncConfig.mode = newMode
                        persistSyncIfReady(message: newMode == .gdirectMount ? "已切换为 gdirect 挂载模式" : "已切换为 Google Drive 正常直连")
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
            .background(
                SettingsPalette.subtleFill(for: colorScheme),
                in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous)
                    .strokeBorder(SettingsPalette.border(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
            )

            if snap.accounts.count > 1 {
                HStack {
                    Text("本机 gdirect 账号")
                        .font(CharkleTheme.text(.caption, weight: .medium))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { gdirectEmail ?? snap.accounts.first ?? "" },
                        set: { newEmail in
                            draftSyncConfig.selectedGDirectAccount = newEmail
                            persistSyncIfReady(message: "已切换本机 gdirect 账号为 \(newEmail)")
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
                    .font(CharkleTheme.text(.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(NSHomeDirectory() + "/GoogleDrive", text: $draftSyncConfig.mountPath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { persistSyncIfReady(message: "已更新本地挂载目录") }
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
                        .font(CharkleTheme.text(.caption))
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

    private func persistSyncIfReady(message: String? = nil) {
        guard didLoadDraft else { return }
        let snapshot = draftSyncConfig
        guard snapshot != syncAndAI.syncConfig else { return }
        Task {
            await syncAndAI.saveSyncConfig(
                snapshot,
                quiet: message == nil,
                successMessage: message
            )
        }
    }
}
