import CryptoKit
import Foundation
import os

private let updaterLogger = Logger(subsystem: "com.charkle.app", category: "Updater")

// MARK: - Semantic Versioning

/// Strict semantic version (`major.minor.patch` with optional `-prerelease` suffix).
/// Accepts optional leading `v`/`V` and ignores `+build` metadata during comparison.
public struct CharkleSemanticVersion: Comparable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init(major: Int, minor: Int = 0, patch: Int = 0, prerelease: String? = nil) {
        self.major = max(0, major)
        self.minor = max(0, minor)
        self.patch = max(0, patch)
        if let prerelease, !prerelease.isEmpty {
            self.prerelease = prerelease
        } else {
            self.prerelease = nil
        }
    }

    public init?(parsing raw: String) {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        guard !trimmed.isEmpty else { return nil }

        // Strip +build metadata per SemVer 2.0.0
        let withoutBuild: String
        if let plusIdx = trimmed.firstIndex(of: "+") {
            withoutBuild = String(trimmed[..<plusIdx])
        } else {
            withoutBuild = trimmed
        }

        // Split optional -prerelease suffix
        let corePart: String
        let prereleasePart: String?
        if let hyphenIdx = withoutBuild.firstIndex(of: "-") {
            corePart = String(withoutBuild[..<hyphenIdx])
            let suffix = String(withoutBuild[withoutBuild.index(after: hyphenIdx)...])
            guard !suffix.isEmpty else { return nil }
            prereleasePart = suffix
        } else {
            corePart = withoutBuild
            prereleasePart = nil
        }

        let segments = corePart.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 2 || segments.count == 3 else { return nil }

        var numbers: [Int] = []
        numbers.reserveCapacity(3)
        for segment in segments {
            guard !segment.isEmpty,
                  segment.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(segment),
                  value >= 0 else {
                return nil
            }
            numbers.append(value)
        }

        self.major = numbers[0]
        self.minor = numbers[1]
        self.patch = numbers.count == 3 ? numbers[2] : 0
        self.prerelease = prereleasePart
    }

    public var description: String {
        if let prerelease {
            return "\(major).\(minor).\(patch)-\(prerelease)"
        }
        return "\(major).\(minor).\(patch)"
    }

    public var tagString: String {
        "v\(description)"
    }

    public static func < (lhs: CharkleSemanticVersion, rhs: CharkleSemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (_?, nil):
            // A prerelease version has lower precedence than the matching stable release.
            return true
        case (nil, _?):
            return false
        case let (lPre?, rPre?):
            let lParts = lPre.split(separator: ".")
            let rParts = rPre.split(separator: ".")
            let count = min(lParts.count, rParts.count)
            for idx in 0..<count {
                let lSub = lParts[idx]
                let rSub = rParts[idx]
                if lSub == rSub { continue }
                let lInt = Int(lSub)
                let rInt = Int(rSub)
                switch (lInt, rInt) {
                case let (a?, b?):
                    return a < b
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lSub < rSub
                }
            }
            return lParts.count < rParts.count
        }
    }
}

// MARK: - GitHub Release DTOs & Domain Models

public struct GitHubReleaseAssetDTO: Decodable, Sendable, Equatable {
    public let name: String
    public let browserDownloadURL: URL
    public let size: Int64
    public let contentType: String?
    public let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
        case contentType = "content_type"
        case digest
    }

    public init(
        name: String,
        browserDownloadURL: URL,
        size: Int64,
        contentType: String? = nil,
        digest: String? = nil
    ) {
        self.name = name
        self.browserDownloadURL = browserDownloadURL
        self.size = size
        self.contentType = contentType
        self.digest = digest
    }
}

public struct GitHubReleaseDTO: Decodable, Sendable, Equatable {
    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlURL: URL
    public let draft: Bool
    public let prerelease: Bool
    public let publishedAt: Date?
    public let assets: [GitHubReleaseAssetDTO]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case draft
        case prerelease
        case publishedAt = "published_at"
        case assets
    }

    public init(
        tagName: String,
        name: String? = nil,
        body: String? = nil,
        htmlURL: URL,
        draft: Bool = false,
        prerelease: Bool = false,
        publishedAt: Date? = nil,
        assets: [GitHubReleaseAssetDTO] = []
    ) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlURL = htmlURL
        self.draft = draft
        self.prerelease = prerelease
        self.publishedAt = publishedAt
        self.assets = assets
    }
}

public struct AppReleaseUpdate: Sendable, Equatable, Identifiable {
    public var id: String { tagName }
    public let tagName: String
    public let version: CharkleSemanticVersion
    public let title: String
    public let releaseNotes: String
    public let releasePageURL: URL
    public let publishedAt: Date?
    public let assetName: String
    public let downloadURL: URL
    public let assetSizeBytes: Int64
    public let expectedSHA256: String?

    public init(
        tagName: String,
        version: CharkleSemanticVersion,
        title: String,
        releaseNotes: String,
        releasePageURL: URL,
        publishedAt: Date?,
        assetName: String,
        downloadURL: URL,
        assetSizeBytes: Int64,
        expectedSHA256: String?
    ) {
        self.tagName = tagName
        self.version = version
        self.title = title
        self.releaseNotes = releaseNotes
        self.releasePageURL = releasePageURL
        self.publishedAt = publishedAt
        self.assetName = assetName
        self.downloadURL = downloadURL
        self.assetSizeBytes = assetSizeBytes
        self.expectedSHA256 = expectedSHA256
    }
}

