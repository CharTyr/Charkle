import AppKit
import SwiftUI

public enum CharkleIconStyle: String, Sendable {
    case duotone
    case layered
}

/// Canonical icon loader for bundled SVG icons (`duotone-<name>.svg`, `layered-<name>.svg`)
/// bundled inside `Bundle.module`, with automatic Light/Dark & Active-state dual-tone adaptation,
/// `NSCache` acceleration, and crisp SF Symbol fallback.
public struct CharkleIcon: View {
    @Environment(\.colorScheme) private var colorScheme

    public let name: String
    public let style: CharkleIconStyle
    public let size: CGFloat
    public let fallbackColor: Color?
    public let isActive: Bool
    public let tintHex: String?

    public init(
        _ name: String,
        style: CharkleIconStyle = .duotone,
        size: CGFloat = 18,
        color: Color? = nil,
        isActive: Bool = false,
        tintHex: String? = nil
    ) {
        self.name = name
        self.style = style
        self.size = size
        self.fallbackColor = color
        self.isActive = isActive
        self.tintHex = tintHex
    }

    public var body: some View {
        let variant = CharkleIconCache.Variant(
            isDark: colorScheme == .dark,
            isActive: isActive,
            tintHex: tintHex?.uppercased()
        )
        if let nsImage = CharkleIconCache.shared.svgImage(name: name, style: style, variant: variant) {
            Image(nsImage: nsImage)
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: Self.sfSymbolFallback(for: name))
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: style == .layered ? size * 0.62 : size * 0.86, weight: .medium))
                .foregroundStyle(fallbackColor ?? .primary)
                .frame(width: size, height: size)
        }
    }

    /// Calibrated SF Symbol fallbacks covering all canonical names.
    public static func sfSymbolFallback(for name: String) -> String {
        switch name {
        // Navigation
        case "library": "square.grid.2x2"
        case "inbox": "tray.and.arrow.down"
        case "moodboard": "rectangle.3.group"
        case "folder": "folder"
        case "smart-folder": "folder.badge.gearshape"
        case "untagged": "tag.slash"
        case "recent": "clock"
        case "trash": "trash"
        case "tag": "tag"
        case "sidebar-toggle": "sidebar.left"
        // Gallery & Media
        case "masonry-vertical": "rectangle.split.3x1"
        case "masonry-horizontal": "rectangle.split.1x2"
        case "gallery-ring": "square.stack.3d.forward.dottedline"
        case "compact-list": "list.bullet"
        case "github": "chevron.left.forwardslash.chevron.right"
        case "model3d": "cube"
        case "audio": "waveform"
        case "social-post": "text.bubble"
        case "markdown": "doc.richtext"
        case "similar": "sparkles"
        // Moodboard & Canvas
        case "sparkle-board": "sparkles.rectangle.stack"
        case "auto-layout": "rectangle.3.group"
        case "freeform": "scribble.variable"
        case "note": "note.text"
        case "group-frame": "rectangle.dashed"
        case "connector": "arrow.up.right"
        case "ink-pen": "pencil.tip"
        case "palette": "paintpalette"
        case "export": "square.and.arrow.up"
        case "swap": "arrow.triangle.2.circlepath"
        case "pin-offline": "arrow.down.circle.fill"
        // Capture & Sync
        case "notch": "menubar.dock.rectangle"
        case "screenshot": "camera.viewfinder"
        case "drive-sync": "icloud.and.arrow.up"
        case "drive": "icloud.and.arrow.up"
        case "ai-spark": "sparkles"
        case "gallery": "rectangle.grid.2x2"
        case "ready": "checkmark.circle.fill"
        case "filter": "line.3.horizontal.decrease.circle"
        case "search": "magnifyingglass"
        case "settings": "gearshape"
        case "quicklook": "eye"
        default: "square.dashed"
        }
    }
}

final class CharkleIconCache {
    static let shared = CharkleIconCache()

