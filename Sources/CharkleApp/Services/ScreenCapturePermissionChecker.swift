import AppKit
import CoreGraphics
import Foundation

/// Non-intrusive macOS Screen Recording permission status checker & System Settings deep-linker
/// used by the Capture & Shortcuts Settings pane to provide Refto-style inline guidance.
public enum ScreenCapturePermissionChecker {
    public static func hasScreenRecordingAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestAccessPromptIfNeeded() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
