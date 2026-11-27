import CharkleCore
import Darwin
import Foundation

/// Minimal headless `stdio` MCP server helper bundled at `Charkle.app/Contents/Helpers/charkle`.
///
/// Serves local AI Agents (Claude Code, Codex, Antigravity, Cursor, Claude Desktop) over stdio JSON-RPC 2.0
/// even when `Charkle.app` is closed. Remote & cross-machine Agents connect via Streamable HTTP `/api/v1/mcp`.
@main
struct CharkleMCPHelper {
    static let version = CharkleExternalAgentService.serverVersion

    static func main() async {
        let rawArgs = Array(CommandLine.arguments.dropFirst())
        var libraryDir: URL?
        var positional: [String] = []

        var i = 0
        while i < rawArgs.count {
            let arg = rawArgs[i]
            if arg == "--library-dir" || arg == "-d" {
                if i + 1 < rawArgs.count {
                    let expanded = (rawArgs[i + 1] as NSString).expandingTildeInPath
                    libraryDir = URL(fileURLWithPath: expanded, isDirectory: true)
                    i += 2
                    continue
                }
            } else if arg.hasPrefix("--library-dir=") {
                let rawPath = String(arg.dropFirst("--library-dir=".count))
                let expanded = (rawPath as NSString).expandingTildeInPath
                libraryDir = URL(fileURLWithPath: expanded, isDirectory: true)
                i += 1
                continue
            } else if arg == "--json" || arg == "--compact" {
                i += 1
                continue
            } else if arg == "--version" || arg == "-v" || arg == "version" {
                print("charkle-mcp \(version)")
                return
            } else if arg == "--help" || arg == "-h" || arg == "help" {
                printHelp()
                return
            } else {
                positional.append(arg)
            }
            i += 1
        }

        // Default to `mcp` when stdin is piped (standard MCP host invocation) or `mcp` is passed explicitly.
        let command = positional.first ?? (isatty(STDIN_FILENO) == 0 ? "mcp" : "help")

        switch command {
        case "help":
            printHelp()
            return

        case "mcp", "doctor":
            do {
                let resolvedDir = libraryDir ?? ExternalAgentConfigStore.defaultDirectory()
                let engine = try LiveCharkleEngine.make(appSupportDirectory: resolvedDir, startAutoSync: false)
                let service = CharkleExternalAgentService(engine: engine, configDirectory: resolvedDir, notifyOnWrite: true)

                if command == "doctor" {
                    let report = await service.runDiagnostics()
                    print(CharkleExternalAgentService.encodeCompactJSON(report))
                    if (report["ok"] as? Bool) != true {
                        exit(1)
                    }
                    return
                }

                let policy = service.currentPolicy()
                if !policy.isEnabled(for: .stdio) && isatty(STDIN_FILENO) != 0 {
                    writeStderr("本机 MCP 服务（stdio）已在 Charkle「设置 → 外部 Agent」中关闭，请先开启后再试。\n")
                    exit(1)
                }
                await runMCPStdioLoop(service: service)
            } catch {
                writeStderr("Charkle MCP helper error: \(error.localizedDescription)\n")
                exit(1)
            }

        default:
            writeStderr("Charkle v2 exposes a pure MCP interface (CLI subcommands have been retired). Run `charkle mcp` for stdio MCP or connect via HTTP `/api/v1/mcp`.\n")
            exit(2)
        }
    }

    // MARK: - Non-Blocking Stdio MCP Server Loop (NDJSON + Content-Length Framing)

    private static func runMCPStdioLoop(service: CharkleExternalAgentService) async {
        setvbuf(stdout, nil, _IONBF, 0)
        // Prevent SIGPIPE from crashing if the MCP client disconnects mid-write.
        signal(SIGPIPE, SIG_IGN)

        let stdinStream = makeStdinChunkStream()
        var parser = MCPStdioFrameParser()

        for await chunk in stdinStream {
            for event in parser.append(chunk) {
                await dispatchMCPEvent(event, service: service)
            }
        }
        for event in parser.finishEOF() {
            await dispatchMCPEvent(event, service: service)
        }
    }

    private static func dispatchMCPEvent(
        _ event: MCPStdioFrameParser.Event,
        service: CharkleExternalAgentService
    ) async {
        switch event {
        case .message(let payload, let framing):
            if let reply = await service.handleJSONRPC(payload, context: .localStdio) {
                writeStdout(MCPStdioFrameParser.encode(reply, framing: framing))
            }
        case .invalidFrame(let reason, let framing):
            let errObj: [String: Any] = [
                "jsonrpc": "2.0",
                "id": NSNull(),
                "error": ["code": -32700, "message": "Parse error: \(reason)"]
            ]
            if let data = try? JSONSerialization.data(withJSONObject: errObj, options: [.sortedKeys]) {
                writeStdout(MCPStdioFrameParser.encode(data, framing: framing))
            }
        }
    }

    /// Reads blocking stdin off the Swift cooperative thread pool via a dedicated background DispatchQueue.
    private static func makeStdinChunkStream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "com.charkle.mcp.stdin", qos: .userInitiated)
            queue.async {
                var scratch = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let n = Darwin.read(STDIN_FILENO, &scratch, scratch.count)
                    if n > 0 {
                        continuation.yield(Data(scratch[0..<n]))
                    } else if n == 0 {
                        break // EOF
                    } else if errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
                continuation.finish()
            }
        }
    }

    private static func writeStdout(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = Darwin.write(STDOUT_FILENO, base.advanced(by: written), data.count - written)
                if n > 0 {
                    written += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    private static func writeStderr(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }

    private static func printHelp() {
        print("""
        charkle \(version) — Charkle Native MCP Server Helper (Pure MCP v2)

        USAGE:
          charkle mcp [--library-dir <path>]     Run stdio JSON-RPC 2.0 MCP server (10 safe tools)
          charkle doctor [--library-dir <path>]  Run internal diagnostics JSON check
          charkle --version                      Show MCP server version

        For cross-machine / remote Agents, connect via HTTP MCP at `http(s)://<host>:41937/api/v1/mcp`
        using a scoped Bearer token created in Charkle Settings → 外部 Agent.
        """)
    }
}