    struct Variant: Hashable {
        let isDark: Bool
        let isActive: Bool
        let tintHex: String?

        var keySuffix: String {
            "\(isDark ? "d" : "l")-\(isActive ? "a" : "n")-\(tintHex ?? "def")"
        }
    }

    // Exported canonical duotone SVG palette in Resources/Icons/duotone-*.svg
    private static let sourcePrimary = "#445C94"
    private static let sourceSecondary = "#B4BED4"

    private let imageCache = NSCache<NSString, NSImage>()
    private var missingKeys: Set<String> = []

    private init() {
        imageCache.countLimit = 256
    }

    func svgImage(name: String, style: CharkleIconStyle, variant: Variant) -> NSImage? {
        let baseName = "\(style.rawValue)-\(name)"
        let cacheKey = (style == .duotone ? "\(baseName)-\(variant.keySuffix)" : baseName) as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }
        if missingKeys.contains(baseName) {
            return nil
        }

        let url = Bundle.module.url(forResource: baseName, withExtension: "svg")
            ?? Bundle.module.url(forResource: baseName, withExtension: "svg", subdirectory: "Icons")

        guard let url else {
            missingKeys.insert(baseName)
            return nil
        }

        let image: NSImage?
        if style == .duotone, let rawSVG = try? String(contentsOf: url, encoding: .utf8) {
            let adapted = adaptDuotonePalette(rawSVG, variant: variant)
            image = NSImage(data: Data(adapted.utf8)) ?? NSImage(contentsOf: url)
        } else {
            image = NSImage(contentsOf: url)
        }

        guard let image else {
            missingKeys.insert(baseName)
            return nil
        }
        image.isTemplate = false
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    /// Renders a crisp 16×16 non-template colored folder `NSImage` suitable for macOS `NSMenu` / `.contextMenu` items,
    /// where SwiftUI `.foregroundStyle` would otherwise be stripped into monochrome template tinting.
    func menuFolderIcon(colorHex: String?, isDark: Bool) -> NSImage {
        let key = "menu-folder:\(colorHex ?? "default"):\(isDark ? "d" : "l")" as NSString
        if let cached = imageCache.object(forKey: key) {
            return cached
        }
        let variant = Variant(isDark: isDark, isActive: false, tintHex: colorHex)
        let source = svgImage(name: "folder", style: .duotone, variant: variant)
        let targetSize = NSSize(width: 16, height: 16)
        let rendered = NSImage(size: targetSize, flipped: false) { rect in
            if let source {
                source.draw(
                    in: rect,
                    from: NSRect(origin: .zero, size: source.size),
                    operation: .sourceOver,
                    fraction: 1.0
                )
            } else {
                let fallbackColor = colorHex.flatMap { NSColor(charkleHex: $0) } ?? NSColor.controlAccentColor
                fallbackColor.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            }
            return true
        }
        rendered.isTemplate = false
        imageCache.setObject(rendered, forKey: key)
        return rendered
    }

    private func adaptDuotonePalette(_ svg: String, variant: Variant) -> String {
        if let customHex = variant.tintHex, let pair = Self.deriveDuotonePair(from: customHex, isDark: variant.isDark) {
            return svg
                .replacingOccurrences(of: Self.sourcePrimary, with: pair.primary, options: .caseInsensitive)
                .replacingOccurrences(of: Self.sourceSecondary, with: pair.secondary, options: .caseInsensitive)
        }
        let targetPrimary: String
        let targetSecondary: String
        switch (variant.isDark, variant.isActive) {
        case (false, false):
            return svg
        case (false, true):
            targetPrimary = "#2A60E0"
            targetSecondary = "#AFC6F7"
        case (true, false):
            targetPrimary = "#8EA8E8"
            targetSecondary = "#3D4E75"
        case (true, true):
            targetPrimary = "#9BB7FF"
            targetSecondary = "#3E5998"
        }
        return svg
            .replacingOccurrences(of: Self.sourcePrimary, with: targetPrimary, options: .caseInsensitive)
            .replacingOccurrences(of: Self.sourceSecondary, with: targetSecondary, options: .caseInsensitive)
    }

