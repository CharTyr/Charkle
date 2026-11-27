import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI

/// High-craft first-launch & re-runnable onboarding studio for Charkle,
/// visually and functionally aligned with Charkle's modular 9-pane Settings overlay:
/// - Warm neutral `SettingsPalette` & `SettingsChrome` surfaces, hairline borders, and calm typography
/// - Bespoke layered hero icons (`layered-notch`, `layered-ai-spark`, `layered-gallery`, `layered-ready`)
/// - Live macOS Screen Recording permission check (`ScreenCapturePermissionChecker`) & default Notch target
/// - Google Drive OAuth setup sheet reuse (`GoogleOAuthSetupSheet`), WebDAV, ChatGPT & AI presets
/// - Every individual step and the entire onboarding flow are explicitly skippable at any time
public struct OnboardingView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let coordinator: AppCoordinatorStore
    public let syncAndAI: SyncAndAIStore
    public let onToggleNotchPreview: () -> Void
    public let onSyncHotkeysEnabled: (Bool) -> Void
    public let onSyncDefaultNotchTarget: (NotchTargetMode) -> Void
    public let onOpenSettings: (CharkleSettingsTab) -> Void
    public let onFinish: () -> Void

    public enum Step: Int, CaseIterable, Identifiable {
        case welcome = 0
        case storage = 1
        case capture = 2
        case intelligence = 3
        case workspace = 4
        case ready = 5

        public var id: Int { rawValue }

        var shortTitle: String {
            switch self {
            case .welcome: "欢迎"
            case .storage: "素材库"
            case .capture: "采集"
            case .intelligence: "AI 智能"
            case .workspace: "外观"
            case .ready: "完成"
            }
        }
    }

    private struct QuickAIPreset: Identifiable {
        let id: String
        let label: String
        let provider: CloudAIProviderKind
        let format: CustomAIEndpointFormat
        let baseURL: String
        let chatModel: String
        let embeddingModel: String
    }

    private static let aiPresets: [QuickAIPreset] = [
        QuickAIPreset(
            id: "gemini",
            label: "Gemini",
            provider: .gemini,
            format: .openAIChatCompletions,
            baseURL: "https://generativelanguage.googleapis.com",
            chatModel: "gemini-2.5-flash",
            embeddingModel: "gemini-embedding-001"
        ),
        QuickAIPreset(
            id: "openai",
            label: "OpenAI",
            provider: .openAICompatible,
            format: .openAIChatCompletions,
            baseURL: "https://api.openai.com/v1",
            chatModel: "gpt-4.1-mini",
            embeddingModel: "text-embedding-3-small"
        ),
        QuickAIPreset(
            id: "claude",
            label: "Claude",
            provider: .openAICompatible,
            format: .anthropicMessages,
            baseURL: "https://api.anthropic.com",
            chatModel: "claude-sonnet-4-5",
            embeddingModel: ""
        ),
        QuickAIPreset(
            id: "deepseek",
            label: "DeepSeek",
            provider: .openAICompatible,
            format: .openAIChatCompletions,
            baseURL: "https://api.deepseek.com/v1",
            chatModel: "deepseek-chat",
            embeddingModel: ""
        ),
        QuickAIPreset(
            id: "ollama",
            label: "Ollama 本地",
            provider: .openAICompatible,
            format: .openAIChatCompletions,
            baseURL: "http://localhost:11434/v1",
            chatModel: "qwen2.5vl:7b",
            embeddingModel: "nomic-embed-text"
        )
    ]

    private let appIconManager = CharkleAppIconManager.shared

    @Namespace private var stepPillNamespace

    @State private var currentStep: Step = .welcome
    @State private var stepDirection: CGFloat = 1
    @State private var skippedSteps: Set<Step> = []
    @State private var heroEntered: Bool = false
    @State private var welcomeCardsAppeared: Bool = false
    @State private var readyShockwaveExpanded: Bool = false
    @State private var hoveredPillarIndex: Int?
    @State private var isSkipButtonHovered: Bool = false

    // Live animated mini-notch preview state on Step 2
    @State private var demoNotchExpanded: Bool = false
    @State private var demoCardDropped: Bool = false
    @State private var demoConfirmed: Bool = false

    // Live macOS Screen Recording permission status
    @State private var hasScreenCapturePermission: Bool = ScreenCapturePermissionChecker.hasScreenRecordingAccess()

    // Real configuration drafts synced immediately on user edits
    @State private var draftSyncConfig: DriveSyncConfig = DriveSyncConfig()
    @State private var webDAVPasswordDraft: String = ""
    @State private var showOAuthSetupSheet: Bool = false

    @State private var draftAIConfig: AIProviderConfig = AIProviderConfig()
    @State private var aiAPIKeyDraft: String = ""
    @State private var localActionHint: String?
    @State private var localActionIsError: Bool = false

    public init(
        coordinator: AppCoordinatorStore,
        syncAndAI: SyncAndAIStore,
        onToggleNotchPreview: @escaping () -> Void,
        onSyncHotkeysEnabled: @escaping (Bool) -> Void,
        onSyncDefaultNotchTarget: @escaping (NotchTargetMode) -> Void = { _ in },
        onOpenSettings: @escaping (CharkleSettingsTab) -> Void = { _ in },
        onFinish: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.syncAndAI = syncAndAI
        self.onToggleNotchPreview = onToggleNotchPreview
        self.onSyncHotkeysEnabled = onSyncHotkeysEnabled
        self.onSyncDefaultNotchTarget = onSyncDefaultNotchTarget
        self.onOpenSettings = onOpenSettings
        self.onFinish = onFinish
    }

    private var sheetBackground: Color {
        SettingsPalette.contentBackground(for: colorScheme)
    }

    private var pedestalBackground: Color {
        SettingsPalette.railBackground(for: colorScheme)
    }

    private var cardBackground: Color {
        SettingsPalette.cardBackground(for: colorScheme)
    }

    private var selectedStrokeColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.50 : 0.42)
    }

    private var selectedFillColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.045)
    }

    public var body: some View {
        let outerShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.dockOuter, style: .continuous)

        ZStack {
            CharkleModalBackdrop()

            GeometryReader { geo in
                let maxAvailableWidth = max(360, geo.size.width - 24)
                let maxAvailableHeight = max(320, geo.size.height - 24)
                let modalWidth = min(max(620, geo.size.width - 72), min(840, maxAvailableWidth))
                let modalHeight = min(max(460, geo.size.height - 64), min(636, maxAvailableHeight))

                VStack(spacing: 0) {
                    headerBar
                        .padding(.horizontal, 22)
                        .padding(.top, 16)
                        .padding(.bottom, 13)

                    Rectangle()
                        .fill(SettingsPalette.border(for: colorScheme))
                        .frame(height: 0.75)

                    ZStack {
                        stepContent(for: currentStep)
                            .id(currentStep)
                            .transition(stepTransition)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                    Rectangle()
                        .fill(SettingsPalette.border(for: colorScheme))
                        .frame(height: 0.75)

                    footerBar
                        .padding(.horizontal, 22)
                        .padding(.vertical, 14)
                }
                .frame(width: modalWidth, height: modalHeight)
                .clipShape(outerShape)
                .background {
                    outerShape
                        .fill(sheetBackground)
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.46 : 0.14), radius: 34, y: 16)
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.05), radius: 8, y: 3)
                }
                .overlay(
                    outerShape.strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08),
                        lineWidth: CharkleTheme.hairlineWidth
                    )
                )
                .scaleEffect(heroEntered ? 1.0 : (reduceMotion ? 1.0 : 0.97))
                .opacity(heroEntered ? 1.0 : 0.0)
                .animation(CharkleMotion.accessible(CharkleMotion.enterMd, reduced: reduceMotion), value: heroEntered)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea(.all)
        .sheet(isPresented: $showOAuthSetupSheet) {
            GoogleOAuthSetupSheet(syncAndAI: syncAndAI, autoSignInAfterSave: true) {
                localActionIsError = false
                localActionHint = "凭据已导入，正在前往浏览器完成 Google 登录"
            }
        }
        .onAppear {
            heroEntered = true
            if reduceMotion {
                welcomeCardsAppeared = true
            }
        }
        .task(id: coordinator.onboardingRunID) {
            draftSyncConfig = syncAndAI.syncConfig
            draftAIConfig = syncAndAI.aiConfig
            hasScreenCapturePermission = ScreenCapturePermissionChecker.hasScreenRecordingAccess()
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(90))
                welcomeCardsAppeared = true
            }
            await syncAndAI.loadAll()
            draftSyncConfig = syncAndAI.syncConfig
            draftAIConfig = syncAndAI.aiConfig
        }
        .onChange(of: syncAndAI.syncConfig) { _, latest in
            var merged = latest
            if !draftSyncConfig.webDAVServerURL.isEmpty && latest.webDAVServerURL.isEmpty {
                merged.webDAVServerURL = draftSyncConfig.webDAVServerURL
            }
            if !draftSyncConfig.webDAVUsername.isEmpty && latest.webDAVUsername.isEmpty {
                merged.webDAVUsername = draftSyncConfig.webDAVUsername
            }
            draftSyncConfig = merged
        }
        .onChange(of: syncAndAI.aiConfig) { _, latest in
            draftAIConfig = latest
        }
        .onChange(of: currentStep) { _, next in
            localActionHint = nil
            localActionIsError = false
            if next == .capture {
                hasScreenCapturePermission = ScreenCapturePermissionChecker.hasScreenRecordingAccess()
            }
            if next == .ready {
                triggerReadyShockwave()
            } else {
                readyShockwaveExpanded = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if currentStep == .capture || currentStep == .ready {
                hasScreenCapturePermission = ScreenCapturePermissionChecker.hasScreenRecordingAccess()
            }
        }
        .onKeyPress(.escape) {
            guard !showOAuthSetupSheet else { return .ignored }
            skipEntireOnboarding()
            return .handled
        }
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let enterOffset = stepDirection * 24
        let exitOffset = -stepDirection * 20
        return .asymmetric(
            insertion: .opacity
                .combined(with: .offset(x: enterOffset))
                .combined(with: .scale(scale: 0.985)),
            removal: .opacity
                .combined(with: .offset(x: exitOffset))
                .combined(with: .scale(scale: 0.99))
        )
    }

    // MARK: - Header & Interactive Progress Rail

    private var headerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                CharkleBrandMark(size: 22)
                Text("Charkle")
                    .font(CharkleTheme.text(.body, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: 112, alignment: .leading)

            Spacer(minLength: 8)

            // Travelling active capsule indicator (moveOnScreen continuity)
            HStack(spacing: 2.5) {
                ForEach(Step.allCases) { step in
                    let isActive = currentStep == step
                    let isPast = step.rawValue < currentStep.rawValue
                    let wasSkipped = skippedSteps.contains(step)
                    Button {
                        navigate(to: step)
                    } label: {
                        HStack(spacing: 5) {
                            if isPast && !wasSkipped {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(SettingsPalette.positiveInk(for: colorScheme))
                            } else if isPast && wasSkipped {
                                Circle()
                                    .strokeBorder(Color.primary.opacity(0.28), lineWidth: 1.2)
                                    .frame(width: 6, height: 6)
                            } else {
                                Circle()
                                    .fill(isActive ? Color.primary : Color.primary.opacity(0.22))
                                    .frame(width: 5.5, height: 5.5)
                            }
                            Text(step.shortTitle)
                                .font(CharkleTheme.text(.caption, weight: isActive ? .semibold : .medium))
                                .foregroundStyle(isActive ? .primary : .secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            if isActive {
                                Capsule(style: .continuous)
                                    .fill(cardBackground)
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .strokeBorder(SettingsPalette.border(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                                    )
                                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.30 : 0.06), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "onboarding-step-pill", in: stepPillNamespace)
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(SettingsPalette.subtleFill(for: colorScheme), in: Capsule(style: .continuous))
            .animation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion), value: currentStep)

            Spacer(minLength: 8)

            HStack {
                Spacer()
                if currentStep != .ready {
                    Button {
                        skipEntireOnboarding()
                    } label: {
                        HStack(spacing: 4) {
                            Text("跳过引导")
                                .font(CharkleTheme.text(.caption, weight: .medium))
                            Image(systemName: "xmark")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .foregroundStyle(isSkipButtonHovered ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            isSkipButtonHovered ? SettingsPalette.subtleFill(for: colorScheme) : Color.clear,
                            in: Capsule(style: .continuous)
                        )
                        .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .onHover { isSkipButtonHovered = $0 }
                    .help("直接跳过全部引导 (Esc)，随时可在「设置 → 通用」重新查看")
                }
            }
            .frame(width: 112)
        }
    }

    // MARK: - Footer Navigation Bar (Always Skippable + Tactile Primary CTA)

    private var footerBar: some View {
        HStack(spacing: 10) {
            if currentStep != .welcome {
                Button {
                    goPrevious()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("上一步")
                    }
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
            } else {
                Text("每一步都可跳过 · 随时可在「设置 (⌘,) → 通用」重新查看")
                    .font(CharkleTheme.text(.caption))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(currentStep.rawValue + 1) / \(Step.allCases.count)")
                .font(CharkleTheme.text(.caption, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .padding(.trailing, 4)

            switch currentStep {
            case .welcome:
                Button("跳过，直接使用") {
                    skipEntireOnboarding()
                }
                .buttonStyle(SettingsSecondaryButtonStyle())

                Button {
                    goNext(skipped: false)
                } label: {
                    HStack(spacing: 6) {
                        Text("开始快速配置")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(CharkleSkeuoButtonStyle(.primary))

            case .storage, .capture, .intelligence, .workspace:
                Button("跳过此步") {
                    goNext(skipped: true)
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .help("保持当前默认设置，稍后再在「设置」中按需配置")

                Button {
                    goNext(skipped: false)
                } label: {
                    HStack(spacing: 6) {
                        Text(currentStep == .workspace ? "查看配置摘要" : "下一步")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(CharkleSkeuoButtonStyle(.primary))

            case .ready:
                Button("打开完整设置 (⌘,)") {
                    finishAndOpenSettings(.general)
                }
                .buttonStyle(SettingsSecondaryButtonStyle())

                Button {
                    finishOnboarding()
                } label: {
                    HStack(spacing: 6) {
                        Text("进入 Charkle 工作台")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(CharkleSkeuoButtonStyle(.primary))
            }
        }
    }

    // MARK: - Step Router

    @ViewBuilder
    private func stepContent(for step: Step) -> some View {
        switch step {
        case .welcome:
            welcomeStep
        case .storage:
            storageStep
        case .capture:
            captureStep
        case .intelligence:
            intelligenceStep
        case .workspace:
            workspaceStep
        case .ready:
            readyStep
        }
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 6)

            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(charkleHex: "#3B74E8").opacity(colorScheme == .dark ? 0.20 : 0.11),
                                    .clear
                                ],
                                center: .center,
                                startRadius: 6,
                                endRadius: 56
                            )
                        )
                        .frame(width: 110, height: 110)

                    CharkleBrandMark(size: 62)
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.42 : 0.15), radius: 14, y: 7)
                }
                .scaleEffect(welcomeCardsAppeared ? 1.0 : (reduceMotion ? 1.0 : 0.90))
                .opacity(welcomeCardsAppeared ? 1.0 : 0.0)
                .animation(CharkleMotion.accessible(CharkleMotion.onboardingDelightSpring, reduced: reduceMotion), value: welcomeCardsAppeared)

                VStack(spacing: 6) {
                    Text("欢迎使用 Charkle")
                        .font(CharkleTheme.text(.title, weight: .bold))
                        .tracking(-0.45)
                        .foregroundStyle(.primary)

                    Text("专为视觉创作者打造的 macOS 灵感收集与情绪板工作台。花 1 分钟按需选几项偏好，或直接跳过立即开始。")
                        .font(CharkleTheme.text(.body))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 540)
                }
            }

            // 4 staggered pillars showcasing our layered icons
            HStack(spacing: 12) {
                welcomePillarCard(
                    index: 0,
                    iconName: "notch",
                    accentHex: "#3B74E8",
                    title: "顶部刘海随手拖",
                    subtitle: "跨应用拖起即收纳，不抢窗口焦点，支持反向拖出复用",
                    targetStep: .capture
                )
                welcomePillarCard(
                    index: 1,
                    iconName: "library",
                    accentHex: "#D96B43",
                    title: "本地与云端无损互迁",
                    subtitle: "支持纯本地、Google Drive 与 WebDAV，随时一键安全搬家",
                    targetStep: .storage
                )
                welcomePillarCard(
                    index: 2,
                    iconName: "ai-spark",
                    accentHex: "#2A8F9D",
                    title: "离线视觉 + 可选云 AI",
                    subtitle: "免费内置配色提取、OCR 与相似检索，按需接入云端策展",
                    targetStep: .intelligence
                )
                welcomePillarCard(
                    index: 3,
                    iconName: "moodboard",
                    accentHex: "#3D9970",
                    title: "自由画布与 Figma 桥接",
                    subtitle: "10 秒拼板推演灵感，原生支持导出高分辨率可编辑 Figma 包",
                    targetStep: .workspace
                )
            }
            .padding(.horizontal, 26)

            Spacer(minLength: 4)
        }
    }

    private func welcomePillarCard(
        index: Int,
        iconName: String,
        accentHex: String,
        title: String,
        subtitle: String,
        targetStep: Step
    ) -> some View {
        let hovered = hoveredPillarIndex == index
        return Button {
            navigate(to: targetStep)
        } label: {
            VStack(alignment: .leading, spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous)
                        .fill(Color(charkleHex: accentHex).opacity(colorScheme == .dark ? 0.14 : 0.08))
                        .frame(width: 54, height: 54)
                    CharkleIcon(iconName, style: .layered, size: 40)
                        .scaleEffect(hovered && !reduceMotion ? 1.07 : 1.0)
                        .offset(y: hovered && !reduceMotion ? -2 : 0)
                        .animation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion), value: hovered)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(CharkleTheme.text(.body, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2.2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 162, alignment: .topLeading)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous)
                    .strokeBorder(
                        hovered ? selectedStrokeColor : SettingsPalette.border(for: colorScheme),
                        lineWidth: hovered ? 1.5 : CharkleTheme.hairlineWidth
                    )
            )
            .shadow(
                color: Color.black.opacity(hovered ? (colorScheme == .dark ? 0.28 : 0.07) : (colorScheme == .dark ? 0.12 : 0.03)),
                radius: hovered ? 10 : 4,
                y: hovered ? 4 : 2
            )
            .offset(y: welcomeCardsAppeared ? (hovered && !reduceMotion ? -2 : 0) : (reduceMotion ? 0 : 12))
            .opacity(welcomeCardsAppeared ? 1.0 : 0.0)
            .animation(
                reduceMotion
                    ? CharkleMotion.reducedMotionFade
                    : CharkleMotion.enterMd.delay(Double(index) * 0.05),
                value: welcomeCardsAppeared
            )
            .animation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion), value: hovered)
        }
        .buttonStyle(.plain)
        .onHover { isOver in
            hoveredPillarIndex = isOver ? index : (hoveredPillarIndex == index ? nil : hoveredPillarIndex)
        }
    }

    // MARK: - Step 1: Library Storage & Cloud Sync

    private var storageStep: some View {
        let activeMode: DriveTransportMode = draftSyncConfig.mode == .gdirectMount ? .directAPIWithGDirect : draftSyncConfig.mode
        let isLocal = activeMode == .localOnly
        let isGoogle = activeMode == .directAPIWithGDirect
        let isWebDAV = activeMode == .webDAV
        let hasGDirect = syncAndAI.gdirectSnapshot.cliPath != nil
        let directAccount: DriveAccountInfo? = {
            guard let acc = syncAndAI.syncStatus.account,
                  acc.source != "WebDAV",
                  acc.source != "本地文件夹" else { return nil }
            return acc
        }()

        return twoColumnStepLayout(
            hero: {
                stepHeroPedestal(
                    iconName: isLocal ? "folder" : "drive",
                    accentHex: isLocal ? "#D96B43" : "#3B74E8",
                    badgeText: isLocal ? "本机隐私优先" : (directAccount != nil ? "已连接云端" : "多机自动同步"),
                    caption: isLocal
                        ? "所有素材原件与索引直接留在你指定的本机目录，零账号即可开箱使用。"
                        : "文件夹、原图与情绪板自动增量同步；随时可在「设置 → 素材库」一键无损互迁。"
                )
            },
            content: {
                stepHeading(
                    title: "素材库保存在哪里？",
                    subtitle: "默认使用纯本地目录，也可现在或以后再接入云盘。跳过此步将保留当前存储设置。",
                    optionalTag: "可选 · 可跳过"
                )

                VStack(spacing: 10) {
                    // Option 1: Pure Local Folder
                    radioChoiceCard(
                        title: "纯本地文件夹",
                        badge: "默认推荐",
                        badgeTint: SettingsPalette.positiveInk(for: colorScheme),
                        subtitle: "零配置立即可用，文件完整留在你的 Mac 本地文件夹",
                        iconName: "library",
                        isSelected: isLocal
                    ) {
                        selectStorageMode(.localOnly)
                    } detail: {
                        HStack(spacing: 8) {
                            Text(draftSyncConfig.localLibraryPath.isEmpty ? "~/Pictures/Charkle" : draftSyncConfig.localLibraryPath)
                                .font(CharkleTheme.text(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("选择文件夹…") {
                                pickLocalFolder()
                            }
                            .buttonStyle(SettingsSecondaryButtonStyle())
                            .fixedSize()
                        }
                    }

                    // Option 2: Google Drive Direct Sync (aligned with SyncSettingsPane + GoogleOAuthSetupSheet)
                    radioChoiceCard(
                        title: "Google Drive 云端直连",
                        badge: directAccount != nil ? "已连接" : nil,
                        badgeTint: SettingsPalette.positiveInk(for: colorScheme),
                        subtitle: "直连你自己的 Google Drive，不经第三方中转，支持多机同步与共享协作",
                        iconName: "drive-sync",
                        isSelected: isGoogle
                    ) {
                        selectStorageMode(.directAPIWithGDirect)
                    } detail: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                if let account = directAccount {
                                    SettingsStatusBadge(account.email, tint: SettingsPalette.positiveInk(for: colorScheme))
                                    Spacer()
                                } else if syncAndAI.hasGoogleOAuthClient {
                                    Text("点击后在浏览器中安全完成 OAuth 登录")
                                        .font(CharkleTheme.text(.caption))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        Task {
                                            let ok = await syncAndAI.signInGoogleDrive()
                                            localActionIsError = !ok
                                            localActionHint = ok
                                                ? "Google 账号登录成功，同步已就绪"
                                                : (syncAndAI.errorMessage ?? "登录未完成，可稍后在「设置 → 云同步」重试")
                                        }
                                    } label: {
                                        HStack(spacing: 5) {
                                            if syncAndAI.isBusy { ProgressView().controlSize(.mini) }
                                            Text("使用 Google 登录")
                                        }
                                    }
                                    .buttonStyle(SettingsPrimaryButtonStyle())
                                    .fixedSize()
                                    .disabled(syncAndAI.isBusy)
                                } else {
                                    Text(hasGDirect ? "检测到本机 gdirect，可一键导入凭据" : "首次直连需准备个人桌面端 OAuth 凭据")
                                        .font(CharkleTheme.text(.caption))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if hasGDirect {
                                        Button("从 gdirect 导入并登录") {
                                            Task {
                                                if await syncAndAI.importGoogleOAuthFromGDirect() {
                                                    let ok = await syncAndAI.signInGoogleDrive()
                                                    localActionIsError = !ok
                                                    localActionHint = ok ? "已通过 gdirect 凭据完成登录" : (syncAndAI.errorMessage ?? "登录未完成")
                                                }
                                            }
                                        }
                                        .buttonStyle(SettingsPrimaryButtonStyle())
                                        .fixedSize()
                                        .disabled(syncAndAI.isBusy)

                                        Button("手动配置…") {
                                            showOAuthSetupSheet = true
                                        }
                                        .buttonStyle(SettingsSecondaryButtonStyle())
                                        .fixedSize()
                                    } else {
                                        Button("配置凭据并登录…") {
                                            showOAuthSetupSheet = true
                                        }
                                        .buttonStyle(SettingsPrimaryButtonStyle())
                                        .fixedSize()
                                    }
                                }
                            }
                        }
                    }

                    // Option 3: WebDAV / NAS
                    radioChoiceCard(
                        title: "WebDAV 云盘 / 自建 NAS",
                        badge: (isWebDAV && !draftSyncConfig.webDAVServerURL.isEmpty && syncAndAI.hasWebDAVPassword) ? "已保存" : nil,
                        badgeTint: SettingsPalette.positiveInk(for: colorScheme),
                        subtitle: "兼容坚果云、Nextcloud、群晖 NAS、Alist 等任意标准 WebDAV 服务",
                        iconName: "drive-sync",
                        isSelected: isWebDAV
                    ) {
                        selectStorageMode(.webDAV)
                    } detail: {
                        VStack(spacing: 8) {
                            TextField("服务器地址（如 https://dav.jianguoyun.com/dav/）", text: $draftSyncConfig.webDAVServerURL)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                            HStack(spacing: 8) {
                                TextField("用户名", text: $draftSyncConfig.webDAVUsername)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                                SecureField(syncAndAI.hasWebDAVPassword ? "已保存密码（留空保持）" : "应用专用密码", text: $webDAVPasswordDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                                Button("测试并保存") {
                                    Task {
                                        let ok = await syncAndAI.testWebDAVConnection(
                                            config: draftSyncConfig,
                                            password: webDAVPasswordDraft.isEmpty ? nil : webDAVPasswordDraft
                                        )
                                        localActionIsError = !ok
                                        localActionHint = ok
                                            ? "WebDAV 连接验证通过并已保存"
                                            : (syncAndAI.errorMessage ?? "连接失败，请核对地址或应用密码")
                                    }
                                }
                                .buttonStyle(SettingsPrimaryButtonStyle())
                                .fixedSize()
                                .disabled(syncAndAI.isBusy || draftSyncConfig.webDAVServerURL.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                    }
                }

                inlineFeedbackPill
            }
        )
    }

    // MARK: - Step 2: Notch Shelf, Screen Recording Permission & Shortcuts

    private var captureStep: some View {
        twoColumnStepLayout(
            hero: {
                VStack(spacing: 14) {
                    miniNotchAnimatedDemo

                    Button {
                        onToggleNotchPreview()
                    } label: {
                        HStack(spacing: 6) {
                            CharkleIcon("notch", style: .duotone, size: 15)
                            Text("预览顶部真刘海 (\(GlobalHotkeyManager.displayString(for: .toggleNotchShelf, fallback: "⌥⇧S")))")
                                .font(CharkleTheme.text(.caption, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .disabled(!coordinator.notchShelfEnabled)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(pedestalBackground, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous)
                        .strokeBorder(SettingsPalette.border(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                )
            },
            content: {
                stepHeading(
                    title: "刘海浮窗、截图权限与快捷键",
                    subtitle: "在任意应用中拖拽靠近屏幕顶部即可收纳灵感，以下开关即时生效，不需要的项目可留空跳过。",
                    optionalTag: "可选 · 可跳过"
                )

                // 1. Live macOS Screen Recording Permission Card (aligned with CaptureShortcutsSettingsPane)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Text("屏幕录制权限（区域截图）")
                                    .font(CharkleTheme.text(.body, weight: .medium))
                                    .foregroundStyle(.primary)
                                SettingsStatusBadge(
                                    hasScreenCapturePermission ? "已授权" : "暂未开启",
                                    tint: hasScreenCapturePermission
                                        ? SettingsPalette.positiveInk(for: colorScheme)
                                        : SettingsPalette.warningInk(for: colorScheme)
                                )
                            }
                            let captureKey = GlobalHotkeyManager.displayString(for: .captureArea, fallback: "⌥⇧A")
                            Text(
                                hasScreenCapturePermission
                                    ? "已就绪 · 可随时按 \(captureKey) 在任意应用中框选截图入库"
                                    : "仅在使用 \(captureKey) 区域截图时需要；纯拖图或收藏剪贴板可直接跳过"
                            )
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 8)

                        HStack(spacing: 6) {
                            Button("重新检测") {
                                hasScreenCapturePermission = ScreenCapturePermissionChecker.hasScreenRecordingAccess()
                            }
                            .buttonStyle(SettingsSecondaryButtonStyle())
                            .fixedSize()

                            if !hasScreenCapturePermission {
                                Button("打开系统设置") {
                                    _ = ScreenCapturePermissionChecker.requestAccessPromptIfNeeded()
                                    ScreenCapturePermissionChecker.openSystemSettings()
                                }
                                .buttonStyle(SettingsPrimaryButtonStyle())
                                .fixedSize()
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                    if !hasScreenCapturePermission {
                        InlineGuideDisclosure("如何开启屏幕录制权限（可稍后再开）") {
                            SettingsGuideStep("1", title: "点击「打开系统设置」直达「隐私与安全性 → 录屏与系统录音」")
                            SettingsGuideStep("2", title: "打开列表中 Charkle 的开关（若未出现可点左下角 + 选择 Charkle.app）")
                            SettingsGuideStep("3", title: "返回 Charkle 点击「重新检测」确认状态")
                        }
                    }
                }
                .background(cardBackground, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous)
                        .strokeBorder(SettingsPalette.border(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                )

                // 2. Notch Shelf & Default Target & Hotkeys Card (aligned with NotchShelfSettingsPane)
                VStack(spacing: 0) {
                    instantSwitchRow(
                        title: "启用屏幕顶部灵感浮窗",
                        subtitle: "拖起图片、链接或文件靠近顶边时自动滑出收纳区",
                        isOn: Binding(
                            get: { coordinator.notchShelfEnabled },
                            set: { coordinator.notchShelfEnabled = $0 }
                        )
                    )
                    SettingsCardDivider()
                    instantSwitchRow(
                        title: "悬停顶部中央自动展开",
                        subtitle: "鼠标停留在刘海区域片刻即可浏览最近素材或反向拖出",
                        isOn: Binding(
                            get: { coordinator.notchHoverTriggerEnabled },
                            set: { coordinator.notchHoverTriggerEnabled = $0 }
                        ),
                        disabled: !coordinator.notchShelfEnabled
                    )
                    SettingsCardDivider()
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("默认收纳目标")
                                .font(CharkleTheme.text(.body, weight: .medium))
                                .foregroundStyle(coordinator.notchShelfEnabled ? .primary : .secondary)
                            Text("拖入浮窗或快捷键采集的新灵感默认落入位置")
                                .font(CharkleTheme.text(.caption))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Picker("", selection: Binding(
                            get: { coordinator.defaultNotchTargetMode },
                            set: { newMode in
                                coordinator.defaultNotchTargetMode = newMode
                                onSyncDefaultNotchTarget(newMode)
                            }
                        )) {
                            ForEach(NotchTargetMode.allCases, id: \.self) { mode in
                                Text(mode.localizedTitle).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 146)
                        .disabled(!coordinator.notchShelfEnabled)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .opacity(coordinator.notchShelfEnabled ? 1.0 : 0.55)

                    SettingsCardDivider()
                    let captureKey = GlobalHotkeyManager.displayString(for: .captureArea, fallback: "⌥⇧A")
                    let clipboardKey = GlobalHotkeyManager.displayString(for: .collectClipboard, fallback: "⌥⇧V")
                    let notchKey = GlobalHotkeyManager.displayString(for: .toggleNotchShelf, fallback: "⌥⇧S")
                    instantSwitchRow(
                        title: "启用系统全局快捷键",
                        subtitle: "任意应用中随时按 \(captureKey) 截图、\(clipboardKey) 收藏剪贴板与推文、\(notchKey) 呼出刘海",
                        isOn: Binding(
                            get: { coordinator.globalHotkeysEnabled },
                            set: { newVal in
                                coordinator.globalHotkeysEnabled = newVal
                                onSyncHotkeysEnabled(newVal)
                            }
                        )
                    )
                }
                .background(cardBackground, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous)
                        .strokeBorder(SettingsPalette.border(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                )
            }
        )
        .task(id: currentStep == .capture) {
            guard currentStep == .capture else { return }
            if reduceMotion {
                demoNotchExpanded = true
                demoCardDropped = false
                demoConfirmed = true
                return
            }
            while !Task.isCancelled && currentStep == .capture {
                demoNotchExpanded = false
                demoCardDropped = false
                demoConfirmed = false
                try? await Task.sleep(for: .milliseconds(550))
                guard !Task.isCancelled else { break }
                withAnimation(CharkleMotion.notchMorphSpring) {
                    demoNotchExpanded = true
                }
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { break }
                withAnimation(CharkleMotion.enterMd) {
                    demoCardDropped = true
                }
                try? await Task.sleep(for: .milliseconds(520))
                guard !Task.isCancelled else { break }
                withAnimation(CharkleMotion.settleStrong) {
                    demoConfirmed = true
                }
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    private var miniNotchAnimatedDemo: some View {
        let targetText = coordinator.defaultNotchTargetMode.localizedTitle
        return VStack(spacing: 10) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [Color(charkleHex: "#242730"), Color(charkleHex: "#181A20")]
                                : [Color(charkleHex: "#E7EAEF"), Color(charkleHex: "#F3F4F6")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous)
                            .strokeBorder(SettingsPalette.border(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                    )

                VStack(spacing: 6) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.20))
                        .frame(width: 26, height: 3.5)
                        .padding(.top, 5)

                    if demoNotchExpanded {
                        HStack(spacing: 6) {
                            Image(systemName: demoConfirmed ? "checkmark.circle.fill" : "arrow.down.doc.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(demoConfirmed ? Color(charkleHex: "#4ADE80") : Color(charkleHex: "#60A5FA"))
                            Text(demoConfirmed ? "已收入\(targetText)" : "松手即存")
                                .font(CharkleTheme.text(.caption, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            (demoConfirmed ? Color(charkleHex: "#3D9970") : Color(charkleHex: "#3B82F6")).opacity(0.22),
                            in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
                    }
                }
                .frame(width: demoNotchExpanded ? 162 : 64, height: demoNotchExpanded ? 64 : 16, alignment: .top)
                .background(
                    Color.black,
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: demoNotchExpanded ? CharkleTheme.Radius.cardOuter : CharkleTheme.Radius.sm,
                        bottomTrailingRadius: demoNotchExpanded ? CharkleTheme.Radius.cardOuter : CharkleTheme.Radius.sm,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                )
                .shadow(color: Color.black.opacity(0.26), radius: 8, y: 4)

                RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(charkleHex: "#3B74E8"), Color(charkleHex: "#2A8F9D")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 34, height: 24)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                    )
                    .shadow(color: Color.black.opacity(0.18), radius: 6, y: 3)
                    .offset(y: demoCardDropped ? 28 : 96)
                    .scaleEffect(demoConfirmed ? 0.65 : (demoCardDropped ? 0.92 : 1.0))
                    .opacity(demoConfirmed ? 0.0 : 1.0)
            }
            .frame(height: 146)
            .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous))

            HStack(spacing: 8) {
                CharkleIcon("notch", style: .layered, size: 32)
                Text("拖起素材靠近屏幕顶边即展，不抢焦点、不切桌面。")
                    .font(CharkleTheme.text(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Step 3: Local Vision + Optional Cloud AI (Aligned with AISettingsPane)

    private var intelligenceStep: some View {
        let isLocalOnly = draftAIConfig.provider == .disabled
        let isChatGPT = draftAIConfig.provider == .chatGPTSubscription
        let isAPI = draftAIConfig.provider == .gemini || draftAIConfig.provider == .openAICompatible
        let isLocalOllama = draftAIConfig.provider == .openAICompatible &&
            (draftAIConfig.baseURL.lowercased().contains("localhost") || draftAIConfig.baseURL.contains("127.0.0.1"))

        return twoColumnStepLayout(
            hero: {
                VStack(spacing: 14) {
                    stepHeroIconDisc(iconName: "ai-spark", accentHex: "#2A8F9D")

                    VStack(alignment: .leading, spacing: 7) {
                        Text("基础离线能力免费内置")
                            .font(CharkleTheme.text(.caption, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("无需下载模型 · 数据不出本机")
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 2)
                        offlineFeatureBullet("自动配色提取与相近色筛选")
                        offlineFeatureBullet("视觉相似推荐（Apple Vision）")
                        offlineFeatureBullet("图内文字 OCR 识别")
                        offlineFeatureBullet("中文与拼音首字母快搜")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(cardBackground, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous)
                            .strokeBorder(SettingsPalette.border(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                    )
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(pedestalBackground, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous)
                        .strokeBorder(SettingsPalette.border(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                )
            },
            content: {
                stepHeading(
                    title: "需要云端 AI 自动打标与生板吗？",
                    subtitle: "纯属可选增强项。跳过将保持仅使用本机离线能力，日后可在「设置 → AI 智能」随时接入。",
                    optionalTag: "可选 · 可跳过"
                )

                VStack(spacing: 10) {
                    radioChoiceCard(
                        title: "仅使用内置离线能力",
                        badge: "默认",
                        badgeTint: SettingsPalette.positiveInk(for: colorScheme),
                        subtitle: "零费用、零账号、完全离线；配色、OCR、相似图与快搜全部立即可用",
                        iconName: "similar",
                        isSelected: isLocalOnly
                    ) {
                        selectAIProvider(.disabled)
                    } detail: {
                        EmptyView()
                    }

                    // ChatGPT Subscription Option with official mark from SettingsHelpers
                    radioChoiceCardCustomIcon(
                        title: "连接 ChatGPT 订阅账号",
                        badge: syncAndAI.chatGPTSession.status == .connected ? "已连接" : nil,
                        badgeTint: SettingsPalette.positiveInk(for: colorScheme),
                        subtitle: "使用你的 ChatGPT Plus / Pro 订阅，无需额外购买 API Key",
                        isSelected: isChatGPT,
                        icon: {
                            SettingsHelpers.chatGPTBrandMark(size: 17, color: isChatGPT ? .primary : .secondary)
                        }
                    ) {
                        selectAIProvider(.chatGPTSubscription)
                    } detail: {
                        HStack(spacing: 10) {
                            if syncAndAI.chatGPTSession.status == .connected {
                                SettingsStatusBadge(
                                    syncAndAI.chatGPTSession.displayName,
                                    tint: SettingsPalette.positiveInk(for: colorScheme)
                                )
                                Spacer()
                            } else {
                                Text("通过官方 OAuth 登录，凭据仅存于系统钥匙串")
                                    .font(CharkleTheme.text(.caption))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    Task {
                                        let ok = await syncAndAI.signInWithChatGPT()
                                        localActionIsError = !ok
                                        localActionHint = ok
                                            ? "已连接 ChatGPT 账号，云端打标与策展已就绪"
                                            : (syncAndAI.errorMessage ?? "连接未完成，可稍后在「设置 → AI 智能」重试")
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        if syncAndAI.isSigningInChatGPT { ProgressView().controlSize(.mini) }
                                        Text("登录 ChatGPT")
                                    }
                                }
                                .buttonStyle(SettingsPrimaryButtonStyle())
                                .fixedSize()
                                .disabled(syncAndAI.isSigningInChatGPT)
                            }
                        }
                    }

                    // Gemini / Custom API with presets aligned with AISettingsPane
                    radioChoiceCard(
                        title: "Google Gemini 或自定义 API",
                        badge: (isAPI && (syncAndAI.hasStoredAIKey || isLocalOllama)) ? "已配置" : nil,
                        badgeTint: SettingsPalette.positiveInk(for: colorScheme),
                        subtitle: "一键预设 Gemini、OpenAI、Claude、DeepSeek 或本机 Ollama",
                        iconName: "sparkle-board",
                        isSelected: isAPI
                    ) {
                        if !isAPI {
                            applyAIPreset(Self.aiPresets[0])
                        }
                    } detail: {
                        VStack(alignment: .leading, spacing: 8) {
                            // Quick preset pills
                            HStack(spacing: 6) {
                                ForEach(Self.aiPresets) { preset in
                                    let active = isPresetActive(preset)
                                    Button(preset.label) {
                                        applyAIPreset(preset)
                                    }
                                    .font(CharkleTheme.text(.caption, weight: active ? .semibold : .medium))
                                    .foregroundStyle(active ? (colorScheme == .dark ? Color.black : Color.white) : Color.primary.opacity(0.82))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(
                                        active
                                            ? (colorScheme == .dark ? Color.white : Color(charkleHex: "#18191D"))
                                            : SettingsPalette.subtleFill(for: colorScheme),
                                        in: Capsule(style: .continuous)
                                    )
                                    .buttonStyle(.plain)
                                }
                            }

                            HStack(spacing: 8) {
                                TextField("模型名（如 gemini-2.5-flash）", text: $draftAIConfig.chatModel)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)

                                if draftAIConfig.provider == .openAICompatible {
                                    TextField("接口地址", text: $draftAIConfig.baseURL)
                                        .textFieldStyle(.roundedBorder)
                                        .controlSize(.small)
                                }
                            }

                            HStack(spacing: 8) {
                                SecureField(
                                    isLocalOllama
                                        ? "本机 Ollama 无需 API Key（可直接保存）"
                                        : (syncAndAI.hasStoredAIKey ? "钥匙串已存有密钥（留空保持）" : "粘贴 API Key（仅存本机钥匙串）"),
                                    text: $aiAPIKeyDraft
                                )
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)

                                Button("保存") {
                                    Task {
                                        let trimmedKey = aiAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                        await syncAndAI.saveAIConfig(draftAIConfig, apiKey: trimmedKey.isEmpty ? nil : trimmedKey, quiet: false)
                                        aiAPIKeyDraft = ""
                                        localActionIsError = syncAndAI.errorMessage != nil
                                        localActionHint = syncAndAI.errorMessage ?? "AI 配置已保存至 macOS 钥匙串"
                                    }
                                }
                                .buttonStyle(SettingsPrimaryButtonStyle())
                                .fixedSize()
                            }
                        }
                    }
                }

                Text("TypeSafe 视觉增强与外部 AI Agent (MCP) 可随时在「设置 → 生态与智能」中按需开启。")
                    .font(CharkleTheme.text(.caption))
                    .foregroundStyle(.tertiary)

                inlineFeedbackPill
            }
        )
    }

    // MARK: - Step 4: Appearance, App Icon & Default Gallery Layout (Aligned with GeneralSettingsPane)

    private var workspaceStep: some View {
        twoColumnStepLayout(
            hero: {
                VStack(spacing: 14) {
                    stepHeroIconDisc(iconName: "gallery", accentHex: "#D96B43")

                    galleryLayoutMiniPreview(mode: coordinator.galleryLayoutMode)
                        .padding(12)
                        .background(cardBackground, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous)
                                .strokeBorder(SettingsPalette.border(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                        )
                        .animation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion), value: coordinator.galleryLayoutMode)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(pedestalBackground, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous)
                        .strokeBorder(SettingsPalette.border(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                )
            },
            content: {
                stepHeading(
                    title: "挑选顺眼的图标与画廊排布",
                    subtitle: "点选立即生效，程序坞图标与主画布默认排布会实时同步。保持默认可直接跳过。",
                    optionalTag: "可选 · 可跳过"
                )

                // 1. App Icon Variant Choice Cards (matching GeneralSettingsPane)
                VStack(alignment: .leading, spacing: 7) {
                    Text("应用与程序坞图标")
                        .font(CharkleTheme.text(.caption, weight: .medium))
                        .foregroundStyle(SettingsPalette.sectionLabel(for: colorScheme))

                    HStack(spacing: 10) {
                        ForEach(CharkleAppIconVariant.allCases) { variant in
                            let selected = appIconManager.currentVariant == variant
                            Button {
                                withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                                    appIconManager.select(variant)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack(alignment: .topTrailing) {
                                        if let img = appIconManager.previewImage(for: variant) {
                                            Image(nsImage: img)
                                                .resizable()
                                                .interpolation(.high)
                                                .aspectRatio(contentMode: .fit)
                                                .frame(width: 46, height: 46)
                                                .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverInner, style: .continuous))
                                                .shadow(color: Color.black.opacity(0.15), radius: 5, y: 2)
                                        }
                                        if selected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(
                                                    colorScheme == .dark ? Color.black : Color.white,
                                                    colorScheme == .dark ? Color.white : Color(charkleHex: "#18191D")
                                                )
                                                .offset(x: 4, y: -4)
                                        }
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(variant.title)
                                            .font(CharkleTheme.text(.body, weight: selected ? .semibold : .medium))
                                            .foregroundStyle(.primary)
                                        Text(variant.subtitle)
                                            .font(CharkleTheme.text(.caption))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(12)
                                .background(
                                    selected ? selectedFillColor : cardBackground,
                                    in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous)
                                        .strokeBorder(
                                            selected ? selectedStrokeColor : SettingsPalette.border(for: colorScheme),
                                            lineWidth: selected ? 1.5 : CharkleTheme.hairlineWidth
                                        )
                                )
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                        }
                    }
                }

                // 2. Default Gallery Layout Choice Cards
                VStack(alignment: .leading, spacing: 7) {
                    Text("画廊默认排布")
                        .font(CharkleTheme.text(.caption, weight: .medium))
                        .foregroundStyle(SettingsPalette.sectionLabel(for: colorScheme))

                    HStack(spacing: 10) {
                        galleryModeCard(
                            mode: .verticalMasonry,
                            title: "纵向瀑布流",
                            subtitle: "保留原比例，高密度扫图",
                            iconName: "masonry-vertical"
                        )
                        galleryModeCard(
                            mode: .horizontalJustified,
                            title: "横向等高行",
                            subtitle: "行高齐平，节奏工整",
                            iconName: "masonry-horizontal"
                        )
                        galleryModeCard(
                            mode: .galleryFilmstrip,
                            title: "画廊视图",
                            subtitle: "大图直览 + 翻转缩放",
                            iconName: "quicklook"
                        )
                    }
                }

                // 3. Compact Sidebar Option
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启动时默认收起侧边栏为精简图标栏")
                            .font(CharkleTheme.text(.body, weight: .medium))
                        Text("随时可用 ⌘\\ 一键展开或收起，左侧底部齿轮按钮可随时打开设置")
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { coordinator.isSidebarCollapsed },
                        set: { coordinator.isSidebarCollapsed = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(cardBackground, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous)
                        .strokeBorder(SettingsPalette.border(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                )
            }
        )
    }

    private func galleryModeCard(
        mode: GalleryLayoutMode,
        title: String,
        subtitle: String,
        iconName: String
    ) -> some View {
        let selected = coordinator.galleryLayoutMode == mode
        return Button {
            withAnimation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion)) {
                coordinator.galleryLayoutMode = mode
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CharkleIcon(iconName, style: .duotone, size: 17, isActive: selected)
                    Spacer()
                    radioIndicator(isSelected: selected)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(CharkleTheme.text(.body, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? selectedFillColor : cardBackground, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous)
                    .strokeBorder(
                        selected ? selectedStrokeColor : SettingsPalette.border(for: colorScheme),
                        lineWidth: selected ? 1.5 : CharkleTheme.hairlineWidth
                    )
            )
        }
        .buttonStyle(CharkleTactileButtonStyle())
    }

    private func galleryLayoutMiniPreview(mode: GalleryLayoutMode) -> some View {
        let accent = Color(charkleHex: "#D96B43")
        let tile = Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.09)
        return VStack(alignment: .leading, spacing: 7) {
            Text("视图预览 · \(mode.localizedLabel)")
                .font(CharkleTheme.text(.caption, weight: .semibold))
                .foregroundStyle(.secondary)

            Group {
                switch mode {
                case .verticalMasonry:
                    HStack(alignment: .top, spacing: 6) {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous).fill(accent.opacity(0.45)).frame(height: 46)
                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous).fill(tile).frame(height: 30)
                        }
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous).fill(tile).frame(height: 28)
                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous).fill(tile).frame(height: 48)
                        }
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous).fill(tile).frame(height: 38)
                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous).fill(accent.opacity(0.28)).frame(height: 38)
                        }
                    }
                case .horizontalJustified:
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous).fill(accent.opacity(0.45)).frame(width: 68, height: 37)
                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous).fill(tile).frame(maxWidth: .infinity, minHeight: 37, maxHeight: 37)
                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous).fill(tile).frame(width: 38, height: 37)
                        }
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous).fill(tile).frame(width: 44, height: 37)
                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous).fill(accent.opacity(0.28)).frame(maxWidth: .infinity, minHeight: 37, maxHeight: 37)
                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous).fill(tile).frame(width: 56, height: 37)
                        }
                    }
                case .galleryFilmstrip:
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
                            .fill(accent.opacity(0.42))
                            .frame(height: 58)
                        HStack(spacing: 5) {
                            ForEach(0..<5, id: \.self) { i in
                                RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous)
                                    .fill(i == 2 ? accent : tile)
                                    .frame(height: 16)
                            }
                        }
                    }
                case .ringGallery:
                    HStack(alignment: .center, spacing: 6) {
                        RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous)
                            .fill(tile.opacity(0.65))
                            .frame(width: 26, height: 50)
                        RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
                            .fill(tile)
                            .frame(width: 34, height: 64)
                        RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
                            .fill(accent.opacity(0.45))
                            .frame(width: 44, height: 78)
                        RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
                            .fill(tile)
                            .frame(width: 34, height: 64)
                        RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous)
                            .fill(tile.opacity(0.65))
                            .frame(width: 26, height: 50)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 82)
        }
    }

    // MARK: - Step 5: Ready Summary & Completion Shockwave Glow

    private var readyStep: some View {
        let storageSummary: String = switch draftSyncConfig.mode {
        case .localOnly: "纯本地文件夹"
        case .iCloudDrive: "iCloud Drive"
        case .directAPIWithGDirect, .gdirectMount:
            syncAndAI.syncStatus.account?.email ?? "Google Drive（待登录）"
        case .webDAV:
            draftSyncConfig.webDAVServerURL.isEmpty ? "WebDAV（待填写）" : "WebDAV 云盘"
        }

        let captureSummary: String = {
            let notchPart = coordinator.notchShelfEnabled
                ? "刘海 → \(coordinator.defaultNotchTargetMode.localizedTitle)"
                : "刘海已关闭"
            let permPart = hasScreenCapturePermission ? "录屏已授权" : "录屏未开启"
            return "\(notchPart) · \(permPart)"
        }()

        let aiSummary: String = switch draftAIConfig.provider {
        case .disabled: "内置离线 Apple Vision"
        case .chatGPTSubscription:
            syncAndAI.chatGPTSession.status == .connected ? "ChatGPT 已连接" : "ChatGPT（待登录）"
        case .gemini:
            syncAndAI.hasStoredAIKey ? "Google Gemini 已就绪" : "Gemini（待填密钥）"
        case .openAICompatible:
            (syncAndAI.hasStoredAIKey || draftAIConfig.baseURL.contains("localhost") || draftAIConfig.baseURL.contains("127.0.0.1"))
                ? "\(draftAIConfig.chatModel.isEmpty ? "自定义 API" : draftAIConfig.chatModel) 已就绪"
                : "自定义 API（待填密钥）"
        }

        let workspaceSummary = "\(appIconManager.currentVariant.title)图标 · \(coordinator.galleryLayoutMode.localizedLabel)"

        return VStack(spacing: 20) {
            Spacer(minLength: 4)

            // Hero Ready Seal with radial shockwave ring (one-shot GPU burst)
            ZStack {
                if !reduceMotion {
                    Circle()
                        .strokeBorder(Color(charkleHex: "#3D9970").opacity(readyShockwaveExpanded ? 0.0 : 0.45), lineWidth: 2.5)
                        .frame(width: 78, height: 78)
                        .scaleEffect(readyShockwaveExpanded ? 1.85 : 0.88)
                        .animation(CharkleMotion.onboardingShockwave, value: readyShockwaveExpanded)

                    Circle()
                        .strokeBorder(Color(charkleHex: "#3B74E8").opacity(readyShockwaveExpanded ? 0.0 : 0.25), lineWidth: 1.5)
                        .frame(width: 78, height: 78)
                        .scaleEffect(readyShockwaveExpanded ? 2.25 : 0.92)
                        .animation(CharkleMotion.onboardingShockwave.delay(0.08), value: readyShockwaveExpanded)
                }

                Circle()
                    .fill(Color(charkleHex: "#3D9970").opacity(colorScheme == .dark ? 0.16 : 0.10))
                    .frame(width: 88, height: 88)

                CharkleIcon("ready", style: .layered, size: 64)
                    .scaleEffect(readyShockwaveExpanded || reduceMotion ? 1.0 : 0.88)
                    .animation(CharkleMotion.accessible(CharkleMotion.onboardingDelightSpring, reduced: reduceMotion), value: readyShockwaveExpanded)
            }

            VStack(spacing: 6) {
                Text("一切准备就绪")
                    .font(CharkleTheme.text(.title, weight: .bold))
                    .tracking(-0.35)
                Text("点击任意卡片可回头微调，或随时按 ⌘, 打开设置页继续深度定制。")
                    .font(CharkleTheme.text(.body))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                readySummaryCard(
                    icon: "library",
                    title: "素材库与云同步",
                    value: storageSummary,
                    skipped: skippedSteps.contains(.storage),
                    targetStep: .storage
                )
                readySummaryCard(
                    icon: "notch",
                    title: "刘海浮窗与采集",
                    value: captureSummary,
                    skipped: skippedSteps.contains(.capture),
                    targetStep: .capture
                )
                readySummaryCard(
                    icon: "ai-spark",
                    title: "AI 智能",
                    value: aiSummary,
                    skipped: skippedSteps.contains(.intelligence),
                    targetStep: .intelligence
                )
                readySummaryCard(
                    icon: "gallery",
                    title: "外观与画廊排布",
                    value: workspaceSummary,
                    skipped: skippedSteps.contains(.workspace),
                    targetStep: .workspace
                )
            }
            .padding(.horizontal, 44)

            Spacer(minLength: 4)
        }
    }

    private func readySummaryCard(
        icon: String,
        title: String,
        value: String,
        skipped: Bool,
        targetStep: Step
    ) -> some View {
        Button {
            navigate(to: targetStep)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous)
                        .fill(SettingsPalette.subtleFill(for: colorScheme))
                        .frame(width: 36, height: 36)
                    CharkleIcon(icon, style: .duotone, size: 19, isActive: !skipped)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                        if skipped {
                            Text("已跳过")
                                .font(CharkleTheme.text(.caption, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(SettingsPalette.subtleFill(for: colorScheme), in: Capsule(style: .continuous))
                        }
                    }
                    Text(value)
                        .font(CharkleTheme.text(.body, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(13)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous)
                    .strokeBorder(SettingsPalette.border(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
            )
        }
        .buttonStyle(CharkleTactileButtonStyle())
    }

    // MARK: - Reusable Layout Primitives

    private func twoColumnStepLayout<Hero: View, Content: View>(
        @ViewBuilder hero: () -> Hero,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 22) {
            hero()
                .frame(width: 234)
                .frame(maxHeight: .infinity)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    content()
                }
                .padding(.vertical, 2)
                .padding(.trailing, 2)
                .charkleCleanScrollbars(hidden: true)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(22)
    }

    private func stepHeroPedestal(
        iconName: String,
        accentHex: String,
        badgeText: String,
        caption: String
    ) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 6)
            stepHeroIconDisc(iconName: iconName, accentHex: accentHex)

            Text(badgeText)
                .font(CharkleTheme.text(.caption, weight: .semibold))
                .foregroundStyle(Color(charkleHex: accentHex))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(charkleHex: accentHex).opacity(colorScheme == .dark ? 0.18 : 0.10), in: Capsule(style: .continuous))

            Text(caption)
                .font(CharkleTheme.text(.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pedestalBackground, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous)
                .strokeBorder(SettingsPalette.border(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
        )
    }

    private func stepHeroIconDisc(iconName: String, accentHex: String) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(charkleHex: accentHex).opacity(colorScheme == .dark ? 0.22 : 0.12),
                            .clear
                        ],
                        center: .center,
                        startRadius: 6,
                        endRadius: 52
                    )
                )
                .frame(width: 102, height: 102)

            CharkleIcon(iconName, style: .layered, size: 66)
                .id(iconName)
                .transition(CharkleMotion.originTransition(anchor: .center, scale: 0.92, reduced: reduceMotion))
        }
        .animation(CharkleMotion.accessible(CharkleMotion.onboardingDelightSpring, reduced: reduceMotion), value: iconName)
    }

    private func stepHeading(title: String, subtitle: String, optionalTag: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(CharkleTheme.text(.title, weight: .bold))
                    .tracking(-0.3)
                if let optionalTag {
                    Text(optionalTag)
                        .font(CharkleTheme.text(.caption, weight: .medium))
                        .foregroundStyle(SettingsPalette.sectionLabel(for: colorScheme))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(SettingsPalette.subtleFill(for: colorScheme), in: Capsule(style: .continuous))
                }
            }
            Text(subtitle)
                .font(CharkleTheme.text(.body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func radioChoiceCard<Detail: View>(
        title: String,
        badge: String?,
        badgeTint: Color,
        subtitle: String,
        iconName: String,
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        radioChoiceCardCustomIcon(
            title: title,
            badge: badge,
            badgeTint: badgeTint,
            subtitle: subtitle,
            isSelected: isSelected,
            icon: {
                CharkleIcon(iconName, style: .duotone, size: 17, color: isSelected ? .primary : .secondary, isActive: isSelected)
            },
            action: action,
            detail: detail
        )
    }

    private func radioChoiceCardCustomIcon<Icon: View, Detail: View>(
        title: String,
        badge: String?,
        badgeTint: Color,
        subtitle: String,
        isSelected: Bool,
        @ViewBuilder icon: () -> Icon,
        action: @escaping () -> Void,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous)
                            .fill(SettingsPalette.subtleFill(for: colorScheme))
                            .frame(width: 34, height: 34)
                        icon()
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(CharkleTheme.text(.body, weight: .semibold))
                                .foregroundStyle(.primary)
                            if let badge {
                                SettingsStatusBadge(badge, tint: badgeTint)
                            }
                        }
                        Text(subtitle)
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 6)
                    radioIndicator(isSelected: isSelected)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected {
                detail()
                    .padding(.leading, 46)
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : -4)))
            }
        }
        .padding(13)
        .background(isSelected ? selectedFillColor : cardBackground, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous)
                .strokeBorder(
                    isSelected ? selectedStrokeColor : SettingsPalette.border(for: colorScheme),
                    lineWidth: isSelected ? 1.5 : CharkleTheme.hairlineWidth
                )
        )
        .animation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion), value: isSelected)
    }

    private func radioIndicator(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .strokeBorder(
                    isSelected ? Color.primary : Color.primary.opacity(0.24),
                    lineWidth: isSelected ? 2 : 1.25
                )
                .frame(width: 17, height: 17)
            if isSelected {
                Circle()
                    .fill(Color.primary)
                    .frame(width: 7.5, height: 7.5)
                    .transition(CharkleMotion.originTransition(anchor: .center, scale: 0.86, reduced: reduceMotion))
            }
        }
    }

    private func instantSwitchRow(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        disabled: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(CharkleTheme.text(.body, weight: .medium))
                    .foregroundStyle(disabled ? .secondary : .primary)
                Text(subtitle)
                    .font(CharkleTheme.text(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(disabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .opacity(disabled ? 0.55 : 1.0)
    }

    private func offlineFeatureBullet(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(SettingsPalette.positiveInk(for: colorScheme))
            Text(text)
                .font(CharkleTheme.text(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var inlineFeedbackPill: some View {
        if let hint = localActionHint {
            let tint = localActionIsError
                ? SettingsPalette.warningInk(for: colorScheme)
                : SettingsPalette.positiveInk(for: colorScheme)
            HStack(spacing: 7) {
                Image(systemName: localActionIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
                Text(hint)
                    .font(CharkleTheme.text(.caption, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint.opacity(colorScheme == .dark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous)
                    .strokeBorder(tint.opacity(0.22), lineWidth: CharkleTheme.hairlineWidth)
            )
            .transition(CharkleMotion.originTransition(anchor: .top, scale: 0.97, reduced: reduceMotion))
        }
    }

    // MARK: - Actions & Persistence

    private func navigate(to step: Step) {
        guard step != currentStep else { return }
        stepDirection = step.rawValue > currentStep.rawValue ? 1 : -1
        withAnimation(CharkleMotion.accessible(CharkleMotion.onboardingStepSlide, reduced: reduceMotion)) {
            currentStep = step
        }
    }

    private func goNext(skipped: Bool) {
        if skipped {
            skippedSteps.insert(currentStep)
        } else {
            skippedSteps.remove(currentStep)
        }
        guard let next = Step(rawValue: currentStep.rawValue + 1) else {
            finishOnboarding()
            return
        }
        navigate(to: next)
    }

    private func goPrevious() {
        guard let prev = Step(rawValue: currentStep.rawValue - 1) else { return }
        navigate(to: prev)
    }

    private func skipEntireOnboarding() {
        coordinator.showToast("已跳过首次引导 · 随时可在「设置 → 通用」重新查看", icon: "forward.end.fill")
        onFinish()
    }

    private func finishOnboarding() {
        onFinish()
    }

    private func finishAndOpenSettings(_ tab: CharkleSettingsTab) {
        onFinish()
        onOpenSettings(tab)
    }

    private func triggerReadyShockwave() {
        readyShockwaveExpanded = false
        guard !reduceMotion else {
            readyShockwaveExpanded = true
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            readyShockwaveExpanded = true
        }
    }

    private func selectStorageMode(_ mode: DriveTransportMode) {
        skippedSteps.remove(.storage)
        draftSyncConfig.mode = mode
        Task {
            await syncAndAI.saveSyncConfig(draftSyncConfig, quiet: true)
        }
    }

    private func pickLocalFolder() {
        if let picked = SettingsHelpers.pickLocalDirectory(initialPath: draftSyncConfig.localLibraryPath) {
            skippedSteps.remove(.storage)
            draftSyncConfig.mode = .localOnly
            draftSyncConfig.localLibraryPath = picked
            Task {
                await syncAndAI.saveSyncConfig(draftSyncConfig, quiet: true)
                localActionIsError = false
                localActionHint = "已将本地存储目录设为：\((picked as NSString).lastPathComponent)"
            }
        }
    }

    private func selectAIProvider(_ provider: CloudAIProviderKind) {
        skippedSteps.remove(.intelligence)
        draftAIConfig.provider = provider
        if provider == .gemini && draftAIConfig.chatModel.isEmpty {
            draftAIConfig.chatModel = "gemini-2.5-flash"
            draftAIConfig.baseURL = "https://generativelanguage.googleapis.com"
        }
        Task {
            await syncAndAI.saveAIConfig(draftAIConfig, apiKey: nil, quiet: true)
            await syncAndAI.refreshAIKeyPresence(for: provider)
        }
    }

    private func applyAIPreset(_ preset: QuickAIPreset) {
        skippedSteps.remove(.intelligence)
        draftAIConfig.provider = preset.provider
        draftAIConfig.customEndpointFormat = preset.format
        draftAIConfig.baseURL = preset.baseURL
        draftAIConfig.chatModel = preset.chatModel
        draftAIConfig.embeddingModel = preset.embeddingModel
        Task {
            await syncAndAI.saveAIConfig(draftAIConfig, apiKey: nil, quiet: true)
            await syncAndAI.refreshAIKeyPresence(for: preset.provider)
        }
    }

    private func isPresetActive(_ preset: QuickAIPreset) -> Bool {
        if preset.provider == .gemini {
            return draftAIConfig.provider == .gemini
        }
        return draftAIConfig.provider == .openAICompatible &&
            draftAIConfig.baseURL.lowercased().contains(
                URL(string: preset.baseURL)?.host?.lowercased() ?? preset.baseURL.lowercased()
            )
    }
}