public enum UpdateCheckOutcome: Sendable, Equatable {
    case upToDate(currentVersion: CharkleSemanticVersion, latestVersion: CharkleSemanticVersion?)
    case updateAvailable(AppReleaseUpdate)
}

public struct DownloadProgress: Sendable, Equatable {
    public let downloadedBytes: Int64
    public let totalBytes: Int64
    public let fraction: Double

    public init(downloadedBytes: Int64, totalBytes: Int64, fraction: Double) {
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.fraction = fraction
    }
}

public struct StagedAppUpdate: Sendable, Equatable {
    public let workingDirectoryURL: URL
    public let dmgURL: URL
    public let stagedAppURL: URL
    public let verifiedSHA256: String
    public let bundleVersion: String?
    public let bundleShortVersion: String?

    public init(
        workingDirectoryURL: URL,
        dmgURL: URL,
        stagedAppURL: URL,
        verifiedSHA256: String,
        bundleVersion: String?,
        bundleShortVersion: String?
    ) {
        self.workingDirectoryURL = workingDirectoryURL
        self.dmgURL = dmgURL
        self.stagedAppURL = stagedAppURL
        self.verifiedSHA256 = verifiedSHA256
        self.bundleVersion = bundleVersion
        self.bundleShortVersion = bundleShortVersion
    }
}

public enum InstallTargetEligibility: Sendable, Equatable {
    case eligible(targetAppURL: URL)
    case manualInstallRequired(reason: String)
}

// MARK: - Errors

public enum GitHubReleaseUpdaterError: LocalizedError, Sendable, Equatable {
    case invalidEndpoint
    case rateLimited
    case httpError(statusCode: Int)
    case decodingFailed(String)
    case insecureDownloadURL
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case dmgMountFailed(String)
    case appBundleNotFoundInDMG
    case copyFailed(String)
    case invalidBundleIdentifier(found: String?)
    case codesignVerificationFailed(String)
    case launcherFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "更新服务地址配置无效。"
        case .rateLimited:
            return "GitHub API 请求频率受限，请稍后再试或前往 GitHub Releases 手动下载。"
        case .httpError(let statusCode):
            return "检查更新时服务器返回错误（HTTP \(statusCode)）。"
        case .decodingFailed(let detail):
            return "无法解析 GitHub Release 元数据：\(detail)"
        case .insecureDownloadURL:
            return "出于安全原因，仅允许通过 HTTPS 下载更新安装包。"
        case .downloadFailed(let detail):
            return "安装包下载失败：\(detail)"
        case .checksumMismatch(let expected, let actual):
            return "安装包 SHA-256 校验失败，文件可能已损坏或被篡改（预期 \(expected.prefix(12))…，实际 \(actual.prefix(12))…）。"
        case .dmgMountFailed(let detail):
            return "无法挂载磁盘映像（DMG）：\(detail)"
        case .appBundleNotFoundInDMG:
            return "安装包内未找到有效的 Charkle.app 应用包。"
        case .copyFailed(let detail):
            return "解压并暂存新版本应用包失败：\(detail)"
        case .invalidBundleIdentifier(let found):
            let actual = found ?? "空"
            return "安装包身份校验失败（CFBundleIdentifier 为 \(actual)，预期 com.charkle.app）。"
        case .codesignVerificationFailed(let detail):
            return "新版本代码签名严格校验未通过：\(detail)"
        case .launcherFailed(let detail):
            return "无法启动原子更新替换程序：\(detail)"
        }
    }
}

// MARK: - Throttle & Skipped-Version Policy + Preferences Persistence

/// Pure policy rules governing 6-hour automatic check throttling and skipped-version filtering.
public enum AppUpdateCheckPolicy {
    public static let defaultAutoCheckInterval: TimeInterval = 6 * 60 * 60

    public static func shouldRunAutomaticCheck(
        autoCheckEnabled: Bool,
        lastCheckAt: Date?,
        now: Date = Date(),
        interval: TimeInterval = defaultAutoCheckInterval
    ) -> Bool {
        guard autoCheckEnabled else { return false }
        guard let lastCheckAt else { return true }
        return now.timeIntervalSince(lastCheckAt) >= interval
    }

    public static func isVersionSkipped(
        _ version: CharkleSemanticVersion,
        skippedVersion: String?
    ) -> Bool {
        guard let skippedVersion else { return false }
        let trimmed = skippedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let parsedSkipped = CharkleSemanticVersion(parsing: trimmed) {
            return parsedSkipped == version
        }
        return trimmed == version.description || trimmed == version.tagString
    }

    public static func shouldNotifyForUpdate(
        _ version: CharkleSemanticVersion,
        skippedVersion: String?,
        isManual: Bool
    ) -> Bool {
        if isManual { return true }
        return !isVersionSkipped(version, skippedVersion: skippedVersion)
    }
}