    /// Derives a duotone primary + secondary hex pair from any user-selected folder color hex
    /// (40% tint over white in Light Mode, 38% tint over charcoal in Dark Mode).
    private static func deriveDuotonePair(from rawHex: String, isDark: Bool) -> (primary: String, secondary: String)? {
        let cleaned = rawHex.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
        guard cleaned.count == 6, let val = UInt32(cleaned, radix: 16) else { return nil }
        let r = Double((val >> 16) & 0xFF)
        let g = Double((val >> 8) & 0xFF)
        let b = Double(val & 0xFF)

        if isDark {
            let pr = min(255, r * 0.88 + 255 * 0.12)
            let pg = min(255, g * 0.88 + 255 * 0.12)
            let pb = min(255, b * 0.88 + 255 * 0.12)
            let sr = r * 0.45 + 34 * 0.55
            let sg = g * 0.45 + 36 * 0.55
            let sb = b * 0.45 + 42 * 0.55
            return (
                String(format: "#%02X%02X%02X", Int(pr.rounded()), Int(pg.rounded()), Int(pb.rounded())),
                String(format: "#%02X%02X%02X", Int(sr.rounded()), Int(sg.rounded()), Int(sb.rounded()))
            )
        } else {
            let sr = r * 0.50 + 255 * 0.50
            let sg = g * 0.50 + 255 * 0.50
            let sb = b * 0.50 + 255 * 0.50
            return (
                "#\(cleaned.uppercased())",
                String(format: "#%02X%02X%02X", Int(sr.rounded()), Int(sg.rounded()), Int(sb.rounded()))
            )
        }
    }
}

private extension NSColor {
    convenience init?(charkleHex: String) {
        let cleaned = charkleHex.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
        guard cleaned.count == 6, let val = UInt32(cleaned, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((val >> 16) & 0xFF) / 255.0,
            green: CGFloat((val >> 8) & 0xFF) / 255.0,
            blue: CGFloat(val & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

/// Renders a duotone folder icon with optional macOS-style custom color tint
/// and embossed SF Symbol or Emoji badge centered on the folder face.
public struct CharkleFolderIcon: View {
    @Environment(\.colorScheme) private var colorScheme

    public let colorHex: String?
    public let customSymbol: String?
    public let size: CGFloat
    public let isActive: Bool

    public init(
        colorHex: String? = nil,
        customSymbol: String? = nil,
        size: CGFloat = 18,
        isActive: Bool = false
    ) {
        self.colorHex = colorHex
        self.customSymbol = customSymbol
        self.size = size
        self.isActive = isActive
    }

    public var body: some View {
        ZStack {
            CharkleIcon("folder", style: .duotone, size: size, isActive: isActive, tintHex: colorHex)

            if let sym = customSymbol, !sym.isEmpty {
                if sym.hasPrefix("emoji:") {
                    let emoji = String(sym.dropFirst(6))
                    Text(emoji)
                        .font(.system(size: max(8, size * 0.46)))
                        .offset(y: size * 0.08)
                } else {
                    let sfName = sym.hasPrefix("sf:") ? String(sym.dropFirst(3)) : sym
                    Image(systemName: sfName)
                        .font(.system(size: max(7, size * 0.42), weight: .bold))
                        .foregroundStyle(embossColor)
                        .offset(y: size * 0.08)
                }
            }
        }
        .frame(width: size, height: size)
    }

    private var embossColor: Color {
        if let hex = colorHex {
            return colorScheme == .dark ? Color.white.opacity(0.92) : Color(charkleHex: hex).opacity(0.95)
        }
        return colorScheme == .dark ? Color.white.opacity(0.88) : Color(charkleHex: "#314678")
    }
}
