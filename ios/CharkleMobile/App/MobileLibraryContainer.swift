import Foundation

/// Shared storage and cross-process handoff coordinator between `CharkleMobile` and `CharkleShareExtension`.
///
/// - Automatically discovers the active App Group container even when a sideloader / re-signer
///   rewrites the App Group identifier inside `embedded.mobileprovision`.
/// - Keeps `rootDirectory()` stable so existing local SQLite databases are never orphaned.
/// - Provides direct zero-App-Group handoff (`charkle-mobile://import?payload=...` for URLs/text and
///   short-lived local-only pasteboard envelopes for shared images/files) so Share Extension imports
///   work reliably even on unsigned / re-signed builds where App Groups are stripped.
public nonisolated enum MobileLibraryContainer {
    public static let appGroupIdentifier = "group.com.charkle.mobile"
    public static let deepLinkScheme = "charkle-mobile"
    public static let pasteboardShareTypeIdentifier = "com.charkle.mobile.pending-share-v1"

    /// Process-lifetime cached App Group container URL so hot callers (`reloadAll`, `sharedFoldersIndexURL`,
    /// `listPendingCaptureFiles`) never repeatedly read and parse `embedded.mobileprovision` on MainActor.
    private static let cachedSharedAppGroupContainerURL: URL? = resolveSharedAppGroupContainerURL()

    /// Resolves a genuine OS-granted shared App Group container URL, or `nil` when no App Group
    /// entitlement is active for this process (never falls back to the process-private sandbox).
    public static func sharedAppGroupContainerURL() -> URL? {
        cachedSharedAppGroupContainerURL
    }

    private static func resolveSharedAppGroupContainerURL() -> URL? {
        let fm = FileManager.default
        for candidate in candidateAppGroupIdentifiers() {
            if let url = fm.containerURL(forSecurityApplicationGroupIdentifier: candidate) {
                return url
            }
        }
        return nil
    }

    public static var isAppGroupAvailable: Bool {
        sharedAppGroupContainerURL() != nil
    }

    private static func candidateAppGroupIdentifiers() -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            ordered.append(trimmed)
        }

        // 1. Dynamically discover any App Group granted in embedded.mobileprovision (handles re-signed IPAs)
        for provisioned in embeddedMobileProvisionAppGroups() {
            add(provisioned)
        }

        // 2. Canonical bundle-default App Group
        add(appGroupIdentifier)

        // 3. Derived `group.<hostBundleID>` convention used by common sideloading signers
        if let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty {
            let hostBundleID: String
            if bundleID.hasSuffix(".share") {
                hostBundleID = String(bundleID.dropLast(".share".count))
            } else {
                hostBundleID = bundleID
            }
            add("group.\(hostBundleID)")
        }

        return ordered
    }

    private static func embeddedMobileProvisionAppGroups() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let rawData = try? Data(contentsOf: url),
              let startRange = rawData.range(of: Data("<plist".utf8)),
              let endRange = rawData.range(of: Data("</plist>".utf8), in: startRange.lowerBound..<rawData.endIndex) else {
            return []
        }
        let plistData = rawData.subdata(in: startRange.lowerBound..<endRange.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else {
            return []
        }
        return groups
    }

    /// Stable root directory for `Library.sqlite3` and cached media inside the host app.
    public static func rootDirectory() -> URL {
        let fm = FileManager.default
        let base: URL
        if let groupURL = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            base = groupURL.appending(path: "Charkle", directoryHint: .isDirectory)
        } else if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            base = appSupport.appending(path: "Charkle", directoryHint: .isDirectory)
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory())
                .appending(path: "Library/Application Support/Charkle", directoryHint: .isDirectory)
        }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Shared directory readable by both `CharkleMobile` and `CharkleShareExtension` when an App Group is active.
    public static func sharedExchangeDirectory() -> URL? {
        guard let groupURL = sharedAppGroupContainerURL() else { return nil }
        let base = groupURL.appending(path: "Charkle", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public static func pendingCapturesDirectory() -> URL {
        let base = sharedExchangeDirectory() ?? rootDirectory()
        let dir = base.appending(path: "PendingCaptures", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Returns all unique candidate PendingCaptures directories (shared App Group + legacy local root).
    public static func allPendingCapturesDirectories() -> [URL] {
        var dirs: [URL] = []
        var seen = Set<String>()
        if let shared = sharedExchangeDirectory() {
            let sharedPending = shared.appending(path: "PendingCaptures", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: sharedPending, withIntermediateDirectories: true)
            let path = sharedPending.standardizedFileURL.path
            if seen.insert(path).inserted { dirs.append(sharedPending) }
        }
        let localPending = rootDirectory().appending(path: "PendingCaptures", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: localPending, withIntermediateDirectories: true)
        let localPath = localPending.standardizedFileURL.path
        if seen.insert(localPath).inserted { dirs.append(localPending) }
        return dirs
    }

    public static func sharedFoldersIndexURL() -> URL {
        let base = sharedExchangeDirectory() ?? rootDirectory()
        return base.appending(path: "shared-folders.json", directoryHint: .notDirectory)
    }

    public static func saveSharedFoldersSnapshot(_ folders: [SharedFolderSummary]) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(folders) else { return }
        try? data.write(to: sharedFoldersIndexURL(), options: .atomic)
    }

    public static func loadSharedFoldersSnapshot() -> [SharedFolderSummary] {
        guard let data = try? Data(contentsOf: sharedFoldersIndexURL()),
              let decoded = try? JSONDecoder().decode([SharedFolderSummary].self, from: data) else {
            return []
        }
        return decoded
    }

    public static func enqueuePendingCapture(_ payload: PendingSharePayload) throws {
        let fileURL = pendingCapturesDirectory().appending(path: "capture-\(payload.id.uuidString).json")
        let data = try JSONEncoder().encode(payload)
        try data.write(to: fileURL, options: .atomic)
    }

    public static func listPendingCaptureFiles() -> [URL] {
        var result: [URL] = []
        for dir in allPendingCapturesDirectories() {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            let matching = items
                .filter { $0.lastPathComponent.hasPrefix("capture-") && $0.pathExtension.lowercased() == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            result.append(contentsOf: matching)
        }
        return result
    }

    // MARK: - Zero-App-Group Direct Deep-Link & Pasteboard Handoff

    /// Encodes lightweight URL/text payloads directly into `charkle-mobile://import?payload=<base64url>`
    /// so sharing works with zero App Groups and zero clipboard permission banners.
    public static func deepLinkImportURL(for payloads: [PendingSharePayload]) -> URL? {
        guard !payloads.isEmpty,
              let json = try? JSONEncoder().encode(payloads) else {
            return nil
        }
        let encoded = base64URLEncode(json)
        guard encoded.count <= 24_000 else { return nil }
        var comps = URLComponents()
        comps.scheme = deepLinkScheme
        comps.host = "import"
        comps.queryItems = [URLQueryItem(name: "payload", value: encoded)]
        return comps.url
    }

    public static func deepLinkPasteboardImportURL() -> URL {
        var comps = URLComponents()
        comps.scheme = deepLinkScheme
        comps.host = "import"
        comps.queryItems = [URLQueryItem(name: "source", value: "pasteboard")]
        return comps.url ?? URL(string: "\(deepLinkScheme)://import?source=pasteboard")!
    }

    public static func deepLinkQueueImportURL() -> URL {
        var comps = URLComponents()
        comps.scheme = deepLinkScheme
        comps.host = "import"
        comps.queryItems = [URLQueryItem(name: "source", value: "queue")]
        return comps.url ?? URL(string: "\(deepLinkScheme)://import?source=queue")!
    }

    public static func decodeDeepLinkImportPayloads(from url: URL) -> [PendingSharePayload]? {
        guard url.scheme?.lowercased() == deepLinkScheme,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = comps.queryItems?.first(where: { $0.name == "payload" })?.value,
              let data = base64URLDecode(raw),
              let payloads = try? JSONDecoder().decode([PendingSharePayload].self, from: data) else {
            return nil
        }
        return payloads
    }

    public static func deepLinkImportSource(from url: URL) -> String? {
        guard url.scheme?.lowercased() == deepLinkScheme,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return comps.queryItems?.first(where: { $0.name == "source" })?.value
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ raw: String) -> Data? {
        var base64 = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}

public nonisolated struct PasteboardShareEnvelope: Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let payloads: [PendingSharePayload]
    public let files: [String: Data]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        payloads: [PendingSharePayload],
        files: [String: Data] = [:]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.payloads = payloads
        self.files = files
    }
}

public nonisolated struct SharedFolderSummary: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let depth: Int
    public let colorHex: String?

    public init(id: UUID, name: String, depth: Int = 0, colorHex: String? = nil) {
        self.id = id
        self.name = name
        self.depth = depth
        self.colorHex = colorHex
    }
}

public nonisolated struct PendingSharePayload: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case file
        case webURL
        case text
    }

    public let id: UUID
    public let kind: Kind
    public let stagedFileName: String?
    public let originalFileName: String?
    public let urlString: String?
    public let text: String?
    public let title: String?
    public let notes: String?
    public let tags: [String]
    public let targetFolderID: UUID?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        stagedFileName: String? = nil,
        originalFileName: String? = nil,
        urlString: String? = nil,
        text: String? = nil,
        title: String? = nil,
        notes: String? = nil,
        tags: [String] = [],
        targetFolderID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.stagedFileName = stagedFileName
        self.originalFileName = originalFileName
        self.urlString = urlString
        self.text = text
        self.title = title
        self.notes = notes
        self.tags = tags
        self.targetFolderID = targetFolderID
        self.createdAt = createdAt
    }
}
