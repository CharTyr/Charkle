import CharkleCore
import SwiftUI
import UniformTypeIdentifiers

/// Multi-backend cloud sync hub supporting simultaneous Google Drive, iCloud Drive, WebDAV, and local folders,
/// plus OAuth login, iCloud Drive Files folder bookmark picker, shared folder collaboration, and cache budget.
struct GoogleDriveSyncSettingsView: View {
    @Bindable var store: MobileAppStore
    let showDoneButton: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var autoSyncInterval: Int = 120
    @State private var syncThumbnails: Bool = true
    @State private var syncEmbeddings: Bool = true
    @State private var clientIDInput: String = ""
    @State private var showOAuthConfigEditor: Bool = false
    @State private var isCredentialImporterPresented: Bool = false
    @State private var isSharedFolderPickerPresented: Bool = false
    @State private var cacheBudgetGB: Double = 4.0

    @State private var editingBackend: SyncBackendProfile? = nil
    @State private var isAddingNewBackend: Bool = false

    private var hasGoogleBackend: Bool {
        store.syncConfig.resolvedBackends.contains { $0.mode == .directAPIWithGDirect || $0.mode == .gdirectMount }
    }

    var body: some View {
        Form {
            // 1. Live Multi-Backend Connection & Progress Hero
            Section {
                connectionStatusCard
            }

            // 2. Simultaneous Connected Backends List (Google Drive + iCloud Drive + WebDAV + Local)
            Section {
                let profiles = store.syncConfig.resolvedBackends
                let statusByID = Dictionary(uniqueKeysWithValues: store.syncStatus.backendStatuses.map { ($0.backendID, $0) })

                ForEach(profiles) { profile in
                    backendRow(profile: profile, status: statusByID[profile.id], totalCount: profiles.count)
                }

                Menu {
                    Button {
                        openNewBackend(mode: .iCloudDrive)
                    } label: {
                        Label("添加 iCloud Drive", systemImage: "icloud")
                    }
                    Button {
                        openNewBackend(mode: .directAPIWithGDirect)
                    } label: {
                        Label("添加 Google Drive", systemImage: "externaldrive.badge.icloud")
                    }
                    Button {
                        openNewBackend(mode: .webDAV)
                    } label: {
                        Label("添加 WebDAV 云盘", systemImage: "server.rack")
                    }
                    Button {
                        openNewBackend(mode: .localOnly)
                    } label: {
                        Label("添加本地文件夹", systemImage: "folder")
                    }
                } label: {
                    Label("添加同步后端…", systemImage: "plus.circle.fill")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(MobileTheme.accent(for: colorScheme))
                }
            } header: {
                Text("已连接的同步后端（支持同时连接多个）")
            } footer: {
                Text("可同时启用 iCloud Drive、Google Drive、WebDAV 等多个后端；同步时会自动双向合并元数据、原图、缩略图与情绪板。")
            }

            // 3. Google Drive OAuth & Shared Collaboration (visible whenever a Google backend exists)
            if hasGoogleBackend {
                Section("Google 账号与授权凭据") {
                    if !store.hasGoogleOAuthClient || showOAuthConfigEditor {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("在 Google Cloud Console 创建 iOS 类型 OAuth Client ID，导入 `.plist` / `.json` 文件或直接粘贴 Client ID。")
                                .font(.system(size: 12.5))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))

                            TextField("例如：123456-xxxx.apps.googleusercontent.com", text: $clientIDInput)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(size: 13, design: .monospaced))

                            if let derivedScheme = GoogleOAuthClientConfig(clientID: clientIDInput).reversedClientIDScheme {
                                Text("自动回调 Scheme：\(derivedScheme)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                    .lineLimit(1)
                            }

                            HStack(spacing: 10) {
                                Button("保存 Client ID") {
                                    Task {
                                        await store.saveGoogleOAuthClientID(clientIDInput)
                                        if store.hasGoogleOAuthClient {
                                            showOAuthConfigEditor = false
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(clientIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                Button("导入 .plist / .json") {
                                    isCredentialImporterPresented = true
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        HStack {
                            Label("已就绪 iOS OAuth 凭据", systemImage: "checkmark.seal.fill")
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(MobileTheme.positive(for: colorScheme))
                            Spacer()
                            Button("更换") {
                                showOAuthConfigEditor = true
                            }
                            .font(.system(size: 13))
                        }
                    }

                    if !store.isGoogleDriveSignedIn {
                        Button {
                            Task { await store.signInGoogleDrive() }
                        } label: {
                            HStack {
                                if store.isSigningInGoogle {
                                    ProgressView()
                                } else {
                                    Image(systemName: "person.badge.key.fill")
                                }
                                Text(store.isSigningInGoogle ? "正在拉起 Google 授权…" : "使用 Google 账号登录")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.hasGoogleOAuthClient || store.isSigningInGoogle)
                    } else {
                        HStack {
                            Label("已登录 Google 账号", systemImage: "person.crop.circle.badge.checkmark")
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(MobileTheme.positive(for: colorScheme))
                            Spacer()
                            Button("共享目录") {
                                isSharedFolderPickerPresented = true
                                Task { await store.loadSharedDriveFolders() }
                            }
                            .font(.system(size: 13))
                        }

                        Button(role: .destructive) {
                            Task { await store.signOutGoogleDrive() }
                        } label: {
                            Label("退出当前 Google 账号", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
            }

            // 4. Global Sync Preferences
            Section("同步偏好") {
                Picker("前台自动同步", selection: $autoSyncInterval) {
                    Text("关闭").tag(0)
                    Text("每 1 分钟").tag(60)
                    Text("每 2 分钟").tag(120)
                    Text("每 5 分钟").tag(300)
                }
                .onChange(of: autoSyncInterval) { _, _ in savePreferences() }

                Toggle("同步缩略图（新设备秒开画廊）", isOn: $syncThumbnails)
                    .onChange(of: syncThumbnails) { _, _ in savePreferences() }

                Toggle("同步视觉相似特征向量", isOn: $syncEmbeddings)
                    .onChange(of: syncEmbeddings) { _, _ in savePreferences() }
            }

            // 5. Local Cache Budget
            Section {
                cacheRow("缩略图缓存", MobileFormatters.byteCount(store.cacheStats.thumbnailBytes))
                cacheRow("已缓存原图（\(store.cacheStats.cachedOriginalCount) 项）", MobileFormatters.byteCount(store.cacheStats.originalCacheBytes))
                cacheRow("离线置顶原图（\(store.cacheStats.pinnedAssetCount) 项）", MobileFormatters.byteCount(store.cacheStats.pinnedOfflineBytes))

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("原图缓存上限")
                        Spacer()
                        Text("\(String(format: "%.1f", cacheBudgetGB)) GB")
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $cacheBudgetGB, in: 1...16, step: 0.5) { editing in
                        if !editing {
                            Task { await store.updateCacheBudget(gigabytes: cacheBudgetGB) }
                        }
                    }
                }

                Button("清理可回收缓存") {
                    Task { await store.evictCacheNow() }
                }
            } header: {
                Text("移动端本地缓存")
            } footer: {
                Text("缩略图常驻本机实现瞬开翻找，高清原图按需拉取并自动按上限回收；已置顶离线原图永不自动清理。")
            }

            // 6. System Share Extension & Demo
            Section("快捷采集提示") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("支持系统「分享面板」随手收藏", systemImage: "square.and.arrow.up.on.square")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text("在小红书、X、Safari 或系统相册中点击「分享 → 存到 Charkle」，打开应用后自动完成解析入库并同步到已连接的全部云端后端。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                }
                .padding(.vertical, 4)

                if store.assets.isEmpty {
                    Button("载入精选示例素材库") {
                        Task { await store.seedSampleLibrary() }
                    }
                }
            }
        }
        .navigationTitle("多后端云同步")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear { populateFromStore() }
        .onChange(of: store.syncConfig) { _, _ in populateFromStore() }
        .fileImporter(
            isPresented: $isCredentialImporterPresented,
            allowedContentTypes: [.json, .propertyList, .xml],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task {
                    await store.importGoogleOAuthCredentialFile(from: url)
                    if store.hasGoogleOAuthClient {
                        showOAuthConfigEditor = false
                    }
                }
            }
        }
        .sheet(item: $editingBackend) { profile in
            NavigationStack {
                MobileBackendEditorSheet(
                    store: store,
                    initial: profile,
                    isNew: isAddingNewBackend,
                    onDone: { editingBackend = nil }
                )
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isSharedFolderPickerPresented) {
            NavigationStack {
                List {
                    if store.isLoadingSharedFolders {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在加载共享目录…")
                        }
                    } else if store.sharedFolders.isEmpty {
                        Text("未在 Google Drive 中找到「与我共享」的文件夹。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.sharedFolders, id: \.id) { folder in
                            Button {
                                Task {
                                    await store.assignGoogleSharedFolder(folder.id)
                                    isSharedFolderPickerPresented = false
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "folder.badge.person.crop")
                                        .foregroundStyle(MobileTheme.accent(for: colorScheme))
                                    Text(folder.name)
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("选择共享目录")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { isSharedFolderPickerPresented = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Backend Row

    private func backendRow(profile: SyncBackendProfile, status: SyncBackendStatus?, totalCount: Int) -> some View {
        let dotColor: Color = {
            if !profile.isEnabled { return MobileTheme.tertiaryInk(for: colorScheme) }
            if let status {
                if case .error = status.phase { return MobileTheme.destructive(for: colorScheme) }
                if status.isSyncing { return MobileTheme.accent(for: colorScheme) }
                if status.lastSyncedAt != nil { return MobileTheme.positive(for: colorScheme) }
            }
            return MobileTheme.warning(for: colorScheme)
        }()

        let subtitle: String = {
            if !profile.isEnabled { return "已暂停 · \(profile.locationSummary)" }
            if let err = status?.lastError, !err.isEmpty { return "异常：\(err)" }
            if let syncedAt = status?.lastSyncedAt {
                return "\(profile.locationSummary) · \(MobileFormatters.relativeDate(syncedAt))"
            }
            return profile.locationSummary
        }()

        return HStack(spacing: 10) {
            Image(systemName: iconForMode(profile.mode))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(profile.isEnabled ? MobileTheme.accent(for: colorScheme) : MobileTheme.tertiaryInk(for: colorScheme))
                .frame(width: 28)

            Button {
                isAddingNewBackend = false
                editingBackend = profile
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle().fill(dotColor).frame(width: 7, height: 7)
                        Text(profile.name)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if profile.isPrimary {
                            Text("主后端")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(MobileTheme.accent(for: colorScheme))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(MobileTheme.accentSoft(for: colorScheme), in: Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(status?.lastError != nil ? MobileTheme.destructive(for: colorScheme) : MobileTheme.secondaryInk(for: colorScheme))
                        .lineLimit(2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            Toggle("", isOn: Binding(
                get: { profile.isEnabled },
                set: { enabled in
                    Task { await store.setBackendEnabled(id: profile.id, enabled: enabled) }
                }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("编辑配置", systemImage: "slider.horizontal.3") {
                isAddingNewBackend = false
                editingBackend = profile
            }
            if profile.isEnabled {
                Button("仅同步此后端", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await store.syncBackend(id: profile.id) }
                }
            }
            if !profile.isPrimary {
                Button("设为主后端", systemImage: "star") {
                    Task { await store.setPrimaryBackend(id: profile.id) }
                }
            }
            if totalCount > 1 {
                Divider()
                Button("移除此后端", systemImage: "trash", role: .destructive) {
                    Task { await store.removeBackend(id: profile.id) }
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if totalCount > 1 {
                Button("移除", role: .destructive) {
                    Task { await store.removeBackend(id: profile.id) }
                }
            }
            Button("同步") {
                Task { await store.syncBackend(id: profile.id) }
            }
            .tint(MobileTheme.accent(for: colorScheme))
        }
    }

    private func iconForMode(_ mode: DriveTransportMode) -> String {
        switch mode {
        case .iCloudDrive: "icloud.fill"
        case .directAPIWithGDirect: "externaldrive.badge.icloud"
        case .gdirectMount: "externaldrive.connected.to.line.below"
        case .webDAV: "server.rack"
        case .localOnly: "folder.fill"
        }
    }

    // MARK: - Hero Status Card

    private var connectionStatusCard: some View {
        let enabledCount = store.syncConfig.enabledBackends.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(heroTitle(enabledCount: enabledCount))
                        .font(.system(size: 15, weight: .semibold))
                    Text(statusSubtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                }
                Spacer()
            }

            if store.syncStatus.isSyncing {
                VStack(alignment: .leading, spacing: 6) {
                    if let fraction = store.syncStatus.progressFraction {
                        ProgressView(value: max(0, min(1, fraction)))
                            .tint(MobileTheme.accent(for: colorScheme))
                    } else {
                        ProgressView()
                            .tint(MobileTheme.accent(for: colorScheme))
                    }
                    Text(store.syncStatus.currentDetail ?? store.syncStatus.localizedPhaseTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        .lineLimit(2)
                }
            } else if let error = store.syncStatus.lastError, !error.isEmpty {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(MobileTheme.destructive(for: colorScheme))
            }

            if enabledCount > 0 {
                Button {
                    Task { await store.syncNow(quiet: false) }
                } label: {
                    HStack {
                        if store.isSyncing || store.syncStatus.isSyncing {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(
                            (store.isSyncing || store.syncStatus.isSyncing)
                                ? "正在同步…"
                                : (enabledCount > 1 ? "立即同步全部 \(enabledCount) 个后端" : "立即双向同步")
                        )
                        .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isSyncing || store.syncStatus.isSyncing)
            }
        }
        .padding(.vertical, 4)
    }

    private func heroTitle(enabledCount: Int) -> String {
        if enabledCount > 1 {
            return "已启用 \(enabledCount) 个并行同步后端"
        }
        if let account = store.syncStatus.account {
            return account.email
        }
        return store.syncConfig.activeStorageLocationSummary
    }

    private var statusDotColor: Color {
        if case .error = store.syncStatus.phase {
            return MobileTheme.destructive(for: colorScheme)
        }
        if store.syncStatus.isSyncing {
            return MobileTheme.accent(for: colorScheme)
        }
        return store.hasConnectedCloudBackend
            ? MobileTheme.positive(for: colorScheme)
            : MobileTheme.warning(for: colorScheme)
    }

    private var statusSubtitle: String {
        if store.syncStatus.isSyncing {
            return store.syncStatus.localizedPhaseTitle
        }
        if let syncedAt = store.syncStatus.lastSyncedAt {
            let pending = store.syncStatus.pendingOpCount
            if pending > 0 {
                return "上次同步 \(MobileFormatters.relativeDate(syncedAt)) · \(pending) 条待上传"
            }
            return "上次同步 \(MobileFormatters.relativeDate(syncedAt)) · \(store.syncConfig.activeStorageLocationSummary)"
        }
        return store.syncConfig.activeStorageLocationSummary
    }

    private func cacheRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.system(size: 13.5).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func openNewBackend(mode: DriveTransportMode) {
        isAddingNewBackend = true
        let count = store.syncConfig.resolvedBackends.filter { $0.mode == mode }.count
        let defaultName = count == 0 ? mode.localizedLabel : "\(mode.localizedLabel) \(count + 1)"
        editingBackend = SyncBackendProfile(
            name: defaultName,
            mode: mode,
            isEnabled: true,
            isPrimary: false
        )
    }

    private func populateFromStore() {
        let cfg = store.syncConfig
        autoSyncInterval = cfg.autoSyncIntervalSeconds
        syncThumbnails = cfg.syncThumbnails
        syncEmbeddings = cfg.syncEmbeddings
        cacheBudgetGB = max(1.0, min(16.0, Double(store.cacheStats.budgetBytes) / 1_073_741_824.0))
    }

    private func savePreferences() {
        var next = store.syncConfig
        next.autoSyncIntervalSeconds = autoSyncInterval
        next.syncThumbnails = syncThumbnails
        next.syncEmbeddings = syncEmbeddings
        Task {
            await store.saveSyncConfiguration(next, webDAVPassword: nil)
        }
    }
}

// MARK: - Mobile Add / Edit Backend Profile Sheet (iCloud Drive + Google Drive + WebDAV + Local)

private struct MobileBackendEditorSheet: View {
    @Bindable var store: MobileAppStore
    let isNew: Bool
    let onDone: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var draft: SyncBackendProfile
    @State private var webDAVPassword: String = ""
    @State private var pendingICloudBookmark: Data? = nil
    @State private var isICloudFolderImporterPresented = false
    @State private var isTesting = false

    init(store: MobileAppStore, initial: SyncBackendProfile, isNew: Bool, onDone: @escaping () -> Void) {
        self.store = store
        self._draft = State(initialValue: initial)
        self.isNew = isNew
        self.onDone = onDone
    }

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("后端名称（例如：iCloud Drive / 家庭 NAS）", text: $draft.name)
                if isNew {
                    Picker("后端类型", selection: $draft.mode) {
                        Text("iCloud Drive").tag(DriveTransportMode.iCloudDrive)
                        Text("Google Drive").tag(DriveTransportMode.directAPIWithGDirect)
                        Text("WebDAV").tag(DriveTransportMode.webDAV)
                        Text("本地目录").tag(DriveTransportMode.localOnly)
                    }
                    .onChange(of: draft.mode) { _, nextMode in
                        if draft.name.isEmpty || DriveTransportMode.allCases.map(\.localizedLabel).contains(draft.name) {
                            draft.name = nextMode.localizedLabel
                        }
                    }
                }
                Toggle("启用此同步后端", isOn: $draft.isEnabled)
            }

            switch draft.mode {
            case .iCloudDrive:
                Section {
                    HStack {
                        Text("默认目录名")
                        Spacer()
                        TextField("Charkle", text: $draft.iCloudFolderName)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Button {
                        isICloudFolderImporterPresented = true
                    } label: {
                        HStack {
                            Label(
                                draft.iCloudCustomFolderPath.isEmpty
                                    ? "从「文件」选择 iCloud Drive 目录…"
                                    : "已绑定：\(URL(fileURLWithPath: draft.iCloudCustomFolderPath).lastPathComponent)",
                                systemImage: "folder.badge.plus"
                            )
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !draft.iCloudCustomFolderPath.isEmpty {
                        Button("清除已选目录（恢复自动容器）", role: .destructive) {
                            draft.iCloudCustomFolderPath = ""
                            pendingICloudBookmark = nil
                        }
                        .font(.system(size: 13))
                    }
                } header: {
                    Text("iCloud Drive 目录")
                } footer: {
                    Text(
                        store.iCloudAvailability.isUbiquityContainerAvailable
                            ? "已检测到系统 iCloud 容器；也可以点上方按钮在「文件 → iCloud Drive」中选择与 Mac 相同的 Charkle 文件夹直接互通。"
                            : "侧载/无签名包请点击上方「从「文件」选择 iCloud Drive 目录」，选中 iCloud Drive 里的 Charkle 文件夹即可与 Mac 版无缝双向同步。"
                    )
                }

            case .directAPIWithGDirect, .gdirectMount:
                Section("Google Drive 位置") {
                    HStack {
                        Text("云端目录名")
                        Spacer()
                        TextField("Charkle", text: $draft.rootFolderName)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    TextField("共享目录链接或 ID（可选）", text: $draft.sharedFolderURLOrID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 13))
                }

            case .webDAV:
                Section("WebDAV 服务器") {
                    TextField("服务器地址（https://dav.example.com/dav/）", text: $draft.webDAVServerURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("用户名", text: $draft.webDAVUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码（留空保持原密码）", text: $webDAVPassword)
                    TextField("远端路径（/Charkle）", text: $draft.webDAVRemotePath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

            case .localOnly:
                Section("本地目录") {
                    TextField("本机路径", text: $draft.localLibraryPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            Section {
                Button {
                    isTesting = true
                    let candidate = draft
                    let pwd = webDAVPassword
                    let bm = pendingICloudBookmark
                    Task {
                        if candidate.mode == .iCloudDrive, let bm {
                            try? await store.engine.saveICloudBookmark(bm, displayPath: candidate.iCloudCustomFolderPath, for: candidate.id)
                        }
                        _ = await store.testBackendConnection(candidate, webDAVPassword: pwd.isEmpty ? nil : pwd)
                        isTesting = false
                    }
                } label: {
                    HStack {
                        if isTesting { ProgressView() }
                        Text(isTesting ? "正在测试连通性…" : "测试后端连接")
                    }
                }
                .disabled(isTesting)
            }
        }
        .navigationTitle(isNew ? "添加同步后端" : "编辑同步后端")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", action: onDone)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "添加" : "保存") {
                    var finalProfile = draft
                    if finalProfile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        finalProfile.name = finalProfile.mode.localizedLabel
                    }
                    let pwd = webDAVPassword
                    let bm = pendingICloudBookmark
                    Task {
                        if await store.upsertBackend(
                            finalProfile,
                            webDAVPassword: pwd.isEmpty ? nil : pwd,
                            iCloudBookmarkData: bm
                        ) {
                            onDone()
                        }
                    }
                }
                .fontWeight(.semibold)
            }
        }
        .fileImporter(
            isPresented: $isICloudFolderImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let folderURL = urls.first {
                let accessed = folderURL.startAccessingSecurityScopedResource()
                defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }
                if let bookmark = try? folderURL.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    pendingICloudBookmark = bookmark
                    draft.iCloudCustomFolderPath = folderURL.path
                    if draft.name == "iCloud Drive" || draft.name.isEmpty {
                        draft.name = "iCloud Drive"
                    }
                    MobileHaptics.success()
                } else {
                    store.showToast("无法保存所选目录的访问权限书签", tone: .error)
                }
            }
        }
    }
}
