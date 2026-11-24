import AppKit
import Foundation
import KeyboardShortcuts
import os

private let hotkeyLogger = Logger(subsystem: "com.charkle.app", category: "Hotkeys")

public extension KeyboardShortcuts.Name {
    static let captureArea = Self("charkle.captureArea", default: .init(.a, modifiers: [.option, .shift]))
    static let collectClipboard = Self("charkle.collectClipboard", default: .init(.v, modifiers: [.option, .shift]))
    static let toggleNotchShelf = Self("charkle.toggleNotchShelf", default: .init(.s, modifiers: [.option, .shift]))
}

/// Manages system-wide macOS global hotkeys backed by `KeyboardShortcuts`:
/// - `captureArea` (default `⌥⇧A`): Interactive region screenshot capture into Charkle
/// - `collectClipboard` (default `⌥⇧V`): Quick-collect current clipboard into Charkle
/// - `toggleNotchShelf` (default `⌥⇧S`): Toggle MacBook Notch Shelf anywhere
public final class GlobalHotkeyManager {
    public enum Action: UInt32, Hashable, Sendable, CaseIterable {
        case captureArea = 1
        case toggleNotchShelf = 2
        case quickPasteClipboard = 3

        public var shortcutName: KeyboardShortcuts.Name {
            switch self {
            case .captureArea: .captureArea
            case .toggleNotchShelf: .toggleNotchShelf
            case .quickPasteClipboard: .collectClipboard
            }
        }
    }

    public static let allShortcutNames: [KeyboardShortcuts.Name] = [
        .captureArea,
        .collectClipboard,
        .toggleNotchShelf
    ]

    public static func shortcutName(for action: Action) -> KeyboardShortcuts.Name {
        action.shortcutName
    }

    public static func displayString(for name: KeyboardShortcuts.Name, fallback: String) -> String {
        if let shortcut = KeyboardShortcuts.getShortcut(for: name) {
            return shortcut.description
        }
        return fallback
    }

    public static func resetDefaults() {
        KeyboardShortcuts.reset(allShortcutNames)
    }

    private var onTrigger: ((Action) -> Void)?
    public private(set) var conflictedActions: Set<Action> = []

    public var isEnabled: Bool = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                KeyboardShortcuts.enable(Self.allShortcutNames)
            } else {
                KeyboardShortcuts.disable(Self.allShortcutNames)
            }
        }
    }

    public init() {}

    public func register(onTrigger: @escaping (Action) -> Void) {
        removeRegisteredHandlers()
        self.onTrigger = onTrigger
        self.conflictedActions.removeAll()

        self.isEnabled = true

        for action in Action.allCases {
            let name = action.shortcutName
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.isEnabled else { return }
                    self.onTrigger?(action)
                }
            }
        }
        KeyboardShortcuts.enable(Self.allShortcutNames)
        hotkeyLogger.debug("Registered \(Self.allShortcutNames.count) global shortcuts via KeyboardShortcuts")
    }

    public func unregister() {
        self.isEnabled = false
        KeyboardShortcuts.disable(Self.allShortcutNames)
        removeRegisteredHandlers()
        self.onTrigger = nil
        self.conflictedActions.removeAll()
    }

    private func removeRegisteredHandlers() {
        for name in Self.allShortcutNames {
            KeyboardShortcuts.removeHandler(for: name)
        }
    }

    isolated deinit {
        unregister()
    }
}