/// Lightweight `UserDefaults` wrapper persisting update preferences, throttle timestamps, and skipped versions.
public struct AppUpdatePreferencesStore: Sendable {
    public enum Keys {
        public static let autoCheckUpdates = "charkle.updates.autoCheckUpdates"
        public static let lastUpdateCheckAt = "charkle.updates.lastUpdateCheckAt"
        public static let skippedVersion = "charkle.updates.skippedVersion"
    }

    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private func resolveDefaults() -> UserDefaults {
        if let suiteName, let custom = UserDefaults(suiteName: suiteName) {
            return custom
        }
        return .standard
    }

    public func loadAutoCheckUpdates() -> Bool {
        let defaults = resolveDefaults()
        return defaults.object(forKey: Keys.autoCheckUpdates) as? Bool ?? true
    }

    public func saveAutoCheckUpdates(_ enabled: Bool) {
        resolveDefaults().set(enabled, forKey: Keys.autoCheckUpdates)
    }

    public func loadLastUpdateCheckAt() -> Date? {
        let defaults = resolveDefaults()
        guard let timestamp = defaults.object(forKey: Keys.lastUpdateCheckAt) as? Double else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    public func saveLastUpdateCheckAt(_ date: Date?) {
        let defaults = resolveDefaults()
        if let date {
            defaults.set(date.timeIntervalSince1970, forKey: Keys.lastUpdateCheckAt)
        } else {
            defaults.removeObject(forKey: Keys.lastUpdateCheckAt)
        }
    }

    public func loadSkippedVersion() -> String? {
        let raw = resolveDefaults().string(forKey: Keys.skippedVersion)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false) ? raw : nil
    }

    public func saveSkippedVersion(_ version: String?) {
        let defaults = resolveDefaults()
        if let version, !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.set(version.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.skippedVersion)
        } else {
            defaults.removeObject(forKey: Keys.skippedVersion)
        }
    }
}

// MARK: - GitHub Releases Native Updater Service

/// Pure-Foundation native macOS updater powered directly by GitHub Releases (`CharTyr/Charkle`).
public struct GitHubReleaseUpdater: Sendable {
    public static let defaultOwner = "CharTyr"
    public static let defaultRepo = "Charkle"
    public static let defaultBundleIdentifier = "com.charkle.app"
    public static let releasesPageURL = URL(string: "https://github.com/CharTyr/Charkle/releases")!

    public let owner: String
    public let repo: String
    public let apiBaseURL: URL
    public let expectedBundleIdentifier: String

    public init(
        owner: String = defaultOwner,
        repo: String = defaultRepo,
        apiBaseURL: URL = URL(string: "https://api.github.com")!,
        expectedBundleIdentifier: String = defaultBundleIdentifier
    ) {
        self.owner = owner
        self.repo = repo
        self.apiBaseURL = apiBaseURL
        self.expectedBundleIdentifier = expectedBundleIdentifier
    }

    public var latestReleaseEndpointURL: URL {
        apiBaseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(owner)
            .appendingPathComponent(repo)
            .appendingPathComponent("releases")
            .appendingPathComponent("latest")
    }

