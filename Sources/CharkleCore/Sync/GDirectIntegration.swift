import Darwin
import Foundation

public nonisolated enum GDirectIntegration {
    private static let searchPath = [
        NSHomeDirectory() + "/.local/bin", "/opt/zerobrew/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"
    ] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)

    public static func detectBinary(named name: String = "gdirect") -> String? {
        searchPath.lazy.map { $0 + "/" + name }.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    public static func isMountActive(at path: String) -> Bool {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard let mounted = statInfo(url, followLinks: false), let parent = statInfo(url.deletingLastPathComponent()),
              mounted.st_mode & S_IFMT == S_IFDIR else { return false }
        return mounted.st_dev != parent.st_dev
    }

    static func statInfo(_ url: URL, followLinks: Bool = true) -> stat? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return followLinks ? stat(path, &info) : Darwin.lstat(path, &info)
        }
        return result == 0 ? info : nil
    }

    public static func hasVersionMismatch(cli: String?, app: String?) -> Bool {
        guard let cli = cli.flatMap(version), let app = app.flatMap(version) else { return false }
        return cli != app
    }

    private static func version(_ output: String) -> String? {
        guard let range = output.range(of: #"\b[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?"#, options: .regularExpression) else {
            return nil
        }
        return String(output[range])
    }

    public static func parseAccounts(_ output: String) -> (accounts: [String], defaultAccount: String?) {
        var accounts: [String] = []
        var primary: String?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: #"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
                                         options: .regularExpression) else { continue }
            let email = String(line[range])
            if !accounts.contains(email) { accounts.append(email) }
            if line[..<range.lowerBound].trimmingCharacters(in: .whitespaces).hasSuffix("*") { primary = email }
        }
        return (accounts, primary)
    }

    public static func parseScanList(_ output: String) -> [GDirectEndpoint] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> GDirectEndpoint? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { return nil }
            let ip = String(fields[0])
            var ipv4 = in_addr()
            var ipv6 = in6_addr()
            guard inet_pton(AF_INET, ip, &ipv4) == 1 || inet_pton(AF_INET6, ip, &ipv6) == 1 else { return nil }
            let healthy = fields[1].uppercased() == "OK"
            let ms = fields.dropFirst(2).compactMap { Int($0.prefix(while: \.isNumber)) }.first ?? Int.max
            return GDirectEndpoint(ip: ip, latencyMs: ms, healthy: healthy)
        }.sorted {
            if $0.healthy != $1.healthy { return $0.healthy }
            return ($0.latencyMs, $0.ip) < ($1.latencyMs, $1.ip)
        }
    }

    /// Fast, lightweight account lookup (`gdirect accounts` only) without triggering endpoint scan reads.
    public static func signedInAccounts() async -> (accounts: [String], defaultAccount: String?) {
        guard let binary = detectBinary(),
              let output = try? await run(binary, ["accounts"], timeout: 5) else {
            return ([], nil)
        }
        return parseAccounts(output.stdout)
    }

    public static func inspect(mountPath: String) async -> GDirectEnvironmentSnapshot {
        let binary = detectBinary()
        let app = Bundle(path: "/Applications/gdirect.app")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        var result = GDirectEnvironmentSnapshot(cliPath: binary, appVersion: app, rclonePath: detectBinary(named: "rclone"),
                                               mountPath: (mountPath as NSString).expandingTildeInPath,
                                               isMountActive: isMountActive(at: mountPath))
        guard let binary else { return result }
        async let versionOutput = try? run(binary, ["--version"])
        async let accountOutput = try? run(binary, ["accounts"])
        async let scanOutput = try? run(binary, ["scan", "--list"])
        result.cliVersion = await versionOutput.flatMap { version($0.stdout) }
        result.hasVersionMismatch = hasVersionMismatch(cli: result.cliVersion, app: result.appVersion)
        if let output = await accountOutput {
            (result.accounts, result.defaultAccount) = parseAccounts(output.stdout)
        }
        if let output = await scanOutput {
            result.endpoints = parseScanList(output.stdout)
            let diagnostic = (output.stdout + output.stderr).lowercased()
            result.bypassTunEnabled = !diagnostic.contains("bypass-tun off") && !diagnostic.contains("following proxy")
        }
        return result
    }

    public static func scan(mountPath: String) async throws -> GDirectEnvironmentSnapshot {
        _ = try await command(["scan"], timeout: 180)
        return await inspect(mountPath: mountPath)
    }

    /// Detects any currently active loopback NFS mount (`localhost:/` or `127.0.0.1:/`) created by `gdirect` / `rclone`.
    public static func activeLoopbackNFSMountPath() -> String? {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return nil }
        var entries = Array(repeating: statfs(), count: Int(count))
        let bufferSize = Int32(entries.count * MemoryLayout<statfs>.stride)
        let actual = entries.withUnsafeMutableBufferPointer { ptr in
            getfsstat(ptr.baseAddress, bufferSize, MNT_NOWAIT)
        }
        guard actual > 0 else { return nil }
        for idx in 0..<Int(actual) {
            var entry = entries[idx]
            let fsType = withUnsafeBytes(of: &entry.f_fstypename) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            guard fsType == "nfs" else { continue }
            let source = withUnsafeBytes(of: &entry.f_mntfromname) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            guard source.hasPrefix("localhost:") || source.hasPrefix("127.0.0.1:") else { continue }
            let target = withUnsafeBytes(of: &entry.f_mntonname) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if !target.isEmpty && isMountActive(at: target) {
                return target
            }
        }
        return nil
    }

    @discardableResult
    public static func mount(path: String, account: String? = nil) async throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if isMountActive(at: expanded) { return expanded }
        try? FileManager.default.createDirectory(atPath: expanded, withIntermediateDirectories: true)

        do {
            _ = try await command(["mount", expanded], account: account, timeout: 55)
        } catch let DriveTransportError.commandFailed(_, stderr, _) where stderr.lowercased().contains("already mounted") {
            // If gdirect is already actively mounted at another path on this Mac, reuse it directly
            if let liveMount = activeLoopbackNFSMountPath() {
                return liveMount
            }
            // Otherwise clear stale mount state from an earlier crashed/rebooted session and mount cleanly
            try? await unmount(account: account)
            try? await Task.sleep(for: .milliseconds(250))
            _ = try await command(["mount", expanded], account: account, timeout: 55)
        }

        for _ in 0..<32 {
            if isMountActive(at: expanded) { return expanded }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw DriveTransportError.mountPathUnavailable(expanded)
    }

    public static func unmount(account: String? = nil) async throws {
        _ = try await command(["unmount"], account: account)
    }

    /// Exports the user's already-configured Desktop OAuth client JSON directly from the local `gdirect` CLI.
    public static func exportOAuthClient() async throws -> GoogleOAuthClientConfig {
        let output = try await command(["login", "--export-client", "-"], timeout: 10)
        return try GoogleOAuthClientConfig.parseClientSecretJSON(output.output)
    }

    public static func list(folderID: String = "root", account: String? = nil) async throws -> Data {
        try await command(["ls", "--json", "--", folderID], account: account).output
    }

    public static func upload(_ url: URL, parentID: String, name: String, account: String? = nil) async throws -> String {
        try await command(["upload", "--parent", parentID, "--name", name, "--", url.path], account: account, timeout: 1_800).stdout
    }

    public static func download(fileID: String, to url: URL, account: String? = nil) async throws {
        _ = try await command(["download", "--output", url.path, "--", fileID], account: account, timeout: 1_800)
    }

    private static func command(_ arguments: [String], account: String? = nil, timeout: Double = 20) async throws -> Output {
        guard let binary = detectBinary() else { throw DriveTransportError.gdirectNotFound }
        return try await run(binary, (account.map { ["--account", $0] } ?? []) + arguments, timeout: timeout)
    }

    struct Output: Sendable {
        let output: Data
        let stderr: String
        var stdout: String { String(decoding: output, as: UTF8.self) }
    }

    @concurrent
    static func run(_ executable: String, _ arguments: [String], timeout: Double = 12, input: Data? = nil) async throws -> Output {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appending(path: "CharkleProcess-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let out = directory.appending(path: "stdout")
        let err = directory.appending(path: "stderr")
        try Data().write(to: out)
        try Data().write(to: err)
        let outHandle = try FileHandle(forWritingTo: out)
        let errHandle = try FileHandle(forWritingTo: err)
        defer { try? outHandle.close(); try? errHandle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outHandle
        process.standardError = errHandle
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath.joined(separator: ":")
        process.environment = env
        let inputPipe = input.map { _ in Pipe() }
        if let inputPipe { process.standardInput = inputPipe }
        try process.run()
        if let input, let inputPipe {
            try inputPipe.fileHandleForWriting.write(contentsOf: input)
            try inputPipe.fileHandleForWriting.close()
        }
        let deadline = ContinuousClock.now + .seconds(timeout)
        do {
            while process.isRunning {
                guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
                try await Task.sleep(for: .milliseconds(25))
            }
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
        let error = String(decoding: try Data(contentsOf: err), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw DriveTransportError.commandFailed(command: URL(fileURLWithPath: executable).lastPathComponent,
                                                    stderr: error, exitCode: process.terminationStatus)
        }
        return Output(output: try Data(contentsOf: out), stderr: error)
    }
}
