import AppKit
import CharkleCore
import SwiftUI

// MARK: - Calm Theme Mapping for Notes & Group Frames

public enum NoteStylePalette {
    public static func colors(for style: NoteStyle) -> (background: Color, foreground: Color, border: Color) {
        switch style {
        case .paper:
            return (Color(charkleHex: "#FFFFFF"), Color(charkleHex: "#1D1F23"), Color.black.opacity(0.09))
        case .ink:
            return (Color(charkleHex: "#1D1F24"), Color(charkleHex: "#F1F2F4"), Color.white.opacity(0.14))
        case .warm:
            return (Color(charkleHex: "#F7F0E4"), Color(charkleHex: "#392F22"), Color(charkleHex: "#C9B79C").opacity(0.45))
        case .sage:
            return (Color(charkleHex: "#E8F0EA"), Color(charkleHex: "#203227"), Color(charkleHex: "#9AB5A3").opacity(0.45))
        case .slate:
            return (Color(charkleHex: "#E9EEF3"), Color(charkleHex: "#1F2B36"), Color(charkleHex: "#9EB0C2").opacity(0.45))
        }
    }

    public static func label(for style: NoteStyle) -> String {
        switch style {
        case .paper: "纸白"
        case .ink: "墨黑"
        case .warm: "暖沙"
        case .sage: "鼠尾草"
        case .slate: "岩灰"
        }
    }
}

public enum GroupTintPalette {
    public static func accent(for tint: GroupTint) -> Color {
        switch tint {
        case .neutral: Color(charkleHex: "#7D838B")
        case .sand: Color(charkleHex: "#B5956B")
        case .sage: Color(charkleHex: "#6B8E76")
        case .slate: Color(charkleHex: "#627A94")
        case .terracotta: Color(charkleHex: "#BA6B55")
        case .ocean: Color(charkleHex: "#4D7E97")
        }
    }

    public static func label(for tint: GroupTint) -> String {
        switch tint {
        case .neutral: "中性灰"
        case .sand: "暖沙"
        case .sage: "青苔"
        case .slate: "板岩"
        case .terracotta: "陶土"
        case .ocean: "深海"
        }
    }
}

// MARK: - Board Palette Strip (Top Editorial Bar)

public struct BoardPaletteHeaderStrip: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let colors: [LabColor]
    public let onCopyHex: (String) -> Void
    public let onSearchColor: (String) -> Void

    @State private var copiedHex: String?

    public init(
        colors: [LabColor],
        onCopyHex: @escaping (String) -> Void,
        onSearchColor: @escaping (String) -> Void
    ) {
        self.colors = colors
        self.onCopyHex = onCopyHex
        self.onSearchColor = onSearchColor
    }

    public var body: some View {
        if !colors.isEmpty {
            HStack(spacing: 6) {
                Text("板内色卡")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 2)

                ForEach(colors.prefix(7), id: \.hex) { swatch in
                    let hex = swatch.hex.uppercased()
                    let isLight = Color.charkleIsLightHex(hex)
                    Button {
                        onCopyHex(hex)
                        withAnimation(CanvasMotion.accessible(CanvasMotion.microOvershoot, reduced: reduceMotion)) {
                            copiedHex = hex
                        }
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            if copiedHex == hex {
                                withAnimation(CanvasMotion.accessible(CanvasMotion.exitSm, reduced: reduceMotion)) {
                                    copiedHex = nil
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color(charkleHex: hex))
                                .frame(width: 14, height: 14)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(isLight ? Color.black.opacity(0.14) : Color.white.opacity(0.22), lineWidth: 0.75)
                                )
                            Text(copiedHex == hex ? "已复制" : hex)
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary.opacity(0.84))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            CanvasSurface.elevated(for: colorScheme).opacity(0.88),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(CanvasSurface.hairline(for: colorScheme), lineWidth: 0.75)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("复制 HEX \(hex)") { onCopyHex(hex) }
                        Button("以此色筛选素材库") { onSearchColor(hex) }
                    }
                    .help("点击复制 \(hex)，右键以此色检索素材库")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .canvasLiquidGlass(in: Capsule(style: .continuous))
        }
    }
}

