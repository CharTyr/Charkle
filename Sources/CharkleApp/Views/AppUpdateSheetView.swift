import AppKit
import CharkleCore
import SwiftUI
import Textual

/// Native macOS In-App Update modal sheet powered by GitHub Releases.
/// Uses `CharkleTheme`, `CharkleButtonStyle`, `CharkleHairlineDivider`, and `Textual`
/// (`StructuredText(markdown:)`) with strict Light/Dark, dual accent, and accessibility parity.
public struct AppUpdateSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.charkleAccentSource) private var accentSource
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public let appUpdater: AppUpdateStore
    public let onPrepareQuitForUpdate: () -> Void

    public init(
        appUpdater: AppUpdateStore,
        onPrepareQuitForUpdate: @escaping () -> Void = {}
    ) {
        self.appUpdater = appUpdater
        self.onPrepareQuitForUpdate = onPrepareQuitForUpdate
    }

    private var activeAccent: Color {
        CharkleTheme.accent(for: colorScheme, source: accentSource)
    }

    private var hasReleaseDetails: Bool {
        appUpdater.activeUpdate != nil
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerSection

            CharkleHairlineDivider()

            bodySection

            CharkleHairlineDivider()

            footerSection
        }
        .frame(width: 520)
        .frame(height: hasReleaseDetails ? 500 : 270)
        .background(CharkleTheme.galleryGround(for: colorScheme))
        .animation(
            CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion),
            value: hasReleaseDetails
        )
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 14) {
            appIconView

            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle)
                    .font(CharkleTheme.text(.headline, weight: .semibold))
                    .foregroundStyle(.primary)

                headerSubtitleView
            }

            Spacer(minLength: 8)

            if !isInstalling {
                Button {
                    closeSheet()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.charkle(.subtle, size: .icon, iconDimension: 28))
                .help("关闭")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(CharkleTheme.surfaceElevated(for: colorScheme))
    }

    @ViewBuilder
    private var appIconView: some View {
        if let icon = CharkleAppIconManager.shared.previewImage(for: CharkleAppIconManager.shared.currentVariant) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverInner, style: .continuous))
        } else {
            CharkleBrandMark(size: 38)
                .frame(width: 44, height: 44)
        }
    }

    private var headerTitle: String {
        switch appUpdater.state {
        case .idle, .checking:
            return "检查 Charkle 更新"
        case .upToDate:
            return "Charkle 已是最新版本"
        case .available:
            return "发现 Charkle 新版本"
        case .downloading:
            return "正在下载更新"
        case .verifying:
            return "正在校验安装包"
        case .readyToInstall:
            return "更新已准备就绪"
        case .installing:
            return "正在安装更新并重启"
        case .manualInstallRequired:
            return "请手动完成安装"
        case .failed:
            return "更新未能完成"
        }
    }

    @ViewBuilder
    private var headerSubtitleView: some View {
        if let update = appUpdater.activeUpdate {
            HStack(spacing: 6) {
                Text("v\(appUpdater.currentVersion.description)")
                    .font(CharkleTheme.text(.caption, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))

                Image(systemName: "arrow.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))

                Text(update.tagName)
                    .font(CharkleTheme.text(.caption, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(activeAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        CharkleTheme.accentSoft(for: colorScheme, source: accentSource),
                        in: Capsule(style: .continuous)
                    )

                if update.assetSizeBytes > 0 {
                    Text("· \(Self.formatBytes(update.assetSizeBytes))")
                        .font(CharkleTheme.text(.caption))
                        .monospacedDigit()
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                }

                if let publishedAt = update.publishedAt {
                    Text("· \(Self.formatReleaseDate(publishedAt))")
                        .font(CharkleTheme.text(.caption))
                        .monospacedDigit()
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                }
            }
        } else {
            Text("当前版本 v\(appUpdater.currentVersion.description) (\(appUpdater.currentBuildNumber))")
                .font(CharkleTheme.text(.caption, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var bodySection: some View {
        if let update = appUpdater.activeUpdate {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("更新说明")
                        .font(CharkleTheme.text(.caption, weight: .semibold))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                    Spacer()
                    Text(update.assetName)
                        .font(CharkleTheme.text(.caption, design: .monospaced))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        .lineLimit(1)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)

                ScrollView(.vertical) {
                    releaseNotesView(for: update)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                        .charkleCleanScrollbars(hidden: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if shouldShowProgressBanner {
                    CharkleHairlineDivider()
                    statusStripView
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(CharkleTheme.surfaceElevated(for: colorScheme))
                }
            }
        } else {
            compactStatusBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private func releaseNotesView(for update: AppReleaseUpdate) -> some View {
        let trimmed = update.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Text("本次更新包含稳定性与性能优化，完整变更日志可在 GitHub Release 页面查看。")
                .font(CharkleTheme.text(.body))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } else {
            StructuredText(markdown: trimmed, baseURL: update.releasePageURL)
                .font(CharkleTheme.text(.body))
                .textual.structuredTextStyle(.gitHub)
                .textual.inlineStyle(Self.markdownInlineStyle)
                .textual.overflowMode(.scroll)
                .textual.textSelection(.enabled)
                .environment(\.openURL, Self.safeExternalOpenURLAction)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var shouldShowProgressBanner: Bool {
        switch appUpdater.state {
        case .downloading, .verifying, .readyToInstall, .installing, .manualInstallRequired:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var statusStripView: some View {
        switch appUpdater.state {
        case .downloading(_, let progress, let downloadedBytes, let totalBytes):
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text("正在下载安装包…")
                        .font(CharkleTheme.text(.body, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(Self.downloadCounterText(downloaded: downloadedBytes, total: totalBytes, progress: progress))
                        .font(CharkleTheme.text(.caption, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                }
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(activeAccent)
            }

        case .verifying(let update):
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在校验完整性与签名…")
                        .font(CharkleTheme.text(.body, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(update.expectedSHA256 != nil
                        ? "核对 SHA-256 校验和、应用标识与严格代码签名"
                        : "核对应用标识与严格代码签名")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                }
                Spacer()
            }

        case .readyToInstall:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(CharkleTheme.positive(for: colorScheme))
                VStack(alignment: .leading, spacing: 2) {
                    Text("SHA-256 校验与代码签名验证通过")
                        .font(CharkleTheme.text(.body, weight: .semibold))
                        .foregroundStyle(CharkleTheme.positive(for: colorScheme))
                    Text("点击「重启并安装更新」后，Charkle 将保存当前数据、替换应用包并自动重新打开。")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

        case .installing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在保存情绪板数据并替换应用包，即将自动重启…")
                    .font(CharkleTheme.text(.body, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
            }

        case .manualInstallRequired(_, let dmgURL):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(CharkleTheme.warning(for: colorScheme))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(appUpdater.manualInstallReason ?? "当前运行位置不支持原地替换，请打开已校验的安装包手动拖拽安装。")
                        .font(CharkleTheme.text(.caption, weight: .medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("已验证安装包：\(dmgURL.lastPathComponent)")
                        .font(CharkleTheme.text(.caption, design: .monospaced))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                }
                Spacer(minLength: 0)
            }

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var compactStatusBody: some View {
        switch appUpdater.state {
        case .idle, .checking:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text("正在连接 GitHub Releases 获取最新版本…")
                    .font(CharkleTheme.text(.body, weight: .medium))
                    .foregroundStyle(.primary)
                Text("校验来源：github.com/CharTyr/Charkle")
                    .font(CharkleTheme.text(.caption, design: .monospaced))
                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
            }

        case .upToDate(let checkedAt):
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(CharkleTheme.positive(for: colorScheme))
                Text("当前已是最新稳定版本")
                    .font(CharkleTheme.text(.body, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("上次检查：\(SettingsHelpers.relativeTimeText(checkedAt))")
                    .font(CharkleTheme.text(.caption))
                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
            }

        case .failed(let message):
            VStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(CharkleTheme.warning(for: colorScheme))
                Text(message)
                    .font(CharkleTheme.text(.body, weight: .medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("请检查网络连接，或直接前往 GitHub Releases 页面手动下载。")
                    .font(CharkleTheme.text(.caption))
                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
            }

        default:
            EmptyView()
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack(spacing: 8) {
            leadingFooterControls

            Spacer(minLength: 8)

            trailingFooterControls
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(
            reduceTransparency
                ? CharkleTheme.surfaceElevated(for: colorScheme)
                : CharkleTheme.inspectorBackground(for: colorScheme)
        )
    }

    @ViewBuilder
    private var leadingFooterControls: some View {
        switch appUpdater.state {
        case .available(let update):
            Button("跳过此版本") {
                appUpdater.skipVersion(update.version)
            }
            .buttonStyle(.charkle(.subtle, size: .sm))

            Button {
                appUpdater.openReleasePage()
            } label: {
                HStack(spacing: 4) {
                    Text("在 GitHub 查看")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .buttonStyle(.charkle(.subtle, size: .sm))

        case .upToDate, .failed, .readyToInstall, .manualInstallRequired:
            Button {
                appUpdater.openReleasePage()
            } label: {
                HStack(spacing: 4) {
                    Text("在 GitHub 查看")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .buttonStyle(.charkle(.subtle, size: .sm))

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailingFooterControls: some View {
        switch appUpdater.state {
        case .idle, .checking:
            Button("关闭") {
                closeSheet()
            }
            .buttonStyle(.charkle(.standard, size: .sm))
            .keyboardShortcut(.cancelAction)

        case .upToDate:
            Button("重新检查") {
                appUpdater.checkForUpdatesManually(presentSheet: true)
            }
            .buttonStyle(.charkle(.standard, size: .sm))

            Button("好") {
                closeSheet()
            }
            .buttonStyle(.charkle(.accent, size: .sm))
            .keyboardShortcut(.defaultAction)

        case .available:
            Button("稍后提醒") {
                closeSheet()
            }
            .buttonStyle(.charkle(.standard, size: .sm))
            .keyboardShortcut(.cancelAction)

            Button {
                appUpdater.downloadAndPrepareUpdate()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12))
                    Text("立即下载并更新")
                }
            }
            .buttonStyle(.charkle(.accent, size: .sm))
            .keyboardShortcut(.defaultAction)

        case .downloading:
            Button("取消下载") {
                appUpdater.cancelDownload()
            }
            .buttonStyle(.charkle(.standard, size: .sm))
            .keyboardShortcut(.cancelAction)

        case .verifying:
            Button("取消") {
                appUpdater.cancelDownload()
            }
            .buttonStyle(.charkle(.standard, size: .sm))

            Button("正在校验…") {}
                .buttonStyle(.charkle(.accent, size: .sm))
                .disabled(true)

        case .readyToInstall:
            Button("稍后再说") {
                closeSheet()
            }
            .buttonStyle(.charkle(.standard, size: .sm))
            .keyboardShortcut(.cancelAction)

            Button {
                appUpdater.installAndRelaunch(beforeTerminate: onPrepareQuitForUpdate)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("重启并安装更新")
                }
            }
            .buttonStyle(.charkle(.accent, size: .sm))
            .keyboardShortcut(.defaultAction)

        case .installing:
            Button("正在安装…") {}
                .buttonStyle(.charkle(.accent, size: .sm))
                .disabled(true)

        case .manualInstallRequired:
            Button("在访达中显示") {
                appUpdater.revealDownloadedDMG()
            }
            .buttonStyle(.charkle(.standard, size: .sm))

            Button("打开安装包") {
                appUpdater.openDownloadedDMG()
            }
            .buttonStyle(.charkle(.accent, size: .sm))
            .keyboardShortcut(.defaultAction)

        case .failed:
            Button("关闭") {
                closeSheet()
            }
            .buttonStyle(.charkle(.standard, size: .sm))
            .keyboardShortcut(.cancelAction)

            Button("重试") {
                appUpdater.checkForUpdatesManually(presentSheet: true)
            }
            .buttonStyle(.charkle(.accent, size: .sm))
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Helpers

    private var isInstalling: Bool {
        if case .installing = appUpdater.state { return true }
        return false
    }

    private func closeSheet() {
        appUpdater.isUpdateSheetPresented = false
        dismiss()
    }

    private static let markdownInlineStyle: InlineStyle = InlineStyle()
        .code(
            .monospaced,
            .fontScale(0.86),
            .backgroundColor(
                DynamicColor(
                    light: Color.black.opacity(0.055),
                    dark: Color.white.opacity(0.09)
                )
            )
        )
        .strong(.fontWeight(.semibold))
        .link(
            .foregroundColor(
                DynamicColor(
                    light: Color(charkleHex: CharkleTheme.studioAccentLightHex),
                    dark: Color(charkleHex: CharkleTheme.studioAccentDarkHex)
                )
            )
        )

    private static var safeExternalOpenURLAction: OpenURLAction {
        OpenURLAction { url in
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return .discarded
            }
            NSWorkspace.shared.open(url)
            return .handled
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter
    }()

    private static let releaseDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func formatBytes(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: max(0, bytes))
    }

    private static func downloadCounterText(downloaded: Int64, total: Int64, progress: Double) -> String {
        let percent = Int((min(1.0, max(0.0, progress)) * 100).rounded())
        let downloadedText = formatBytes(downloaded)
        if total > 0 {
            return "\(downloadedText) / \(formatBytes(total)) · \(percent)%"
        }
        return "\(downloadedText) · \(percent)%"
    }

    private static func formatReleaseDate(_ date: Date) -> String {
        releaseDateFormatter.string(from: date)
    }
}
