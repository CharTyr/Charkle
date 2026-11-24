import Carbon
import Foundation
import os

private let hotkeyLogger = Logger(subsystem: "com.charkle.app", category: "Hotkeys")

/// Registers system-wide macOS global hotkeys using Carbon `RegisterEventHotKey`:
/// - `⌥⇧A`: Interactive region screenshot capture into Charkle
/// - `⌥⇧S`: Toggle MacBook Notch Shelf anywhere
/// - `⌥⇧V`: Quick-collect current clipboard into Charkle
public final class GlobalHotkeyManager {
    public enum Action: UInt32, Hashable, Sendable {
        case captureArea = 1
        case toggleNotchShelf = 2
        case quickPasteClipboard = 3
    }

    private nonisolated static let hotKeySignature: OSType = 0x4348_4B4C // 'CHKL'

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var onTrigger: ((Action) -> Void)?
    public private(set) var conflictedActions: Set<Action> = []

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
                guard let userData, let eventRef else { return OSStatus(eventNotHandledErr) }
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
                guard err == noErr,
                      hotKeyID.signature == GlobalHotkeyManager.hotKeySignature,
                      let action = Action(rawValue: hotKeyID.id) else {
                    return OSStatus(eventNotHandledErr)
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
        registerSingle(keyCode: UInt32(kVK_ANSI_A), modifiers: mods, action: .captureArea)
        registerSingle(keyCode: UInt32(kVK_ANSI_S), modifiers: mods, action: .toggleNotchShelf)
        registerSingle(keyCode: UInt32(kVK_ANSI_V), modifiers: mods, action: .quickPasteClipboard)
    }

    private func registerSingle(keyCode: UInt32, modifiers: UInt32, action: Action) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: action.rawValue)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeyRefs.append(ref)
        } else {
            conflictedActions.insert(action)
            hotkeyLogger.warning("RegisterEventHotKey action=\(action.rawValue) failed with status \(status) (possible global shortcut conflict)")
        }
    }

    public func unregister() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        conflictedActions.removeAll()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    isolated deinit {
        unregister()
    }
}
