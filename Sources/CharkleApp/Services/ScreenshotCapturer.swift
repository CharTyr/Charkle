import Foundation

/// Wraps macOS native `/usr/sbin/screencapture` for interactive area, window, and full-screen captures.
public nonisolated enum ScreenshotCapturer {
    public enum Mode: Sendable {
        case area
        case window
        case fullScreen
    }

    @concurrent
    public static func capture(mode: Mode) async -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = formatter.string(from: Date())
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Charkle-Shot-\(stamp).png")

        let args: [String] = switch mode {
        case .area: ["-i", "-r", tempURL.path]
        case .window: ["-i", "-w", "-r", tempURL.path]
        case .fullScreen: ["-x", tempURL.path]
        }

        let succeeded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = args
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }

        guard succeeded, FileManager.default.fileExists(atPath: tempURL.path) else {
            return nil
        }
        return tempURL
    }
}
