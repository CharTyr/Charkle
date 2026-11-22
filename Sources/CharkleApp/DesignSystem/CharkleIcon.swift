import AppKit
import SwiftUI

public enum CharkleIconStyle: String, Sendable {
    case duotone
    case layered
}

/// Canonical icon loader for `$kubai-icons` SVGs (`duotone-<name>.svg`, `layered-<name>.svg`)
/// bundled inside `Bundle.module`, with `NSCache` acceleration and crisp SF Symbol fallback
/// whenever an SVG asset is not present yet.
public struct CharkleIcon: View {
    public let name: String
    public let style: CharkleIconStyle
    public let size: CGFloat
    public let fallbackColor: Color?

    public init(
        _ name: String,
        style: CharkleIconStyle = .duotone,
        size: CGFloat = 16,
        color: Color? = nil
    ) {
        self.name = name
        self.style = style
        self.size = size
        self.fallbackColor = color
    }

    public var body: some View {
        if let nsImage = CharkleIconCache.shared.svgImage(name: name, style: style) {
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

    /// Calibrated SF Symbol fallbacks covering all canonical names in `docs/MOTION_AND_ICON_SPEC.md`.
    public static func sfSymbolFallback(for name: String) -> String {
        switch name {
        // Navigation
        case "library": "square.grid.2x2"
        case "inbox": "tray.and.arrow.down"
        case "moodboard": "rectangle.3.group"
        case "folder": "folder"
        case "untagged": "tag.slash"
        case "recent": "clock"
        case "trash": "trash"
        case "tag": "tag"
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
        case "filter": "line.3.horizontal.decrease.circle"
        case "search": "magnifyingglass"
        case "settings": "gearshape"
        case "quicklook": "eye"
        default: "square.dashed"
        }
    }
}

private final class CharkleIconCache {
    static let shared = CharkleIconCache()

    private let imageCache = NSCache<NSString, NSImage>()
    private var missingKeys: Set<String> = []

    private init() {
        imageCache.countLimit = 128
    }

    func svgImage(name: String, style: CharkleIconStyle) -> NSImage? {
        let baseName = "\(style.rawValue)-\(name)"
        if let cached = imageCache.object(forKey: baseName as NSString) {
            return cached
        }
        if missingKeys.contains(baseName) {
            return nil
        }

        // Check both flattened SPM `.process("Resources")` root and `Icons/` subdirectory.
        let url = Bundle.module.url(forResource: baseName, withExtension: "svg")
            ?? Bundle.module.url(forResource: baseName, withExtension: "svg", subdirectory: "Icons")

        guard let url, let image = NSImage(contentsOf: url) else {
            missingKeys.insert(baseName)
            return nil
        }
        image.isTemplate = false
        imageCache.setObject(image, forKey: baseName as NSString)
        return image
    }
}
