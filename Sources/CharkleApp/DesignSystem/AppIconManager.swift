import AppKit
import SwiftUI

public enum CharkleAppIconVariant: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .light: "亮色"
        case .dark: "暗色背景"
        }
    }

    public var subtitle: String {
        switch self {
        case .light: "默认 · 柔和虹彩浅底"
        case .dark: "可选 · 深邃青灰暗底"
        }
    }

    var previewResourceName: String {
        switch self {
        case .light: "AppIcon-Light-1024"
        case .dark: "AppIcon-Dark-1024"
        }
    }

    var dockResourceName: String {
        switch self {
        case .light: "AppIcon-Light-Dock"
        case .dark: "AppIcon-Dark-Dock"
        }
    }
}

/// Manages Charkle's switchable macOS App Icon (Light default / Dark optional)
/// across the running Dock icon, ⌘Tab switcher, in-app brand marks, and `.app` bundle icon.
@Observable
public final class CharkleAppIconManager {
    public static let shared = CharkleAppIconManager()
    private static let defaultsKey = "com.charkle.appIconVariant"

    public var currentVariant: CharkleAppIconVariant

    @ObservationIgnored
    private var imageCache: [String: NSImage] = [:]

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.defaultsKey),
           let stored = CharkleAppIconVariant(rawValue: raw) {
            self.currentVariant = stored
        } else {
            self.currentVariant = .light
        }
    }

    public func select(_ variant: CharkleAppIconVariant) {
        currentVariant = variant
        UserDefaults.standard.set(variant.rawValue, forKey: Self.defaultsKey)
        applyCurrentIcon(updateBundleFileIcon: false)
    }

    public func applyCurrentIcon(updateBundleFileIcon: Bool = false) {
        _ = updateBundleFileIcon
        guard let app = NSApp else { return }
        // Only update the runtime Dock / ⌘Tab icon via `NSApp.applicationIconImage`.
        // Never mutate the signed `.app` bundle icon on disk so code-signing,
        // Keychain identity, and macOS TCC permissions remain intact.
        if let dockImg = dockImage(for: currentVariant) {
            app.applicationIconImage = dockImg
        }
    }

    public func previewImage(for variant: CharkleAppIconVariant) -> NSImage? {
        loadImage(named: variant.previewResourceName)
    }

    public func dockImage(for variant: CharkleAppIconVariant) -> NSImage? {
        loadImage(named: variant.dockResourceName) ?? loadImage(named: variant.previewResourceName)
    }

    private func loadImage(named name: String) -> NSImage? {
        if let cached = imageCache[name] {
            return cached
        }
        let candidates: [URL?] = [
            Bundle.module.url(forResource: name, withExtension: "png"),
            Bundle.main.url(forResource: name, withExtension: "png"),
            Bundle.main.resourceURL?.appending(path: "\(name).png")
        ]
        for case let url? in candidates {
            if let img = NSImage(contentsOf: url) {
                imageCache[name] = img
                return img
            }
        }
        return nil
    }
}

/// Crisp brand icon badge that tracks the user's selected Charkle App Icon variant live.
public struct CharkleBrandMark: View {
    private let size: CGFloat
    private let iconManager = CharkleAppIconManager.shared

    public init(size: CGFloat = 22) {
        self.size = size
    }

    public var body: some View {
        if let img = iconManager.previewImage(for: iconManager.currentVariant) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
                .shadow(color: Color.black.opacity(0.10), radius: 2, y: 1)
        } else {
            CharkleIcon("moodboard", style: .layered, size: size)
        }
    }
}
