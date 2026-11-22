import Carbon
import Foundation
import os

private let hotkeyLogger = Logger(subsystem: "com.charkle.app", category: "Hotkeys")

/// Registers system-wide macOS global hotkeys using Carbon `RegisterEventHotKey`:
/// - `⌥⇧A`: Interactive region screenshot capture into Charkle
/// - `⌥⇧S`: Toggle MacBook Notch Shelf anywhere
/// - `⌥⇧V`: Quick-collect current clipboard into Charkle
public final class GlobalHotkeyManager {
    public enum Action: UInt32, Sendable {
        case captureArea = 1
        case toggleNotchShelf = 2
        case quickPasteClipboard = 3
    }

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var onTrigger: ((Action) -> Void)?

    public init() {}

    public func register(onTrigger: @escaping (Action) -> Void) {
        unregister()
        self.onTrigger = onTrigger

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let userData, let eventRef else { return noErr }
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr, let action = Action(rawValue: hotKeyID.id) else {
                    return noErr
                }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    manager.onTrigger?(action)
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )

        guard status == noErr else {
            hotkeyLogger.warning("InstallEventHandler failed with status \(status)")
            return
        }

        let mods = UInt32(optionKey | shiftKey)
        registerSingle(keyCode: UInt32(kVK_ANSI_A), modifiers: mods, id: Action.captureArea.rawValue)
        registerSingle(keyCode: UInt32(kVK_ANSI_S), modifiers: mods, id: Action.toggleNotchShelf.rawValue)
        registerSingle(keyCode: UInt32(kVK_ANSI_V), modifiers: mods, id: Action.quickPasteClipboard.rawValue)
    }

    private func registerSingle(keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4348_4B4C), id: id) // 'CHKL'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeyRefs.append(ref)
        } else {
            hotkeyLogger.debug("RegisterEventHotKey id=\(id) returned \(status)")
        }
    }

    public func unregister() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    isolated deinit {
        unregister()
    }
}
