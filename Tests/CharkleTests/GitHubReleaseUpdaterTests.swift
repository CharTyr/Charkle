import CharkleCore
import CryptoKit
import Foundation
import Testing

@Suite("Native GitHub Releases Updater Tests")
struct GitHubReleaseUpdaterTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CharkleTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    private func readSource(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 1. SemVer Parsing & Comparison

    @Test("CharkleSemanticVersion strips leading v, parses major.minor.patch, and compares numerically")
    func semanticVersionParsingAndComparison() throws {
        let v1 = try #require(CharkleSemanticVersion(parsing: "v1.2.0"))
        let v2 = try #require(CharkleSemanticVersion(parsing: "1.2.0"))
        let vShort = try #require(CharkleSemanticVersion(parsing: "V1.2"))
        let vBuild = try #require(CharkleSemanticVersion(parsing: "v1.2.0+build.6"))
        let v10 = try #require(CharkleSemanticVersion(parsing: "v1.10.0"))
        let v29 = try #require(CharkleSemanticVersion(parsing: "1.2.9"))
        let vPatch10 = try #require(CharkleSemanticVersion(parsing: "1.2.10"))
        let vBeta1 = try #require(CharkleSemanticVersion(parsing: "v1.3.0-beta.1"))
        let vBeta2 = try #require(CharkleSemanticVersion(parsing: "1.3.0-beta.2"))
        let vBeta10 = try #require(CharkleSemanticVersion(parsing: "1.3.0-beta.10"))
        let vStable = try #require(CharkleSemanticVersion(parsing: "1.3.0"))

        #expect(v1 == v2)
        #expect(v1 == vShort)
        #expect(v1 == vBuild)
        #expect(v1.major == 1 && v1.minor == 2 && v1.patch == 0)
        #expect(v1.description == "1.2.0")
        #expect(v1.tagString == "v1.2.0")

        // Numeric ordering (not lexicographic)
        #expect(v29 < v10)
        #expect(v29 < vPatch10)
        #expect(v1 < v29)
        #expect(vBeta1 < vBeta2)
        #expect(vBeta2 < vBeta10)
        #expect(vBeta10 < vStable)
        #expect(!(vStable < vBeta1))

        // Invalid inputs
        #expect(CharkleSemanticVersion(parsing: "") == nil)
        #expect(CharkleSemanticVersion(parsing: "v") == nil)
        #expect(CharkleSemanticVersion(parsing: "abc") == nil)
        #expect(CharkleSemanticVersion(parsing: "1") == nil)
        #expect(CharkleSemanticVersion(parsing: "1.2.3.4") == nil)
        #expect(CharkleSemanticVersion(parsing: "1..2") == nil)
        #expect(CharkleSemanticVersion(parsing: "-1.2.0") == nil)
        #expect(CharkleSemanticVersion(parsing: "1.2.0-") == nil)
    }

    // MARK: - 2. GitHub Release JSON Decoding, Filtering & Asset Selection

    @Test("GitHub Release decoding filters drafts/prereleases and prefers arm64 DMG over Windows installers")
    func githubReleaseDecodingAndSelection() throws {
        let macHash = String(repeating: "a", count: 64)
        let winHash = String(repeating: "f", count: 64)

        let json = """
        [
          {
            "tag_name": "v1.4.0-rc.1",
            "name": "Charkle v1.4.0 RC1",
            "body": "## macOS\\nSHA-256: \(macHash)",
            "html_url": "https://github.com/CharTyr/Charkle/releases/tag/v1.4.0-rc.1",
            "draft": false,
            "prerelease": true,
            "published_at": "2026-11-24T12:00:00Z",
            "assets": [
              {
                "name": "Charkle-1.4.0-rc.1-arm64.dmg",
                "browser_download_url": "https://github.com/CharTyr/Charkle/releases/download/v1.4.0-rc.1/Charkle-1.4.0-rc.1-arm64.dmg",
                "size": 15000000
              }
            ]
          },
          {
            "tag_name": "v1.5.0",
            "name": "Draft Release",
            "body": "",
            "html_url": "https://github.com/CharTyr/Charkle/releases/tag/v1.5.0",
            "draft": true,
            "prerelease": false,
            "published_at": "2026-11-24T13:00:00Z",
            "assets": [
              {
                "name": "Charkle-1.5.0-arm64.dmg",
                "browser_download_url": "https://github.com/CharTyr/Charkle/releases/download/v1.5.0/Charkle-1.5.0-arm64.dmg",
                "size": 15000000
              }
            ]
          },
          {
            "tag_name": "v1.3.0",
            "name": "Charkle v1.3.0",
            "body": "## macOS（v1.3.0 · Build 7 · Apple Silicon）\\n- SHA-256: `\(macHash)`\\n\\n## Windows（v1.3.0）\\n- SHA-256: `\(winHash)`",
            "html_url": "https://github.com/CharTyr/Charkle/releases/tag/v1.3.0",
            "draft": false,
            "prerelease": false,
            "published_at": "2026-11-24T10:00:00Z",
            "assets": [
              {
                "name": "Charkle-1.3.0-Setup.exe",
                "browser_download_url": "https://github.com/CharTyr/Charkle/releases/download/v1.3.0/Charkle-1.3.0-Setup.exe",
                "size": 24000000
              },
              {
                "name": "Charkle-1.3.0-x64.msi",
                "browser_download_url": "https://github.com/CharTyr/Charkle/releases/download/v1.3.0/Charkle-1.3.0-x64.msi",
                "size": 25000000
              },
              {
                "name": "Charkle-1.3.0-x86_64.dmg",
                "browser_download_url": "https://github.com/CharTyr/Charkle/releases/download/v1.3.0/Charkle-1.3.0-x86_64.dmg",
                "size": 13500000
              },
              {
                "name": "Charkle-1.3.0-arm64.dmg",
                "browser_download_url": "https://github.com/CharTyr/Charkle/releases/download/v1.3.0/Charkle-1.3.0-arm64.dmg",
                "size": 12800000
              }
            ]
          }
        ]
        """

        let releases = try GitHubReleaseUpdater.decodeReleases(from: Data(json.utf8))
        #expect(releases.count == 3)

        let current = CharkleSemanticVersion(major: 1, minor: 2, patch: 0)

        // Draft and prerelease must each evaluate as upToDate individually
        if case .updateAvailable = GitHubReleaseUpdater.evaluateRelease(releases[0], currentVersion: current) {
            Issue.record("Prerelease must be filtered out")
        }
        if case .updateAvailable = GitHubReleaseUpdater.evaluateRelease(releases[1], currentVersion: current) {
            Issue.record("Draft release must be filtered out")
        }

        // Across the full list, v1.3.0 wins and picks the arm64 DMG + macOS SHA-256
        let outcome = GitHubReleaseUpdater.evaluateReleases(releases, currentVersion: current)
        guard case .updateAvailable(let update) = outcome else {
            Issue.record("Expected updateAvailable for v1.3.0, got \(outcome)")
            return
        }
        #expect(update.tagName == "v1.3.0")
        #expect(update.version == CharkleSemanticVersion(major: 1, minor: 3, patch: 0))
        #expect(update.assetName == "Charkle-1.3.0-arm64.dmg")
        #expect(update.assetSizeBytes == 12_800_000)
        #expect(update.expectedSHA256 == macHash)
        #expect(update.publishedAt != nil)

        // Same version returns upToDate
        let sameOutcome = GitHubReleaseUpdater.evaluateRelease(releases[2], currentVersion: CharkleSemanticVersion(major: 1, minor: 3, patch: 0))
        guard case .upToDate(_, let latest) = sameOutcome else {
            Issue.record("Expected upToDate when installed version equals latest")
            return
        }
        #expect(latest == CharkleSemanticVersion(major: 1, minor: 3, patch: 0))
    }

    @Test("Asset selector falls back to generic DMG and ignores Windows-only releases")
    func assetSelectorFallbackAndWindowsExclusion() throws {
        let exe = GitHubReleaseAssetDTO(
            name: "Charkle-1.3.0-Setup.exe",
            browserDownloadURL: URL(string: "https://example.com/setup.exe")!,
            size: 100
        )
        let msi = GitHubReleaseAssetDTO(
            name: "Charkle-1.3.0.msi",
            browserDownloadURL: URL(string: "https://example.com/setup.msi")!,
            size: 100
        )
        let genericDMG = GitHubReleaseAssetDTO(
            name: "Charkle-1.3.0.dmg",
            browserDownloadURL: URL(string: "https://example.com/charkle.dmg")!,
            size: 200
        )

        #expect(GitHubReleaseUpdater.selectMacOSDMGAsset(from: [exe, msi]) == nil)
        #expect(GitHubReleaseUpdater.selectMacOSDMGAsset(from: [exe, msi, genericDMG]) == genericDMG)

        let windowsOnlyRelease = GitHubReleaseDTO(
            tagName: "v1.3.0",
            htmlURL: URL(string: "https://github.com/CharTyr/Charkle/releases/tag/v1.3.0")!,
            assets: [exe, msi]
        )
        let outcome = GitHubReleaseUpdater.evaluateRelease(
            windowsOnlyRelease,
            currentVersion: CharkleSemanticVersion(major: 1, minor: 2, patch: 0)
        )
        if case .updateAvailable = outcome {
            Issue.record("Windows-only release must not offer an update on macOS")
        }
    }

    // MARK: - 3. macOS-Scoped SHA-256 Extraction from Dual-Platform Release Notes

    @Test("Dual-platform release notes extract macOS SHA-256 without colliding with Windows checksums")
    func macOSScopedSHA256Extraction() {
        let macHash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        let winHash = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

        // Case 1: macOS section first, Windows second
        let standardDual = """
        ## macOS（v1.2.1 · Build 7 · Apple Silicon）
        - 安装包：`Charkle-1.2.1-arm64.dmg` (12.6 MB)
        - SHA-256: `\(macHash.uppercased())`

        ## Windows（v1.2.1）
        - Installer: `Charkle-1.2.1-Setup.exe`
        - SHA-256: `\(winHash)`
        """
        #expect(GitHubReleaseUpdater.extractMacOSSHA256(from: standardDual) == macHash)

        // Case 2: Windows section first, macOS section second
        let reversedDual = """
        ## Windows（v1.2.1）
        - Installer: `Charkle-1.2.1-Setup.exe`
        - SHA-256: `\(winHash)`

        ## macOS (Apple Silicon)
        - SHA-256: `\(macHash)`
        """
        #expect(GitHubReleaseUpdater.extractMacOSSHA256(from: reversedDual) == macHash)

        // Case 3: macOS section lacks checksum while Windows section has one -> must NOT return Windows hash!
        let windowsChecksumOnly = """
        ## macOS（v1.2.1）
        - 即将补充校验和

        ## Windows（v1.2.1）
        - SHA-256: `\(winHash)`
        """
        #expect(GitHubReleaseUpdater.extractMacOSSHA256(from: windowsChecksumOnly) == nil)

        // Case 4: Single-platform release notes without explicit macOS heading -> falls back to full body
        let singlePlatform = """
        ### What's New
        - Improved gallery performance
        - SHA-256: `\(macHash)`
        """
        #expect(GitHubReleaseUpdater.extractMacOSSHA256(from: singlePlatform) == macHash)
    }

    @Test("Asset digest fallback supplies SHA-256 when release notes omit checksum")
    func assetDigestFallback() throws {
        let digestHash = String(repeating: "c", count: 64)
        let release = GitHubReleaseDTO(
            tagName: "v1.3.0",
            name: "Charkle v1.3.0",
            body: "## macOS\n- Stability improvements",
            htmlURL: URL(string: "https://github.com/CharTyr/Charkle/releases/tag/v1.3.0")!,
            assets: [
                GitHubReleaseAssetDTO(
                    name: "Charkle-1.3.0-arm64.dmg",
                    browserDownloadURL: URL(string: "https://github.com/CharTyr/Charkle/releases/download/v1.3.0/Charkle-1.3.0-arm64.dmg")!,
                    size: 1024,
                    digest: "sha256:\(digestHash.uppercased())"
                )
            ]
        )

        let outcome = GitHubReleaseUpdater.evaluateRelease(
            release,
            currentVersion: CharkleSemanticVersion(major: 1, minor: 2, patch: 0)
        )
        guard case .updateAvailable(let update) = outcome else {
            Issue.record("Expected updateAvailable")
            return
        }
        #expect(update.expectedSHA256 == digestHash)
    }

    // MARK: - 4. Real Temp-File CryptoKit SHA-256 Verification

    @Test("CryptoKit streaming SHA-256 verifies matching temp file and rejects mismatched digest")
    func tempFileSHA256Verification() throws {
        let tempDir = try GitHubReleaseUpdater.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let payload = Data("Charkle macOS signed DMG verification payload 2026".utf8)
        let fileURL = tempDir.appendingPathComponent("sample.dmg")
        try payload.write(to: fileURL)

        let expected = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let computed = try GitHubReleaseUpdater.sha256Hex(ofFileAt: fileURL)
        #expect(computed == expected)

        // Exact match, uppercase, and sha256: prefix all succeed
        try GitHubReleaseUpdater.verifySHA256(ofFileAt: fileURL, expectedHex: expected)
        try GitHubReleaseUpdater.verifySHA256(ofFileAt: fileURL, expectedHex: "SHA256:\(expected.uppercased())")

        // Mismatch throws localized Chinese error
        let wrongHash = String(repeating: "0", count: 64)
        do {
            try GitHubReleaseUpdater.verifySHA256(ofFileAt: fileURL, expectedHex: wrongHash)
            Issue.record("Expected checksumMismatch error")
        } catch let error as GitHubReleaseUpdaterError {
            #expect(error == .checksumMismatch(expected: wrongHash, actual: expected))
            #expect(error.localizedDescription.contains("SHA-256"))
        }
    }

    // MARK: - 5. Shell-Safe Path Quoting, Atomic Script & Install Eligibility

    @Test("POSIX single-quote escaping neutralizes spaces, quotes, and command substitution under /bin/sh")
    func shellSingleQuotingPreventsInjection() throws {
        let hostilePath = "/tmp/O'Brien's Folder/$(touch /tmp/pwned)/`id`/$HOME;rm -rf / & echo hi"
        let quoted = GitHubReleaseUpdater.shellSingleQuote(hostilePath)

        // Execute /bin/sh printf '%s' <quoted> to prove POSIX shell receives the exact literal string
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' \(quoted)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        try? pipe.fileHandleForWriting.close()
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(String(data: outputData, encoding: .utf8) == hostilePath)

        // Verify atomic script embeds single-quoted paths, backup rollback, and relaunch
        let script = GitHubReleaseUpdater.buildAtomicReplaceScript(
            pid: 4242,
            stagedAppURL: URL(fileURLWithPath: "/tmp/stage O'1/Charkle.app"),
            targetAppURL: URL(fileURLWithPath: "/Applications/Charkle $(test).app"),
            workingDirectoryURL: URL(fileURLWithPath: "/tmp/stage O'1")
        )
        #expect(script.contains("PID=4242"))
        #expect(script.contains("STAGED='/tmp/stage O'\\''1/Charkle.app'"))
        #expect(script.contains("TARGET='/Applications/Charkle $(test).app'"))
        #expect(script.contains("kill -0 \"$PID\""))
        #expect(script.contains("restore_backup"))
        #expect(script.contains("ditto --norsrc --noextattr"))
        #expect(script.contains("open -n \"$TARGET\""))
    }

    @Test("Install target eligibility rejects dev binaries, /Volumes, AppTranslocation, and approves writable .app bundles")
    func installTargetEligibilityChecks() throws {
        let tempDir = try GitHubReleaseUpdater.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Bare binary directory (not a .app bundle)
        let devBinary = tempDir.appendingPathComponent("Charkle")
        try Data().write(to: devBinary)
        if case .eligible = GitHubReleaseUpdater.evaluateInstallTarget(bundleURL: devBinary) {
            Issue.record("Bare binary should require manual install")
        }

        // Read-only /Volumes path
        let volumeApp = URL(fileURLWithPath: "/Volumes/Charkle/Charkle.app")
        if case .eligible = GitHubReleaseUpdater.evaluateInstallTarget(bundleURL: volumeApp) {
            Issue.record("/Volumes app bundle should require manual install")
        }

        // AppTranslocation path
        let translocated = URL(fileURLWithPath: "/private/var/folders/xx/T/AppTranslocation/ABC/d/Charkle.app")
        if case .eligible = GitHubReleaseUpdater.evaluateInstallTarget(bundleURL: translocated) {
            Issue.record("AppTranslocation bundle should require manual install")
        }

        // Writable valid .app bundle with Contents/Info.plist
        let writableApp = tempDir.appendingPathComponent("Charkle.app", isDirectory: true)
        let contentsDir = writableApp.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: contentsDir.appendingPathComponent("Info.plist"))

        let result = GitHubReleaseUpdater.evaluateInstallTarget(bundleURL: writableApp)
        #expect(result == .eligible(targetAppURL: writableApp.standardizedFileURL))
    }

    // MARK: - 6. Throttle, Skipped Version & Preferences Persistence

    @Test("6-hour automatic check throttle and skipped-version rules behave deterministically")
    func throttleAndSkippedVersionPolicy() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        // Disabled auto-check never runs automatically
        #expect(!AppUpdateCheckPolicy.shouldRunAutomaticCheck(autoCheckEnabled: false, lastCheckAt: nil, now: base))

        // Enabled with no prior check runs immediately
        #expect(AppUpdateCheckPolicy.shouldRunAutomaticCheck(autoCheckEnabled: true, lastCheckAt: nil, now: base))

        // 5h 59m elapsed is still throttled; 6h 00m elapsed is due
        let almostSixHours = base.addingTimeInterval(6 * 3600 - 60)
        let sixHours = base.addingTimeInterval(6 * 3600)
        #expect(!AppUpdateCheckPolicy.shouldRunAutomaticCheck(autoCheckEnabled: true, lastCheckAt: base, now: almostSixHours))
        #expect(AppUpdateCheckPolicy.shouldRunAutomaticCheck(autoCheckEnabled: true, lastCheckAt: base, now: sixHours))

        // Skipped version suppresses automatic notifications (with or without leading v),
        // does not suppress newer versions, and never suppresses manual checks.
        let v130 = CharkleSemanticVersion(major: 1, minor: 3, patch: 0)
        let v131 = CharkleSemanticVersion(major: 1, minor: 3, patch: 1)

        #expect(AppUpdateCheckPolicy.isVersionSkipped(v130, skippedVersion: "1.3.0"))
        #expect(AppUpdateCheckPolicy.isVersionSkipped(v130, skippedVersion: "v1.3.0"))
        #expect(!AppUpdateCheckPolicy.isVersionSkipped(v131, skippedVersion: "1.3.0"))

        #expect(!AppUpdateCheckPolicy.shouldNotifyForUpdate(v130, skippedVersion: "1.3.0", isManual: false))
        #expect(AppUpdateCheckPolicy.shouldNotifyForUpdate(v130, skippedVersion: "1.3.0", isManual: true))
        #expect(AppUpdateCheckPolicy.shouldNotifyForUpdate(v131, skippedVersion: "1.3.0", isManual: false))
    }

    @Test("AppUpdatePreferencesStore persists autoCheckUpdates, lastUpdateCheckAt, and skippedVersion")
    func preferencesPersistenceRoundTrip() {
        let suite = "com.charkle.tests.updater.\(UUID().uuidString)"
        let prefs = AppUpdatePreferencesStore(suiteName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        #expect(prefs.loadAutoCheckUpdates() == true)
        #expect(prefs.loadLastUpdateCheckAt() == nil)
        #expect(prefs.loadSkippedVersion() == nil)

        let checkedAt = Date(timeIntervalSince1970: 1_760_000_000)
        prefs.saveAutoCheckUpdates(false)
        prefs.saveLastUpdateCheckAt(checkedAt)
        prefs.saveSkippedVersion("1.3.0")

        #expect(prefs.loadAutoCheckUpdates() == false)
        #expect(prefs.loadLastUpdateCheckAt() == checkedAt)
        #expect(prefs.loadSkippedVersion() == "1.3.0")

        prefs.saveSkippedVersion(nil)
        #expect(prefs.loadSkippedVersion() == nil)
    }

    // MARK: - 7. UI & Architecture Contracts

    @Test("In-app updater wiring upholds zero-polling, Textual notes, zero-violet, and menu/Settings contracts")
    func updaterArchitectureAndUIContracts() throws {
        let coreUpdater = try readSource("Sources/CharkleCore/Services/GitHubReleaseUpdater.swift")
        #expect(!coreUpdater.contains("import AppKit"))
        #expect(!coreUpdater.contains("import SwiftUI"))

        let store = try readSource("Sources/CharkleApp/Stores/AppUpdateStore.swift")
        #expect(!store.contains("Timer.scheduledTimer"))
        #expect(!store.contains("TimelineView"))
        #expect(store.contains("Task.sleep(for: .seconds(4))"))

        let sheet = try readSource("Sources/CharkleApp/Views/AppUpdateSheetView.swift")
        #expect(sheet.contains("import Textual"))
        #expect(sheet.contains("StructuredText(markdown:"))
        #expect(sheet.contains("CharkleHairlineDivider"))
        #expect(sheet.contains(".buttonStyle(.charkle("))

        let entry = try readSource("Sources/CharkleApp/CharkleAppEntry.swift")
        #expect(entry.contains("public let appUpdater: AppUpdateStore"))
        #expect(entry.contains("CommandGroup(after: .appInfo)"))
        #expect(entry.contains("检查更新…"))
        #expect(entry.contains("checkForUpdatesIfDueOnLaunch"))
        #expect(entry.contains("AppUpdateSheetView("))

        let aboutPane = try readSource("Sources/CharkleApp/Views/Settings/AdvancedAboutSettingsPane.swift")
        #expect(aboutPane.contains("SettingsSection(\"软件更新\")"))
        #expect(aboutPane.contains("启动时自动检查更新"))

        let forbiddenColorAPI = try NSRegularExpression(pattern: #"\.(purple|indigo|violet)\b"#)
        let bareDisclosure = try NSRegularExpression(pattern: #"(?<!Charkle)\bDisclosureGroup\s*[\(\{]"#)
        for path in [
            "Sources/CharkleApp/Views/AppUpdateSheetView.swift",
            "Sources/CharkleApp/Views/Settings/AdvancedAboutSettingsPane.swift",
            "Sources/CharkleApp/Views/Settings/SettingsOverlayView.swift"
        ] {
            let src = try readSource(path)
            let range = NSRange(location: 0, length: (src as NSString).length)
            #expect(forbiddenColorAPI.firstMatch(in: src, range: range) == nil, "Found forbidden color in \(path)")
            #expect(bareDisclosure.firstMatch(in: src, range: range) == nil, "Found bare DisclosureGroup in \(path)")
        }
    }
}
