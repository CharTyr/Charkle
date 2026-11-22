import Foundation
import Testing
@testable import CharkleCore

@Suite("gdirect 0.13.2")
struct GDirectIntegrationTests {
    @Test("Accounts parse the CLI's default marker")
    func accounts() {
        let output = "Signed-in accounts\n  studio@example.com\n* design+drive@example.com\n  studio@example.com\n"
        let result = GDirectIntegration.parseAccounts(output)
        #expect(result.accounts == ["studio@example.com", "design+drive@example.com"])
        #expect(result.defaultAccount == "design+drive@example.com")
        #expect(GDirectIntegration.parseAccounts("No accounts. Run gdirect login.").accounts.isEmpty)
    }

    @Test("Endpoint rows parse IPv4, IPv6, health and latency")
    func scanList() {
        let output = """
            Network: bypassing TUN proxies, bound to en0
            173.194.77.100    OK    2238 ms
            2001:4860:4860::8888    OK    615ms
            192.0.2.1    FAIL    10 ms
            999.42.0.1    OK    2 ms
            """
        let result = GDirectIntegration.parseScanList(output)
        #expect(result.map(\.ip) == ["2001:4860:4860::8888", "173.194.77.100", "192.0.2.1"])
        #expect(result.map(\.latencyMs) == [615, 2238, 10])
        #expect(result.map(\.healthy) == [true, true, false])
    }

    @Test("CLI and desktop app version comparison distinguishes 0.1.2 from 0.13.2")
    func versionMismatch() {
        #expect(GDirectIntegration.hasVersionMismatch(cli: "gdirect 0.1.2\n", app: "0.13.2"))
        #expect(!GDirectIntegration.hasVersionMismatch(cli: "gdirect 0.13.2", app: "0.13.2"))
        #expect(!GDirectIntegration.hasVersionMismatch(cli: nil, app: "0.13.2"))
    }

    @Test("Strict st_dev mount validation refuses ordinary directories and missing paths")
    func mountCheck() async throws {
        let directory = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!GDirectIntegration.isMountActive(at: directory.path))
        #expect(!GDirectIntegration.isMountActive(at: directory.appending(path: "absent").path))
        #expect(GDirectIntegration.isMountActive(at: "/dev"))
        let transport = MountedVolumeTransport(mountPath: directory.path)
        await #expect(throws: DriveTransportError.self) {
            _ = try await transport.findOrCreateFolder(named: "Charkle", parentID: "root")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("OAuth imports the desktop secret and produces RFC 7636 PKCE challenges")
    func oauth() throws {
        let json = Data(#"{"installed":{"client_id":"test.apps.googleusercontent.com","client_secret":"test","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token"}}"#.utf8)
        let config = try GoogleOAuthClientConfig.parseClientSecretJSON(json)
        #expect(config.clientID == "test.apps.googleusercontent.com")
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(GoogleOAuthClient.codeChallengeS256(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(GoogleOAuthClient.generateCodeVerifier().count == 64)
    }
}
