import Foundation

private actor ScreenshotCaptureGate {
    private var inProgress: Bool = false

    func tryBegin() -> Bool {
        guard !inProgress else { return false }
        inProgress = true
        return true
    }

    func end() {
        inProgress = false
    }
}

private nonisolated final class CancellableProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled: Bool = false

    func attach(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled {
            return false
        }
        self.process = process
        return true
    }

    func terminateIfRunning() {
        lock.lock()
        cancelled = true
        let proc = process
        lock.unlock()
        if let proc, proc.isRunning {
            proc.terminate()
        }
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }
}

/// Wraps macOS native `/usr/sbin/screencapture` for interactive area, window, and full-screen captures.
public nonisolated enum ScreenshotCapturer {
    private static let gate = ScreenshotCaptureGate()

    public enum Mode: Sendable {
        case area
        case window
        case fullScreen
    }

    @concurrent
    public static func capture(mode: Mode) async -> URL? {
        guard await gate.tryBegin() else { return nil }
        defer {
            Task { await gate.end() }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = formatter.string(from: Date())
        let nonce = String(UUID().uuidString.prefix(6)).lowercased()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Charkle-Shot-\(stamp)-\(nonce).png")

        let args: [String] = switch mode {
        case .area: ["-i", "-r", tempURL.path]
        case .window: ["-i", "-w", "-r", tempURL.path]
        case .fullScreen: ["-x", tempURL.path]
        }

        let box = CancellableProcessBox()
        let succeeded = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = args
                guard box.attach(process) else {
                    continuation.resume(returning: false)
                    return
                }
                process.terminationHandler = { proc in
                    box.clear()
                    continuation.resume(returning: proc.terminationStatus == 0)
                }
                do {
                    try process.run()
                    if box.isCancelled(), process.isRunning {
                        process.terminate()
                    }
                } catch {
                    box.clear()
                    continuation.resume(returning: false)
                }
            }
        } onCancel: {
            box.terminateIfRunning()
        }

        guard !Task.isCancelled, succeeded, FileManager.default.fileExists(atPath: tempURL.path) else {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
        return tempURL
    }
}