    public var repositoryReleasesURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases") ?? Self.releasesPageURL
    }

    // MARK: - Check for Updates

    /// Queries GitHub Releases `/releases/latest` and evaluates whether a newer stable macOS DMG exists.
    public func checkForLatestRelease(
        currentVersion: CharkleSemanticVersion,
        session: URLSession = .shared
    ) async throws -> UpdateCheckOutcome {
        var request = URLRequest(url: latestReleaseEndpointURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Charkle/\(currentVersion.description)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubReleaseUpdaterError.httpError(statusCode: -1)
        }

        switch http.statusCode {
        case 200..<300:
            let release = try Self.decodeRelease(from: data)
            return Self.evaluateRelease(release, currentVersion: currentVersion)
        case 404:
            return .upToDate(currentVersion: currentVersion, latestVersion: nil)
        case 403, 429:
            throw GitHubReleaseUpdaterError.rateLimited
        default:
            throw GitHubReleaseUpdaterError.httpError(statusCode: http.statusCode)
        }
    }

    // MARK: - Release Decoding, Filtering & Asset Selection

    public static func decodeRelease(from data: Data) throws -> GitHubReleaseDTO {
        let decoder = makeGitHubJSONDecoder()
        do {
            return try decoder.decode(GitHubReleaseDTO.self, from: data)
        } catch {
            throw GitHubReleaseUpdaterError.decodingFailed(error.localizedDescription)
        }
    }

    public static func decodeReleases(from data: Data) throws -> [GitHubReleaseDTO] {
        let decoder = makeGitHubJSONDecoder()
        do {
            return try decoder.decode([GitHubReleaseDTO].self, from: data)
        } catch {
            throw GitHubReleaseUpdaterError.decodingFailed(error.localizedDescription)
        }
    }

    private static func makeGitHubJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) {
                return date
            }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(string)"
            )
        }
        return decoder
    }

    /// Evaluates a single decoded GitHub release against the currently installed version.
    /// Drafts, prereleases, non-newer versions, and releases without a macOS DMG asset return `.upToDate`.
    public static func evaluateRelease(
        _ release: GitHubReleaseDTO,
        currentVersion: CharkleSemanticVersion
    ) -> UpdateCheckOutcome {
        guard !release.draft, !release.prerelease else {
            return .upToDate(currentVersion: currentVersion, latestVersion: nil)
        }
        guard let remoteVersion = CharkleSemanticVersion(parsing: release.tagName) else {
            return .upToDate(currentVersion: currentVersion, latestVersion: nil)
        }
        guard remoteVersion > currentVersion else {
            return .upToDate(currentVersion: currentVersion, latestVersion: remoteVersion)
        }
        guard let asset = selectMacOSDMGAsset(from: release.assets) else {
            return .upToDate(currentVersion: currentVersion, latestVersion: remoteVersion)
        }

        let body = release.body ?? ""
        let resolvedSHA256 = extractMacOSSHA256(from: body)
            ?? extractSHA256FromAssetDigest(asset.digest)
        let title = {
            let trimmed = release.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "Charkle \(release.tagName)" : trimmed
        }()

        let update = AppReleaseUpdate(
            tagName: release.tagName,
            version: remoteVersion,
            title: title,
            releaseNotes: body,
            releasePageURL: release.htmlURL,
            publishedAt: release.publishedAt,
            assetName: asset.name,
            downloadURL: asset.browserDownloadURL,
            assetSizeBytes: asset.size,
            expectedSHA256: resolvedSHA256
        )
        return .updateAvailable(update)
    }

    /// Evaluates a list of releases (e.g., `/releases`), filtering out drafts/prereleases and choosing
    /// the highest semantic version that offers a macOS DMG asset.
    public static func evaluateReleases(
        _ releases: [GitHubReleaseDTO],
        currentVersion: CharkleSemanticVersion
    ) -> UpdateCheckOutcome {
        let candidates: [(version: CharkleSemanticVersion, release: GitHubReleaseDTO)] = releases.compactMap { release in
            guard !release.draft, !release.prerelease else { return nil }
            guard let version = CharkleSemanticVersion(parsing: release.tagName) else { return nil }
            return (version, release)
        }
        .sorted { $0.version > $1.version }

        for candidate in candidates {
            if candidate.version <= currentVersion {
                return .upToDate(currentVersion: currentVersion, latestVersion: candidate.version)
            }
            if case .updateAvailable(let update) = evaluateRelease(candidate.release, currentVersion: currentVersion) {
                return .updateAvailable(update)
            }
        }
        return .upToDate(currentVersion: currentVersion, latestVersion: candidates.first?.version)
    }

    /// Selects the best macOS `.dmg` asset: prefers Apple Silicon (`*arm64*.dmg`),
    /// then universal `.dmg`, then any other `.dmg` (always excluding Windows installers).
    public static func selectMacOSDMGAsset(from assets: [GitHubReleaseAssetDTO]) -> GitHubReleaseAssetDTO? {
        let dmgAssets = assets.filter { asset in
            let lower = asset.name.lowercased()
            guard lower.hasSuffix(".dmg") else { return false }
            guard !lower.hasSuffix(".exe"),
                  !lower.hasSuffix(".msi"),
                  !lower.contains("windows") else {
                return false
            }
            return true
        }

        if let arm64 = dmgAssets.first(where: {
            let lower = $0.name.lowercased()
            return lower.contains("arm64") || lower.contains("aarch64") || lower.contains("apple-silicon")
        }) {
            return arm64
        }

        if let universal = dmgAssets.first(where: { $0.name.lowercased().contains("universal") }) {
            return universal
        }

        return dmgAssets.first
    }

    // MARK: - macOS-Scoped SHA-256 Extraction

    /// Extracts a 64-character lowercase hex SHA-256 checksum from dual-platform release notes.
    /// Searches inside a `## macOS` (or `### macOS`) Markdown section first so Windows checksums
    /// never collide with macOS. If no macOS section is present, strips any Windows sections and
    /// searches the remaining body (preferring `.dmg`-associated lines).
    public static func extractMacOSSHA256(from releaseBody: String) -> String? {
        let normalized = releaseBody
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // 1. Check inside explicit macOS Markdown section(s) first.
        if let macOSSection = extractMarkdownSection(from: lines, matchingKeyword: "macos") {
            if let hash = findSHA256(in: macOSSection, avoidWindowsLines: false) {
                return hash
            }
        }

        // 2. Fall back to non-Windows body so single-platform release notes work seamlessly
        //    while Windows-only checksums inside `## Windows` are never misattributed to macOS.
        let withoutWindows = stripMarkdownSections(from: lines, matchingKeyword: "windows")
        return findSHA256(in: withoutWindows, avoidWindowsLines: true)
    }

    private static func extractSHA256FromAssetDigest(_ digest: String?) -> String? {
        guard let digest else { return nil }
        var trimmed = digest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("sha256:") {
            trimmed.removeFirst("sha256:".count)
        }
        guard trimmed.count == 64, trimmed.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            return nil
        }
        return trimmed
    }

    private static func markdownHeadingInfo(_ line: String) -> (level: Int, title: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        for ch in trimmed {
            if ch == "#" {
                level += 1
            } else {
                break
            }
        }
        guard level >= 1 && level <= 6 else { return nil }
        let remainder = trimmed.dropFirst(level)
        guard remainder.first == " " || remainder.first == "\t" else { return nil }
        return (level, remainder.trimmingCharacters(in: .whitespaces))
    }

    private static func extractMarkdownSection(from lines: [String], matchingKeyword keyword: String) -> [String]? {
        var collected: [String] = []
        var activeLevel: Int? = nil
        var foundAny = false

        for line in lines {
            if let heading = markdownHeadingInfo(line) {
                if let current = activeLevel, heading.level <= current {
                    activeLevel = nil
                }
                if activeLevel == nil && heading.title.lowercased().contains(keyword) {
                    activeLevel = heading.level
                    foundAny = true
                    collected.append(line)
                    continue
                }
            }
            if activeLevel != nil {
                collected.append(line)
            }
        }

        return foundAny ? collected : nil
    }

    private static func stripMarkdownSections(from lines: [String], matchingKeyword keyword: String) -> [String] {
        var kept: [String] = []
        var skippingLevel: Int? = nil

        for line in lines {
            if let heading = markdownHeadingInfo(line) {
                if let current = skippingLevel, heading.level <= current {
                    skippingLevel = nil
                }
                if skippingLevel == nil && heading.title.lowercased().contains(keyword) {
                    skippingLevel = heading.level
                    continue
                }
            }
            if skippingLevel == nil {
                kept.append(line)
            }
        }
        return kept
    }

    private static func findSHA256(in lines: [String], avoidWindowsLines: Bool) -> String? {
        let candidateLines = avoidWindowsLines
            ? lines.filter { line in
                let lower = line.lowercased()
                return !lower.contains(".exe")
                    && !lower.contains(".msi")
                    && !lower.contains("windows")
                    && !lower.contains("setup-")
            }
            : lines

        // Priority 1: lines explicitly referencing .dmg / arm64 / macos alongside a 64-hex token.
        for line in candidateLines {
            let lower = line.lowercased()
            if (lower.contains(".dmg") || lower.contains("arm64") || lower.contains("macos")),
               let hex = first64HexToken(in: line) {
                return hex
            }
        }

        // Priority 2: lines explicitly mentioning sha-256 / sha256 / checksum.
        for line in candidateLines {
            let lower = line.lowercased()
            if (lower.contains("sha-256") || lower.contains("sha256") || lower.contains("checksum") || lower.contains("校验")),
               let hex = first64HexToken(in: line) {
                return hex
            }
        }

        // Priority 3: any standalone 64-hex SHA-256 token in the scoped lines.
        for line in candidateLines {
            if let hex = first64HexToken(in: line) {
                return hex
            }
        }

        return nil
    }

    private static func first64HexToken(in text: String) -> String? {
        var runStart: String.Index?
        var runCount = 0

        for idx in text.indices {
            let ch = text[idx]
            if ch.isASCII && ch.isHexDigit {
                if runStart == nil { runStart = idx }
                runCount += 1
            } else {
                if runCount == 64, let start = runStart {
                    return String(text[start..<idx]).lowercased()
                }
                runStart = nil
                runCount = 0
            }
        }
        if runCount == 64, let start = runStart {
            return String(text[start...]).lowercased()
        }
        return nil
    }

    // MARK: - Streaming DMG Download with Live Progress & Cancellation

    /// Creates a fresh isolated temporary staging directory under `FileManager.default.temporaryDirectory`.
    public static func makeStagingDirectory(fileManager: FileManager = .default) throws -> URL {
        let dir = fileManager.temporaryDirectory
            .appendingPathComponent("charkle-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Streams a macOS `.dmg` from GitHub Releases directly to disk with live progress and cooperative cancellation.
    public func downloadDMG(
        from url: URL,
        suggestedFilename: String,
        expectedSizeBytes: Int64,
        into directoryURL: URL,
        userAgentVersion: CharkleSemanticVersion,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        guard url.scheme?.lowercased() == "https" else {
            throw GitHubReleaseUpdaterError.insecureDownloadURL
        }

        try Task.checkCancellation()

        let safeFilename = sanitizedAssetFilename(suggestedFilename)
        let destinationURL = directoryURL.appendingPathComponent(safeFilename, isDirectory: false)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        let delegate = DMGDownloadDelegate(
            destinationURL: destinationURL,
            expectedSizeBytes: expectedSizeBytes,
            onProgress: onProgress
        )

        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Charkle/\(userAgentVersion.description)", forHTTPHeaderField: "User-Agent")

        defer {
            session.finishTasksAndInvalidate()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request)
                let shouldStart = delegate.attach(continuation: continuation, task: task)
                if shouldStart {
                    task.resume()
                } else {
                    task.cancel()
                }
            }
        } onCancel: {
            delegate.cancel()
        }
    }

    private func sanitizedAssetFilename(_ raw: String) -> String {
        let candidate = URL(fileURLWithPath: raw).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty || candidate == "." || candidate == ".." || !candidate.lowercased().hasSuffix(".dmg") {
            return "Charkle-update.dmg"
        }
        return candidate
    }

    // MARK: - CryptoKit SHA-256 Verification

    /// Computes the lowercase 64-character SHA-256 hex digest of a file on disk using streaming 1 MB chunks.
    public static func sha256Hex(ofFileAt fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1_048_576
        while true {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Verifies a file's CryptoKit SHA-256 digest against an expected 64-hex checksum.
    @discardableResult
    public static func verifySHA256(ofFileAt fileURL: URL, expectedHex: String) throws -> String {
        var normalizedExpected = expectedHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedExpected.hasPrefix("sha256:") {
            normalizedExpected.removeFirst("sha256:".count)
        }
        let actualHex = try sha256Hex(ofFileAt: fileURL)
        guard actualHex == normalizedExpected else {
            throw GitHubReleaseUpdaterError.checksumMismatch(expected: normalizedExpected, actual: actualHex)
        }
        return actualHex
    }

    // MARK: - Safe DMG Mount, Staging, Info.plist & Strict Codesign Verification

    /// Verifies SHA-256, mounts the DMG read-only (`-nobrowse`), stages `Charkle.app` via `ditto --norsrc --noextattr`,
    /// strips xattrs, validates `Info.plist` (`CFBundleIdentifier`) and `codesign --verify --deep --strict`,
    /// and guarantees DMG detachment in cleanup. Runs off the caller's actor via `@concurrent`.
    @concurrent
    public func stageAndVerifyDMG(
        dmgURL: URL,
        workingDirectoryURL: URL,
        expectedSHA256: String?
    ) async throws -> StagedAppUpdate {
        try Task.checkCancellation()

        // 1. CryptoKit SHA-256 digest & verification
        let actualSHA256: String
        if let expectedSHA256, !expectedSHA256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            actualSHA256 = try Self.verifySHA256(ofFileAt: dmgURL, expectedHex: expectedSHA256)
        } else {
            actualSHA256 = try Self.sha256Hex(ofFileAt: dmgURL)
        }

        try Task.checkCancellation()

        let fileManager = FileManager.default
        let mountPoint = workingDirectoryURL.appendingPathComponent("mount", isDirectory: true)
        let stagedAppURL = workingDirectoryURL.appendingPathComponent("Charkle.app", isDirectory: true)

        try? fileManager.removeItem(at: mountPoint)
        try? fileManager.removeItem(at: stagedAppURL)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        // 2. Mount DMG read-only and hidden from Finder
        let attachResult = try Self.runProcess(
            executablePath: "/usr/bin/hdiutil",
            arguments: [
                "attach",
                "-nobrowse",
                "-readonly",
                "-noautoopen",
                "-mountpoint", mountPoint.path,
                dmgURL.path
            ]
        )
        guard attachResult.terminationStatus == 0 else {
            try? fileManager.removeItem(at: mountPoint)
            throw GitHubReleaseUpdaterError.dmgMountFailed(attachResult.summaryOutput)
        }

        // Always detach DMG cleanly even on errors or cancellation
        defer {
            let detach = try? Self.runProcess(
                executablePath: "/usr/bin/hdiutil",
                arguments: ["detach", mountPoint.path, "-quiet"]
            )
            if detach?.terminationStatus != 0 {
                _ = try? Self.runProcess(
                    executablePath: "/usr/bin/hdiutil",
                    arguments: ["detach", mountPoint.path, "-force", "-quiet"]
                )
            }
            try? fileManager.removeItem(at: mountPoint)
        }

        try Task.checkCancellation()

        // 3. Locate Charkle.app inside mounted volume
        guard let mountedAppURL = locateAppBundle(in: mountPoint, fileManager: fileManager) else {
            throw GitHubReleaseUpdaterError.appBundleNotFoundInDMG
        }

        // 4. Copy via ditto without resource forks or extended attributes
        let dittoResult = try Self.runProcess(
            executablePath: "/usr/bin/ditto",
            arguments: ["--norsrc", "--noextattr", mountedAppURL.path, stagedAppURL.path]
        )
        guard dittoResult.terminationStatus == 0 else {
            throw GitHubReleaseUpdaterError.copyFailed(dittoResult.summaryOutput)
        }

        try Task.checkCancellation()

        // 5. Strip any extended attributes (including quarantine / FileProvider detritus)
        _ = try? Self.runProcess(
            executablePath: "/usr/bin/xattr",
            arguments: ["-cr", stagedAppURL.path]
        )

        // 6. Verify Info.plist CFBundleIdentifier == "com.charkle.app"
        let plistMetadata = try verifyStagedAppInfoPlist(at: stagedAppURL)

        // 7. Strict deep code-signature verification on staged .app
        let codesignResult = try Self.runProcess(
            executablePath: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", stagedAppURL.path]
        )
        guard codesignResult.terminationStatus == 0 else {
            throw GitHubReleaseUpdaterError.codesignVerificationFailed(codesignResult.summaryOutput)
        }

        updaterLogger.notice("Staged and verified update bundle at \(stagedAppURL.lastPathComponent, privacy: .public) (sha256: \(actualSHA256.prefix(12), privacy: .public))")

        return StagedAppUpdate(
            workingDirectoryURL: workingDirectoryURL,
            dmgURL: dmgURL,
            stagedAppURL: stagedAppURL,
            verifiedSHA256: actualSHA256,
            bundleVersion: plistMetadata.bundleVersion,
            bundleShortVersion: plistMetadata.shortVersion
        )
    }

    private func locateAppBundle(in mountPoint: URL, fileManager: FileManager) -> URL? {
        let direct = mountPoint.appendingPathComponent("Charkle.app", isDirectory: true)
        if fileManager.fileExists(atPath: direct.appendingPathComponent("Contents/Info.plist").path) {
            return direct
        }
        guard let items = try? fileManager.contentsOfDirectory(
            at: mountPoint,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for item in items where item.pathExtension.lowercased() == "app" {
            let plistURL = item.appendingPathComponent("Contents/Info.plist")
            if let data = try? Data(contentsOf: plistURL),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               (plist["CFBundleIdentifier"] as? String) == expectedBundleIdentifier {
                return item
            }
        }
        return nil
    }

    private func verifyStagedAppInfoPlist(
        at appURL: URL
    ) throws -> (bundleVersion: String?, shortVersion: String?) {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw GitHubReleaseUpdaterError.invalidBundleIdentifier(found: nil)
        }
        let bundleID = plist["CFBundleIdentifier"] as? String
        guard bundleID == expectedBundleIdentifier else {
            throw GitHubReleaseUpdaterError.invalidBundleIdentifier(found: bundleID)
        }
        return (
            bundleVersion: plist["CFBundleVersion"] as? String,
            shortVersion: plist["CFBundleShortVersionString"] as? String
        )
    }

    // MARK: - Atomic Self-Update Target Eligibility & Shell-Safe Launcher

    /// Verifies whether the currently running bundle can be atomically replaced in place.
    /// Rejects bare `swift run` binaries, read-only `/Volumes/...` DMG mounts, AppTranslocation,
    /// and non-writable directories.
    public static func evaluateInstallTarget(
        bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> InstallTargetEligibility {
        let standardized = bundleURL.standardizedFileURL
        let path = standardized.path

        guard standardized.pathExtension.lowercased() == "app",
              fileManager.fileExists(atPath: standardized.appendingPathComponent("Contents/Info.plist").path) else {
            return .manualInstallRequired(
                reason: "当前正以开发二进制方式运行，无法原地替换应用包；请直接打开已校验的安装包完成安装。"
            )
        }

        if path.hasPrefix("/Volumes/") {
            return .manualInstallRequired(
                reason: "当前正从只读磁盘映像卷运行，无法原地覆盖；请打开安装包并将 Charkle 拖入「应用程序」文件夹。"
            )
        }

        if path.contains("/AppTranslocation/") {
            return .manualInstallRequired(
                reason: "当前位于 macOS 安全隔离目录运行，无法原地更新；请打开安装包并将 Charkle 拖入「应用程序」文件夹。"
            )
        }

        let parentDir = standardized.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: parentDir.path),
              fileManager.isWritableFile(atPath: path) else {
            return .manualInstallRequired(
                reason: "当前应用所在目录缺少写入权限，无法自动替换；请打开已验证的安装包手动覆盖安装。"
            )
        }

        return .eligible(targetAppURL: standardized)
    }

    /// POSIX `/bin/sh` single-quote escaping (`'` -> `'\''`, wrapped in single quotes).
    /// Neutralizes `$()`, backticks, variables, globs, spaces, newlines, and quotes completely.
    public static func shellSingleQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Builds a self-contained `/bin/sh` atomic replace-and-relaunch script with zero shell injection
    /// and full backup rollback on failure.
    public static func buildAtomicReplaceScript(
        pid: Int32,
        stagedAppURL: URL,
        targetAppURL: URL,
        workingDirectoryURL: URL
    ) -> String {
        let quotedStaged = shellSingleQuote(stagedAppURL.standardizedFileURL.path)
        let quotedTarget = shellSingleQuote(targetAppURL.standardizedFileURL.path)
        let quotedWorkdir = shellSingleQuote(workingDirectoryURL.standardizedFileURL.path)

        return """
        #!/bin/sh
        trap '' HUP
        set -eu
        PID=\(pid)
        STAGED=\(quotedStaged)
        TARGET=\(quotedTarget)
        WORKDIR=\(quotedWorkdir)
        BACKUP="${TARGET}.charkle-backup-${PID}"
        NEW_TEMP="${TARGET}.charkle-new-${PID}"

        ATTEMPTS=0
        while kill -0 "$PID" 2>/dev/null; do
          ATTEMPTS=$((ATTEMPTS + 1))
          if [ "$ATTEMPTS" -ge 150 ]; then
            exit 1
          fi
          sleep 0.2
        done

        restore_backup() {
          if [ -d "$BACKUP" ] && [ ! -d "$TARGET" ]; then
            mv "$BACKUP" "$TARGET" 2>/dev/null || true
          fi
        }

        rm -rf "$BACKUP" "$NEW_TEMP"

        if ! mv "$STAGED" "$NEW_TEMP" 2>/dev/null; then
          rm -rf "$NEW_TEMP"
          if ! ditto --norsrc --noextattr "$STAGED" "$NEW_TEMP"; then
            rm -rf "$NEW_TEMP"
            exit 1
          fi
        fi

        xattr -cr "$NEW_TEMP" 2>/dev/null || true

        if [ -d "$TARGET" ]; then
          if ! mv "$TARGET" "$BACKUP"; then
            rm -rf "$NEW_TEMP"
            exit 1
          fi
        fi

        if ! mv "$NEW_TEMP" "$TARGET"; then
          rm -rf "$TARGET"
          restore_backup
          rm -rf "$NEW_TEMP"
          exit 1
        fi

        rm -rf "$BACKUP" "$WORKDIR"
        open -n "$TARGET"
        """
    }

    /// Spawns the detached `/bin/sh` helper that waits for the current PID to terminate,
    /// atomically swaps the verified staged `.app` bundle into place, cleans up staging files,
    /// and relaunches the updated app.
    public func launchAtomicSelfUpdate(
        stagedAppURL: URL,
        targetAppURL: URL,
        workingDirectoryURL: URL,
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws {
        let script = Self.buildAtomicReplaceScript(
            pid: currentPID,
            stagedAppURL: stagedAppURL,
            targetAppURL: targetAppURL,
            workingDirectoryURL: workingDirectoryURL
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw GitHubReleaseUpdaterError.launcherFailed(error.localizedDescription)
        }
    }

    // MARK: - Subprocess Helper

    private struct ProcessOutput: Sendable {
        let terminationStatus: Int32
        let output: String

        var summaryOutput: String {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "退出码 \(terminationStatus)"
            }
            if trimmed.count > 260 {
                return String(trimmed.prefix(260)) + "…"
            }
            return trimmed
        }
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String]
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        // Close parent write handle before reading to EOF so we never deadlock on full pipe buffers.
        try? pipe.fileHandleForWriting.close()
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(data: outputData, encoding: .utf8) ?? ""
        return ProcessOutput(terminationStatus: process.terminationStatus, output: text)
    }
}