// MARK: - Asset Node Card (Auto Editorial & Freeform)

struct BoardAssetNodeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let node: BoardNode
    let asset: AssetRecord?
    let loader: ThumbnailImageLoader
    let isSelected: Bool
    let isSwapTarget: Bool
    let isAutoEditorial: Bool
    let heroNamespace: Namespace.ID
    let onToggleHero: () -> Void
    let onTriggerSwap: () -> Void
    let onOpenQuickLook: () -> Void
    let onRevealInLibrary: () -> Void
    let onRevealInFinder: () -> Void
    let onCopy: () -> Void
    let onCut: () -> Void
    let onPaste: () -> Void
    let onRotateBy: (Double) -> Void
    let onResetRotation: () -> Void
    let onFlipHorizontal: () -> Void
    let onFlipVertical: () -> Void
    let onSmartFocusSubject: () -> Void
    let onSemanticCropPrompt: () -> Void
    let onVisualMatchCrop: () -> Void
    let onCleanContentCrop: () -> Void
    let onPinpointAnnotate: () -> Void
    let onResetCrop: () -> Void
    let onToggleLock: () -> Void
    let onDelete: () -> Void

    @State private var isHovered: Bool = false

    private var weight: Int {
        if case .assetRef(_, _, let w, _) = node.kind { return w }
        return 1
    }

    private var crop: NormalizedCropRect? {
        if case .assetRef(_, let c, _, _) = node.kind { return c }
        return nil
    }

    private let outerRadius: CGFloat = 12
    private var innerBadgeRadius: CGFloat { 6 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
        ZStack {
            if let asset {
                AssetThumbnailSurface(
                    asset: asset,
                    loader: loader,
                    tier: weight >= 2 ? .preview1400 : .grid520,
                    cornerRadius: outerRadius,
                    isHovered: isHovered,
                    crop: crop
                )
                .scaleEffect(
                    x: node.flipHorizontal ? -1 : 1,
                    y: node.flipVertical ? -1 : 1
                )
                .matchedGeometryEffect(id: "board-\(node.id.uuidString)", in: heroNamespace)
            } else {
                ZStack {
                    CanvasSurface.subtleCard(for: colorScheme)
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                        Text("素材不可用")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .clipShape(shape)
            }

            // Hover quick controls (clean, restrained, never permanent clutter)
            if isHovered || isSwapTarget {
                VStack {
                    HStack(spacing: 6) {
                        if weight >= 2 || isAutoEditorial {
                            Button(action: onToggleHero) {
                                HStack(spacing: 3) {
                                    Image(systemName: weight >= 2 ? "star.fill" : "star")
                                        .font(.system(size: 9.5, weight: .semibold))
                                    Text(weight >= 2 ? "主图 2×" : "设为主图")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(
                                    weight >= 2 ? Color.accentColor : Color.black.opacity(0.58),
                                    in: RoundedRectangle(cornerRadius: innerBadgeRadius, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                            .help("切换 2× 跨列主图权重")
                        }

                        Spacer(minLength: 4)

                        Button(action: onTriggerSwap) {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 9.5, weight: .semibold))
                                Text("换一张")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(
                                isSwapTarget ? Color.accentColor : Color.black.opacity(0.58),
                                in: RoundedRectangle(cornerRadius: innerBadgeRadius, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("打开右侧候选池原地替换这张图")
                    }
                    .padding(6)

                    Spacer()

                    HStack {
                        if node.isLocked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(Color.black.opacity(0.52), in: Circle())
                        }
                        if let crop, crop != .full {
                            Button(action: onResetCrop) {
                                HStack(spacing: 3) {
                                    Image(systemName: "viewfinder")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text("局部取景 · 还原")
                                        .font(.system(size: 9.5, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: innerBadgeRadius, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("点击还原完整画面（非破坏性裁切）")
                        }
                        Spacer()
                        Button(action: onOpenQuickLook) {
                            Image(systemName: asset?.isExternalWebLink == true ? "safari" : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(Color.black.opacity(0.54), in: RoundedRectangle(cornerRadius: innerBadgeRadius, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(asset?.isExternalWebLink == true ? "在默认浏览器中打开 (Space)" : "快速预览 (Space)")
                    }
                    .padding(6)
                }
                .transition(.opacity)
            }
        }
        .background(CanvasSurface.subtleCard(for: colorScheme), in: shape)
        .overlay {
            if isSwapTarget {
                shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
            } else if isSelected {
                shape.strokeBorder(Color.accentColor, lineWidth: 2.5)
            } else {
                shape.strokeBorder(CanvasSurface.hairline(for: colorScheme), lineWidth: 0.75)
            }
        }
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.26 : 0.075),
            radius: isSelected ? 10 : 4,
            y: isSelected ? 4 : 2
        )
        .contentShape(shape)
        .onHover { hovering in
            withAnimation(CanvasMotion.accessible(CanvasMotion.hoverPress, reduced: reduceMotion)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            Button(asset?.isExternalWebLink == true ? "在默认浏览器中打开 (Space)" : "快速预览 (Space)") { onOpenQuickLook() }
            if asset != nil {
                Button {
                    onRevealInLibrary()
                } label: {
                    Label("在素材库中定位", systemImage: "scope")
                }
                Button {
                    onRevealInFinder()
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                }
            }
            Button("从候选池换一张…") { onTriggerSwap() }
            if asset != nil {
                Menu {
                    Button {
                        onSmartFocusSubject()
                    } label: {
                        Label("聚焦画面主体", systemImage: "viewfinder")
                    }
                    Button {
                        onSemanticCropPrompt()
                    } label: {
                        Label("一句话语义裁切…", systemImage: "text.viewfinder")
                    }
                    Button {
                        onVisualMatchCrop()
                    } label: {
                        Label("以图找局部（按参考图裁切）…", systemImage: "photo.on.rectangle.angled")
                    }
                    Button {
                        onCleanContentCrop()
                    } label: {
                        Label("自动去噪裁净", systemImage: "crop")
                    }
                    Divider()
                    Button {
                        onPinpointAnnotate()
                    } label: {
                        Label("指物批注（定位 + 箭头便签）…", systemImage: "scope")
                    }
                    if let crop, crop != .full {
                        Divider()
                        Button {
                            onResetCrop()
                        } label: {
                            Label("还原完整画面", systemImage: "arrow.uturn.backward")
                        }
                    }
                } label: {
                    Label("智能取景与标注 (Jev Box)", systemImage: "viewfinder.circle")
                }
            }
            Divider()
            if asset != nil {
                Button {
                    onCopy()
                } label: {
                    Label("拷贝", systemImage: "doc.on.doc")
                }
                Button {
                    onCut()
                } label: {
                    Label("剪切", systemImage: "scissors")
                }
            }
            Button {
                onPaste()
            } label: {
                Label("粘贴到情绪板", systemImage: "doc.on.clipboard")
            }
            Divider()
            Button("顺时针旋转 90° (R)") { onRotateBy(90) }
            Button("逆时针旋转 90° (⇧R)") { onRotateBy(-90) }
            if abs(node.rotationDegrees) > 0.1 {
                Button("重置旋转角度 (0°)") { onResetRotation() }
            }
            Button(node.flipHorizontal ? "取消水平翻转 (⇧H)" : "水平翻转 (⇧H)") { onFlipHorizontal() }
            Button(node.flipVertical ? "取消上下翻转 (⇧V)" : "上下翻转 (⇧V)") { onFlipVertical() }
            Divider()
            Button(weight >= 2 ? "取消主图 2× 权重" : "设为主图 2× 权重") { onToggleHero() }
            Button(node.isLocked ? "解锁位置" : "锁定位置") { onToggleLock() }
            Divider()
            Button("从情绪板移除", role: .destructive) { onDelete() }
        }
    }
}

// MARK: - Editable Note Card Node (5 Calm Themes)

struct BoardNoteNodeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let node: BoardNode
    let title: String?
    let text: String
    let style: NoteStyle
    let fontSize: Double
    let isSelected: Bool
    let onUpdate: (String?, String, NoteStyle, Double) -> Void
    let onDelete: () -> Void

    @State private var draftTitle: String = ""
    @State private var draftText: String = ""
    @State private var isHovered: Bool = false

    var body: some View {
        let palette = NoteStylePalette.colors(for: style)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("标题 / 氛围词", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: max(13, fontSize), weight: .semibold))
                    .foregroundStyle(palette.foreground)
                    .frame(minWidth: 64)
                    .layoutPriority(1)
                    .onChange(of: draftTitle) { _, newValue in
                        if newValue != (title ?? "") {
                            onUpdate(newValue.isEmpty ? nil : newValue, draftText, style, fontSize)
                        }
                    }

                if isHovered || isSelected {
                    HStack(spacing: 3) {
                        ForEach(NoteStyle.allCases, id: \.self) { candidate in
                            let c = NoteStylePalette.colors(for: candidate)
                            Button {
                                onUpdate(draftTitle.isEmpty ? nil : draftTitle, draftText, candidate, fontSize)
                            } label: {
                                Circle()
                                    .fill(c.background)
                                    .frame(width: 10, height: 10)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(
                                                candidate == style ? Color.accentColor : c.foreground.opacity(0.3),
                                                lineWidth: candidate == style ? 1.5 : 0.75
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(NoteStylePalette.label(for: candidate))
                        }
                    }
                    .fixedSize()
                    .transition(.opacity)
                }
            }

            Divider()
                .overlay(palette.foreground.opacity(0.10))

            TextEditor(text: $draftText)
                .font(.system(size: max(11, fontSize - 1)))
                .foregroundStyle(palette.foreground.opacity(0.90))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .background(Color.clear)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: draftText) { _, newValue in
                    if newValue != text {
                        onUpdate(draftTitle.isEmpty ? nil : draftTitle, newValue, style, fontSize)
                    }
                }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.background, in: shape)
        .overlay(
            shape.strokeBorder(isSelected ? Color.accentColor : palette.border, lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)
        .onAppear {
            draftTitle = title ?? ""
            draftText = text
        }
        .onChange(of: title) { _, newVal in
            if draftTitle != (newVal ?? "") { draftTitle = newVal ?? "" }
        }
        .onChange(of: text) { _, newVal in
            if draftText != newVal { draftText = newVal }
        }
        .onHover { hovering in
            withAnimation(CanvasMotion.accessible(CanvasMotion.hoverPress, reduced: reduceMotion)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            Menu("便签主题") {
                ForEach(NoteStyle.allCases, id: \.self) { s in
                    Button(NoteStylePalette.label(for: s)) {
                        onUpdate(draftTitle.isEmpty ? nil : draftTitle, draftText, s, fontSize)
                    }
                }
            }
            Menu("字号") {
                ForEach([12.0, 14.0, 16.0, 20.0], id: \.self) { size in
                    Button("\(Int(size)) pt") {
                        onUpdate(draftTitle.isEmpty ? nil : draftTitle, draftText, style, size)
                    }
                }
            }
            Divider()
            Button("删除便签", role: .destructive) { onDelete() }
        }
    }
}

// MARK: - Smart Auto-Layout Group Frame Node (Reference Img 4 Style)

struct BoardGroupFrameView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let tint: GroupTint
    let itemCount: Int
    let isSelected: Bool
    let onUpdate: (String, GroupTint) -> Void
    let onReflowInside: () -> Void
    let onDelete: () -> Void

    @State private var draftTitle: String = ""
    @State private var isHovered: Bool = false

    var body: some View {
        let accent = GroupTintPalette.accent(for: tint)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)

                if itemCount > 0 {
                    Text("\(itemCount) ·")
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                }

                TextField("分组名称", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent.opacity(colorScheme == .dark ? 0.96 : 0.92))
                    .onChange(of: draftTitle) { _, newValue in
                        if newValue != title {
                            onUpdate(newValue, tint)
                        }
                    }

                Spacer()

                if isHovered || isSelected {
                    HStack(spacing: 6) {
                        if itemCount > 0 {
                            Button(action: onReflowInside) {
                                HStack(spacing: 3) {
                                    Image(systemName: "rectangle.3.group")
                                        .font(.system(size: 9.5, weight: .semibold))
                                    Text("自适应排布")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundStyle(accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2.5)
                                .background(accent.opacity(0.14), in: Capsule(style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("按当前框尺寸实时缩放并重排框内所有素材")
                        }

                        HStack(spacing: 4) {
                            ForEach(GroupTint.allCases, id: \.self) { candidate in
                                Button {
                                    onUpdate(draftTitle, candidate)
                                } label: {
                                    Circle()
                                        .fill(GroupTintPalette.accent(for: candidate))
                                        .frame(width: 9, height: 9)
                                        .overlay(
                                            Circle().strokeBorder(Color.white.opacity(candidate == tint ? 0.9 : 0.0), lineWidth: 1.5)
                                        )
                                }
                                .buttonStyle(.plain)
                                .help(GroupTintPalette.label(for: candidate))
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(accent.opacity(colorScheme == .dark ? 0.12 : 0.07))

            Spacer()
        }
        .background(accent.opacity(colorScheme == .dark ? 0.05 : 0.03), in: shape)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                isSelected ? Color.accentColor : accent.opacity(0.62),
                lineWidth: isSelected ? 1.8 : 1.15
            )
        )
        .onAppear { draftTitle = title }
        .onChange(of: title) { _, newVal in
            if draftTitle != newVal { draftTitle = newVal }
        }
        .onHover { hovering in
            withAnimation(CanvasMotion.accessible(CanvasMotion.hoverPress, reduced: reduceMotion)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            if itemCount > 0 {
                Button {
                    onReflowInside()
                } label: {
                    Label("自适应缩放排布框内素材", systemImage: "rectangle.3.group")
                }
                Divider()
            }
            Menu("分组色标") {
                ForEach(GroupTint.allCases, id: \.self) { t in
                    Button(GroupTintPalette.label(for: t)) { onUpdate(draftTitle, t) }
                }
            }
            Divider()
            Button("删除分组框（保留内部元素）", role: .destructive) { onDelete() }
        }
    }
}

// MARK: - On-Canvas Palette Strip Node

struct BoardPaletteStripNodeView: View {
    @Environment(\.colorScheme) private var colorScheme

    let colors: [LabColor]
    let autoSync: Bool
    let isSelected: Bool
    let onCopyHex: (String) -> Void
    let onSearchColor: (String) -> Void
    let onToggleAutoSync: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let swatches = colors.isEmpty ? [LabColor.fromHex("#8B95A1"), LabColor.fromHex("#C8B8A6"), LabColor.fromHex("#4F5D6B")] : colors

        HStack(spacing: 0) {
            ForEach(swatches, id: \.hex) { swatch in
                let hex = swatch.hex.uppercased()
                let isLight = Color.charkleIsLightHex(hex)
                Button {
                    onCopyHex(hex)
                } label: {
                    ZStack(alignment: .bottomLeading) {
                        Color(charkleHex: hex)
                        Text(hex)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isLight ? Color.black.opacity(0.76) : Color.white.opacity(0.88))
                            .padding(8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("复制 \(hex)") { onCopyHex(hex) }
                    Button("以此色筛选素材库") { onSearchColor(hex) }
                }
                .help("点击复制 \(hex)")
            }
        }
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                isSelected ? Color.accentColor : CanvasSurface.hairline(for: colorScheme),
                lineWidth: isSelected ? 2.5 : 1
            )
        )
        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)
        .contextMenu {
            Button(autoSync ? "关闭自动同步板内色板" : "开启自动同步板内色板") { onToggleAutoSync() }
            Divider()
            Button("移除色卡条", role: .destructive) { onDelete() }
        }
    }
}
