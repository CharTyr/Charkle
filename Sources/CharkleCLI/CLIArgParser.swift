import Foundation

/// Deterministic command-line argument parser supporting:
/// - `--key value` and `--key=value`
/// - Short aliases (`-n`, `-f`, `-t`, `-o`, `-q`, `-j`, `-h`, `-v`)
/// - Repeated multi-value flags (`--tag a --tag b`) and CSV splitting
/// - Explicit boolean switches that NEVER swallow following positional arguments
/// - `--` end-of-options sentinel
struct ParsedCLIArgs: Sendable {
    let positionals: [String]
    let values: [String: [String]]
    let booleans: Set<String>

    func first(_ key: String) -> String? {
        values[key]?.last
    }

    func all(_ key: String) -> [String] {
        values[key] ?? []
    }

    func csvValues(_ key: String) -> [String] {
        all(key)
            .flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
            .filter { !$0.isEmpty }
    }

    func int(_ key: String) -> Int? {
        first(key).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func double(_ key: String) -> Double? {
        first(key).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func flag(_ key: String) -> Bool {
        if booleans.contains(key) { return true }
        if let raw = first(key)?.lowercased() {
            return raw == "true" || raw == "1" || raw == "yes"
        }
        return false
    }

    func optionalBool(_ key: String) -> Bool? {
        if booleans.contains(key) { return true }
        if let raw = first(key)?.lowercased() {
            switch raw {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    var wantsHelp: Bool {
        flag("help")
    }
}

enum CLIArgParser {
    /// Known boolean flags across all Charkle CLI commands so they never accidentally
    /// consume a trailing positional argument (e.g. `charkle search --inbox "coffee"`).
    static let knownBooleanFlags: Set<String> = [
        "help",
        "version",
        "json",
        "pretty",
        "compact",
        "human",
        "no-color",
        "inbox",
        "untagged",
        "trashed",
        "include-trashed",
        "subfolders",
        "no-subfolders",
        "diversify",
        "facets",
        "no-facets",
        "fast",
        "visual-rerank",
        "no-visual-rerank",
        "full",
        "pinned",
        "dark",
        "freeform",
        "restore",
        "accept-suggested",
        "include-image",
        "no-image",
        "refresh-rich",
        "root",
        "suggest",
        "contact-sheet"
    ]

    static let shortAliases: [Character: String] = [
        "h": "help",
        "v": "version",
        "j": "json",
        "n": "limit",
        "f": "folder",
        "t": "tag",
        "o": "out",
        "q": "query"
    ]

    private static func looksLikeFlag(_ token: String) -> Bool {
        if token == "--" { return true }
        if token.hasPrefix("--"), token.count > 2 { return true }
        if token.hasPrefix("-"), token.count == 2, let ch = token.last, shortAliases[ch] != nil {
            return true
        }
        return false
    }

    static func parse(_ args: [String], extraBooleans: Set<String> = []) -> ParsedCLIArgs {
        let bools = knownBooleanFlags.union(extraBooleans)
        var positionals: [String] = []
        var values: [String: [String]] = [:]
        var flags = Set<String>()

        var i = 0
        var literalOnly = false

        while i < args.count {
            let token = args[i]

            if literalOnly {
                positionals.append(token)
                i += 1
                continue
            }

            if token == "--" {
                literalOnly = true
                i += 1
                continue
            }

            if token.hasPrefix("--"), token.count > 2 {
                let body = String(token.dropFirst(2))
                if let eqIdx = body.firstIndex(of: "=") {
                    let key = String(body[..<eqIdx])
                    let val = String(body[body.index(after: eqIdx)...])
                    if bools.contains(key) {
                        let lower = val.lowercased()
                        if lower == "true" || lower == "1" || lower == "yes" {
                            flags.insert(key)
                            values[key] = nil
                        } else if lower == "false" || lower == "0" || lower == "no" {
                            flags.remove(key)
                            values[key, default: []].append("false")
                        } else {
                            values[key, default: []].append(val)
                        }
                    } else {
                        values[key, default: []].append(val)
                    }
                    i += 1
                } else if bools.contains(body) {
                    flags.insert(body)
                    values[body] = nil
                    i += 1
                } else if i + 1 < args.count, !looksLikeFlag(args[i + 1]) {
                    values[body, default: []].append(args[i + 1])
                    i += 2
                } else {
                    flags.insert(body)
                    i += 1
                }
                continue
            }

            if token.hasPrefix("-"), token.count == 2,
               let ch = token.last,
               let mapped = shortAliases[ch] {
                if bools.contains(mapped) {
                    flags.insert(mapped)
                    values[mapped] = nil
                    i += 1
                } else if i + 1 < args.count, !looksLikeFlag(args[i + 1]) {
                    values[mapped, default: []].append(args[i + 1])
                    i += 2
                } else {
                    flags.insert(mapped)
                    i += 1
                }
                continue
            }

            positionals.append(token)
            i += 1
        }

        return ParsedCLIArgs(positionals: positionals, values: values, booleans: flags)
    }

    /// Extracts global options (`--library-dir`, `--json`/`--pretty`, `--compact`, `--human`, `--no-color`) from raw CLI args
    /// while preserving subcommand arguments and positional tokens intact.
    struct GlobalOptions: Sendable {
        var libraryDir: URL?
        var explicitJSON: Bool = false
        var compactJSON: Bool = false
        var forceHuman: Bool = false
        var noColor: Bool = false
        var remaining: [String] = []
    }

    static func extractGlobalOptions(_ rawArgs: [String]) -> GlobalOptions {
        var opts = GlobalOptions()
        var i = 0
        var literalOnly = false

        while i < rawArgs.count {
            let token = rawArgs[i]
            if literalOnly {
                opts.remaining.append(token)
                i += 1
                continue
            }
            if token == "--" {
                literalOnly = true
                opts.remaining.append(token)
                i += 1
                continue
            }
            if token == "--library-dir", i + 1 < rawArgs.count, !looksLikeFlag(rawArgs[i + 1]) {
                let expanded = (rawArgs[i + 1] as NSString).expandingTildeInPath
                opts.libraryDir = URL(fileURLWithPath: expanded, isDirectory: true)
                i += 2
            } else if token.hasPrefix("--library-dir=") {
                let val = String(token.dropFirst("--library-dir=".count))
                let expanded = (val as NSString).expandingTildeInPath
                opts.libraryDir = URL(fileURLWithPath: expanded, isDirectory: true)
                i += 1
            } else if token == "--json" || token == "-j" || token == "--pretty" {
                opts.explicitJSON = true
                i += 1
            } else if token == "--compact" {
                opts.explicitJSON = true
                opts.compactJSON = true
                i += 1
            } else if token == "--human" {
                opts.forceHuman = true
                i += 1
            } else if token == "--no-color" {
                opts.noColor = true
                i += 1
            } else {
                opts.remaining.append(token)
                i += 1
            }
        }
        return opts
    }
}