// MARK: - Thread-Safe URLSessionDownloadDelegate

private final class DMGDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<URL, any Error>?
        var task: URLSessionDownloadTask?
        var isCancelled: Bool = false
        var isFinished: Bool = false
        var lastReportedTime: TimeInterval = 0
        var lastReportedFraction: Double = -1
    }

    private let destinationURL: URL
    private let expectedSizeBytes: Int64
    private let onProgress: @Sendable (DownloadProgress) -> Void
    private let lock = OSAllocatedUnfairLock(initialState: State())

    init(
        destinationURL: URL,
        expectedSizeBytes: Int64,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) {
        self.destinationURL = destinationURL
        self.expectedSizeBytes = expectedSizeBytes
        self.onProgress = onProgress
    }

    func attach(
        continuation: CheckedContinuation<URL, any Error>,
        task: URLSessionDownloadTask
    ) -> Bool {
        let alreadyCancelled: Bool = lock.withLock { state in
            if state.isCancelled {
                state.isFinished = true
                return true
            }
            state.continuation = continuation
            state.task = task
            return false
        }
        if alreadyCancelled {
            continuation.resume(throwing: CancellationError())
            return false
        }
        return true
    }

    func cancel() {
        let (task, continuation): (URLSessionDownloadTask?, CheckedContinuation<URL, any Error>?) = lock.withLock { state in
            state.isCancelled = true
            let currentTask = state.task
            state.task = nil
            guard !state.isFinished else { return (currentTask, nil) }
            state.isFinished = true
            let cont = state.continuation
            state.continuation = nil
            return (currentTask, cont)
        }
        task?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    private func finish(with result: Result<URL, any Error>) {
        let continuation: CheckedContinuation<URL, any Error>? = lock.withLock { state in
            guard !state.isFinished else { return nil }
            state.isFinished = true
            state.task = nil
            let cont = state.continuation
            state.continuation = nil
            return cont
        }
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : max(expectedSizeBytes, totalBytesWritten)
        let fraction = total > 0 ? min(1.0, max(0.0, Double(totalBytesWritten) / Double(total))) : 0.0
        let now = ProcessInfo.processInfo.systemUptime

        let shouldEmit: Bool = lock.withLock { state in
            guard !state.isFinished && !state.isCancelled else { return false }
            let elapsed = now - state.lastReportedTime
            let delta = abs(fraction - state.lastReportedFraction)
            if elapsed >= 0.08 || delta >= 0.015 || fraction >= 1.0 || state.lastReportedFraction < 0 {
                state.lastReportedTime = now
                state.lastReportedFraction = fraction
                return true
            }
            return false
        }

        if shouldEmit {
            onProgress(
                DownloadProgress(
                    downloadedBytes: totalBytesWritten,
                    totalBytes: total,
                    fraction: fraction
                )
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            finish(with: .failure(GitHubReleaseUpdaterError.httpError(statusCode: http.statusCode)))
            return
        }

        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: location, to: destinationURL)
            let attrs = try? fileManager.attributesOfItem(atPath: destinationURL.path)
            let finalSize = (attrs?[.size] as? NSNumber)?.int64Value ?? expectedSizeBytes
            onProgress(DownloadProgress(downloadedBytes: finalSize, totalBytes: max(finalSize, expectedSizeBytes), fraction: 1.0))
            finish(with: .success(destinationURL))
        } catch {
            finish(with: .failure(GitHubReleaseUpdaterError.downloadFailed(error.localizedDescription)))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                finish(with: .failure(CancellationError()))
            } else {
                finish(with: .failure(GitHubReleaseUpdaterError.downloadFailed(error.localizedDescription)))
            }
        } else {
            // Defensive fallback: if finished without didFinishDownloadingTo resuming the continuation
            finish(with: .failure(GitHubReleaseUpdaterError.downloadFailed("下载已结束但未收到安装包文件。")))
        }
    }
}
