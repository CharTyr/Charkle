import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI

/// Interactive 3D Outside Ring Gallery powered by Metal (`RingGalleryMetalSurface`) with:
/// - Eye-level curved 22-card ring, per-pixel zero-shimmer depth-of-field blur, superellipse-4 corners & far fade
/// - 1:1 pointer drag + inertial glide, click-to-center (760ms), press feedback (0.95), arrow stepping & Quick Look
/// - Collapsible live tuning panel tucked behind a bottom-trailing toggle button (Perspective, Depth blur, Far fade, Corner)
public struct GalleryRingView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let assets: [AssetRecord]
    public let folders: [FolderRecord]
    public let boards: [MoodboardSummary]
    public let activeMoodboardID: UUID?
    public let isOverlayPresented: Bool
    public let loader: ThumbnailImageLoader
    @Binding public var selectedAssetIDs: Set<UUID>
    public let topContentInset: CGFloat
    public let onOpenQuickLook: (AssetRecord) -> Void
    public let onMarkOpened: (UUID) -> Void
    public let onCopyAssets: ([UUID]) -> Void
    public let onRevealInFinder: (UUID) -> Void
    public let onAddToMoodboard: ([UUID], UUID?) -> Void
    public let onMoveToFolder: ([UUID], UUID?) -> Void
    public let onTogglePinOffline: ([UUID], Bool) -> Void
    public let onTrashAssets: ([UUID]) -> Void
    public let onRestoreAssets: ([UUID]) -> Void
    public let onFocusedAssetChanged: ((UUID?) -> Void)?

    @State private var params: RingGalleryParameters = .default
    @State private var isTuningPanelExpanded: Bool = false
    @State private var frontAsset: AssetRecord?
    @State private var stepTrigger: Int = 0
    @State private var stepDirection: Int = 0
    @State private var markOpenedTask: Task<Void, Never>?

    private func resolveActiveSelection() -> (asset: AssetRecord, index: Int)? {
        if let frontAsset, let idx = assets.firstIndex(where: { $0.id == frontAsset.id }) {
            return (assets[idx], idx)
        }
        if let selectedID = selectedAssetIDs.first,
           let idx = assets.firstIndex(where: { $0.id == selectedID }) {
            return (assets[idx], idx)
        }
        guard let first = assets.first else { return nil }
        return (first, 0)
    }

    private var activeAsset: AssetRecord? {
        resolveActiveSelection()?.asset
    }

    private var activeIndex: Int? {
        resolveActiveSelection()?.index
    }

    public init(
        assets: [AssetRecord],
        folders: [FolderRecord],
        boards: [MoodboardSummary],
        activeMoodboardID: UUID?,
        isOverlayPresented: Bool,
        loader: ThumbnailImageLoader,
        selectedAssetIDs: Binding<Set<UUID>>,
        topContentInset: CGFloat,
        onOpenQuickLook: @escaping (AssetRecord) -> Void,
        onMarkOpened: @escaping (UUID) -> Void,
        onCopyAssets: @escaping ([UUID]) -> Void,
        onRevealInFinder: @escaping (UUID) -> Void,
        onAddToMoodboard: @escaping ([UUID], UUID?) -> Void,
        onMoveToFolder: @escaping ([UUID], UUID?) -> Void,
        onTogglePinOffline: @escaping ([UUID], Bool) -> Void,
        onTrashAssets: @escaping ([UUID]) -> Void,
        onRestoreAssets: @escaping ([UUID]) -> Void,
        onFocusedAssetChanged: ((UUID?) -> Void)? = nil
    ) {
        self.assets = assets
        self.folders = folders
        self.boards = boards
        self.activeMoodboardID = activeMoodboardID
        self.isOverlayPresented = isOverlayPresented
        self.loader = loader
        self._selectedAssetIDs = selectedAssetIDs
        self.topContentInset = topContentInset
        self.onOpenQuickLook = onOpenQuickLook
        self.onMarkOpened = onMarkOpened
        self.onCopyAssets = onCopyAssets
        self.onRevealInFinder = onRevealInFinder
        self.onAddToMoodboard = onAddToMoodboard
        self.onMoveToFolder = onMoveToFolder
        self.onTogglePinOffline = onTogglePinOffline
        self.onTrashAssets = onTrashAssets
        self.onRestoreAssets = onRestoreAssets
        self.onFocusedAssetChanged = onFocusedAssetChanged
    }

    public var body: some View {
        ZStack {
            CharkleTheme.galleryGround(for: colorScheme)
                .ignoresSafeArea()

            let invalidationVersion = loader.invalidationVersion
            RingGalleryMetalSurface(
                assets: assets,
                selectedAssetID: selectedAssetIDs.first,
                loader: loader,
                loaderInvalidationVersion: invalidationVersion,
                params: params,
                isDarkMode: colorScheme == .dark,
                reduceMotion: reduceMotion,
                isOverlayPresented: isOverlayPresented,
                topSafeInset: topContentInset,
                stepTrigger: stepTrigger,
                stepDirection: stepDirection,
                callbacks: RingGalleryInteractionCallbacks(
                    onFrontAssetChanged: { asset in
                        frontAsset = asset
                        onFocusedAssetChanged?(asset?.id)
                        if let asset {
                            if selectedAssetIDs != [asset.id] {
                                selectedAssetIDs = [asset.id]
                            }
                            let targetID = asset.id
                            markOpenedTask?.cancel()
                            markOpenedTask = Task {
                                try? await Task.sleep(for: .milliseconds(220))
                                guard !Task.isCancelled else { return }
                                onMarkOpened(targetID)
                            }
                        } else {
                            markOpenedTask?.cancel()
                            markOpenedTask = nil
                        }
                    },
                    onOpenQuickLook: { asset in
                        selectedAssetIDs = [asset.id]
                        onOpenQuickLook(asset)
                    },
                    onContextMenuRequest: { asset, hostView, point in
                        selectedAssetIDs = [asset.id]
                        presentContextMenu(for: asset, in: hostView, at: point)
                    }
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                onFocusedAssetChanged?(resolveActiveSelection()?.asset.id)
            }
            .onDisappear {
                markOpenedTask?.cancel()
                markOpenedTask = nil
                onFocusedAssetChanged?(nil)
            }

            // Bottom Navigation Capsule & Collapsible Tuning Control
            let resolvedActive = resolveActiveSelection()
            VStack {
                Spacer()
                ZStack(alignment: .bottomTrailing) {
                    if let resolvedActive {
                        bottomNavigationCapsule(asset: resolvedActive.asset, activeIndex: resolvedActive.index)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    VStack(alignment: .trailing, spacing: 10) {
                        if isTuningPanelExpanded {
                            tuningPanelCard
                                .transition(
                                    CharkleMotion.originTransition(
                                        anchor: .bottomTrailing,
                                        scale: 0.95,
                                        reduced: reduceMotion
                                    )
                                )
                        }

                        Button {
                            withAnimation(
                                CharkleMotion.enterExit(
                                    !isTuningPanelExpanded,
                                    enter: CharkleMotion.popoverEnter,
                                    exit: CharkleMotion.popoverExit,
                                    reduced: reduceMotion
                                )
                            ) {
                                isTuningPanelExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 12, weight: .semibold))
                                if isTuningPanelExpanded {
                                    Text("收起")
                                        .font(.system(size: 11.5, weight: .medium))
                                }
                            }
                            .foregroundStyle(isTuningPanelExpanded ? Color.accentColor : .primary.opacity(0.84))
                            .padding(.horizontal, isTuningPanelExpanded ? 11 : 0)
                            .frame(minWidth: 34, minHeight: 34)
                            .charkleLiquidGlass(.regular, in: Capsule(style: .continuous), interactive: true)
                        }
                        .buttonStyle(CharkleTactileButtonStyle())
                        .help("调整环形透视、景深模糊、远端淡出与圆角参数")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
            .animation(
                CharkleMotion.enterExit(
                    isTuningPanelExpanded,
                    enter: CharkleMotion.popoverEnter,
                    exit: CharkleMotion.popoverExit,
                    reduced: reduceMotion
                ),
                value: isTuningPanelExpanded
            )
        }
        .overlay {
            if isTuningPanelExpanded {
                WindowKeyEventBridge { event, hostWindow in
                    let primaryModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                    guard event.keyCode == 53,
                          primaryModifiers.isEmpty,
                          event.window === hostWindow,
                          !isOverlayPresented else {
                        return event
                    }
                    withAnimation(CharkleMotion.accessible(CharkleMotion.popoverExit, reduced: reduceMotion)) {
                        isTuningPanelExpanded = false
                    }
                    return nil
                }
                .allowsHitTesting(false)
            }
        }
        .onKeyPress(.escape) {
            guard isTuningPanelExpanded else { return .ignored }
            withAnimation(CharkleMotion.accessible(CharkleMotion.popoverExit, reduced: reduceMotion)) {
                isTuningPanelExpanded = false
            }
            return .handled
        }
    }

    // MARK: - Bottom Center Minimal Navigation Pill

    private func bottomNavigationCapsule(asset: AssetRecord, activeIndex: Int?) -> some View {
        HStack(spacing: 8) {
            Button {
                triggerStep(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.8))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(CharkleTactileButtonStyle())
            .disabled(assets.count <= 1)
            .help("上一张 (←)")

            VStack(spacing: 1) {
                Text(asset.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 200)
                if let idx = activeIndex {
                    Text("\(idx + 1) / \(assets.count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                triggerStep(1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.8))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(CharkleTactileButtonStyle())
            .disabled(assets.count <= 1)
            .help("下一张 (→)")

            Rectangle()
                .fill(CharkleTheme.hairline(for: colorScheme))
                .frame(width: 1, height: 16)

            Button {
                onOpenQuickLook(asset)
            } label: {
                HStack(spacing: 4) {
                    if asset.isExternalWebLink {
                        Image(systemName: "safari")
                            .font(.system(size: 12, weight: .medium))
                        Text("浏览器打开")
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                    } else {
                        CharkleIcon("quicklook", style: .duotone, size: 13)
                        Text("沉浸预览")
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Capsule())
            }
            .buttonStyle(CharkleTactileButtonStyle())
            .help(asset.isExternalWebLink ? "在默认浏览器中打开 (Space)" : "全屏沉浸预览 (Space)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .charkleLiquidGlass(.regular, in: Capsule(style: .continuous))
    }

    // MARK: - Collapsible Live Tuning Panel (Outside Defaults + Reset)

    private var tuningPanelCard: some View {
        let isModified = params != .default
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("环形画廊参数")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Button("重置默认") {
                    params = .default
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isModified ? Color.accentColor : .secondary)
                .buttonStyle(.plain)
                .disabled(!isModified)
            }

            Rectangle()
                .fill(CharkleTheme.hairline(for: colorScheme))
                .frame(height: 0.75)

            sliderRow(
                title: "透视距离",
                valueText: "\(Int(params.perspective.rounded()))px",
                value: Binding(
                    get: { params.perspective },
                    set: { params.perspective = $0 }
                ),
                range: 900...2400,
                step: 10
            )

            sliderRow(
                title: "景深模糊",
                valueText: "\(Int(params.depthBlur.rounded()))px",
                value: Binding(
                    get: { params.depthBlur },
                    set: { params.depthBlur = $0 }
                ),
                range: 0...30,
                step: 1
            )

            sliderRow(
                title: "远端淡出",
                valueText: "\(Int((params.farFade * 100).rounded()))%",
                value: Binding(
                    get: { params.farFade * 100 },
                    set: { params.farFade = $0 / 100.0 }
                ),
                range: 0...100,
                step: 1
            )

            sliderRow(
                title: "卡片圆角",
                valueText: "\(Int(params.cornerRadius.rounded()))px",
                value: Binding(
                    get: { params.cornerRadius },
                    set: { params.cornerRadius = $0 }
                ),
                range: 0...60,
                step: 1
            )
        }
        .padding(14)
        .frame(width: 276)
        .charkleLiquidGlass(.regular, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverOuter, style: .continuous))
    }

    private func sliderRow(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(valueText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            Slider(value: value, in: range, step: step)
                .controlSize(.small)
        }
    }

    private func triggerStep(_ delta: Int) {
        stepDirection = delta
        stepTrigger &+= 1
    }

    // MARK: - Native Right-Click Context Menu for Any Card in the Ring

    private func presentContextMenu(for asset: AssetRecord, in view: NSView, at point: NSPoint) {
        let menu = NSMenu()
        let addAction: (String, String?, @escaping () -> Void) -> NSMenuItem = { title, symbol, handler in
            let target = RingMenuActionTarget(handler: handler)
            let item = NSMenuItem(title: title, action: #selector(RingMenuActionTarget.invokeHandler), keyEquivalent: "")
            item.target = target
            item.representedObject = target
            if let symbol {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            return item
        }

        if asset.isExternalWebLink {
            menu.addItem(addAction("在默认浏览器中打开 (Space)", "safari") {
                onOpenQuickLook(asset)
            })
        } else {
            menu.addItem(addAction("沉浸预览 (Space)", "eye") {
                onOpenQuickLook(asset)
            })
        }
        menu.addItem(.separator())

        if asset.isTrashed {
            menu.addItem(addAction("放回原处", "arrow.uturn.backward") {
                onRestoreAssets([asset.id])
            })
        } else {
            // Add to Moodboard submenu
            let boardItem = NSMenuItem(title: "加入情绪板", action: nil, keyEquivalent: "")
            boardItem.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
            let boardSub = NSMenu()
            for board in boards {
                boardSub.addItem(addAction(board.title, nil) {
                    onAddToMoodboard([asset.id], board.id)
                })
            }
            if !boards.isEmpty { boardSub.addItem(.separator()) }
            boardSub.addItem(addAction("用此素材创建新情绪板…", "sparkles") {
                onAddToMoodboard([asset.id], nil)
            })
            boardItem.submenu = boardSub
            menu.addItem(boardItem)

            // Move to Folder submenu
            let folderItem = NSMenuItem(title: "移动到文件夹", action: nil, keyEquivalent: "")
            folderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            let folderSub = NSMenu()
            folderSub.addItem(addAction("收件箱", "tray") {
                onMoveToFolder([asset.id], nil)
            })
            if !folders.isEmpty {
                folderSub.addItem(.separator())
                for node in FolderHierarchyNode.flattened(from: folders) {
                    let prefix = node.depth > 0 ? String(repeating: "  ", count: node.depth) + "↳ " : ""
                    folderSub.addItem(addAction("\(prefix)\(node.folder.name)", nil) {
                        onMoveToFolder([asset.id], node.folder.id)
                    })
                }
            }
            folderItem.submenu = folderSub
            menu.addItem(folderItem)

            menu.addItem(.separator())
            menu.addItem(addAction("拷贝素材", "doc.on.doc") {
                onCopyAssets([asset.id])
            })
            menu.addItem(addAction("在访达中显示", "folder") {
                onRevealInFinder(asset.id)
            })
            menu.addItem(addAction(asset.pinnedOffline ? "取消始终保留在本地" : "始终保留在本地", asset.pinnedOffline ? "icloud" : "arrow.down.circle") {
                onTogglePinOffline([asset.id], !asset.pinnedOffline)
            })
            menu.addItem(.separator())
            menu.addItem(addAction("移至废纸篓", "trash") {
                onTrashAssets([asset.id])
            })
        }

        menu.popUp(positioning: nil, at: point, in: view)
    }
}

@MainActor
private final class RingMenuActionTarget: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init()
    }

    @objc func invokeHandler() {
        handler()
    }
}
