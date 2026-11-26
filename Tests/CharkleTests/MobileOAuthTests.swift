import CharkleCore
import CoreGraphics
import Foundation
import Testing

@Suite("Mobile Cross-Platform Core")
struct MobileOAuthTests {
    @Test("GoogleOAuthClientConfig derives reversed client ID scheme for iOS ASWebAuthenticationSession")
    func derivesReversedClientIDScheme() {
        let config = GoogleOAuthClientConfig(clientID: "1234567890-abcdef123456.apps.googleusercontent.com")
        #expect(config.reversedClientIDScheme == "com.googleusercontent.apps.1234567890-abcdef123456")

        let empty = GoogleOAuthClientConfig(clientID: "   ")
        #expect(empty.reversedClientIDScheme == nil)
    }

    @Test("GoogleOAuthClientConfig parses Google Cloud iOS plist credentials")
    func parsesIOSPlistCredentials() throws {
        let plistXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CLIENT_ID</key>
            <string>99887766-mobileclient.apps.googleusercontent.com</string>
            <key>REVERSED_CLIENT_ID</key>
            <string>com.googleusercontent.apps.99887766-mobileclient</string>
        </dict>
        </plist>
        """
        let parsed = try GoogleOAuthClientConfig.parseClientSecretData(Data(plistXML.utf8))
        #expect(parsed.clientID == "99887766-mobileclient.apps.googleusercontent.com")
        #expect(parsed.clientSecret.isEmpty)
        #expect(parsed.reversedClientIDScheme == "com.googleusercontent.apps.99887766-mobileclient")
    }

    @Test("GoogleOAuthClient custom redirect rejects mismatched OAuth state")
    func customRedirectRejectsStateMismatch() async throws {
        let keychain = KeychainStore(service: "com.charkle.tests.\(UUID().uuidString)")
        let oauth = GoogleOAuthClient(keychain: keychain)
        let config = GoogleOAuthClientConfig(clientID: "424242-testios.apps.googleusercontent.com")

        do {
            _ = try await oauth.authorizeWithCustomRedirect(config: config) { authURL, callbackScheme in
                #expect(callbackScheme == "com.googleusercontent.apps.424242-testios")
                let comps = URLComponents(url: authURL, resolvingAgainstBaseURL: false)
                let redirect = comps?.queryItems?.first(where: { $0.name == "redirect_uri" })?.value
                #expect(redirect == "com.googleusercontent.apps.424242-testios:/oauth2redirect")
                return URL(string: "\(callbackScheme):/oauth2redirect?code=fake-code&state=wrong-state")!
            }
            Issue.record("Expected state mismatch to throw authenticationRequired")
        } catch let error as DriveTransportError {
            if case .authenticationRequired(let msg) = error {
                #expect(msg.contains("State"))
            } else {
                Issue.record("Unexpected DriveTransportError: \(error)")
            }
        }
    }

    @Test("TypeSafeImagePreparer encodes valid JPEG without AppKit")
    func imagePreparerProducesValidJPEG() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(
            data: nil,
            width: 320,
            height: 240,
            bitsPerComponent: 8,
            bytesPerRow: 320 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(red: 0.165, green: 0.376, blue: 0.878, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        let cgImage = try #require(ctx.makeImage())

        let prepared = try #require(TypeSafeImagePreparer.prepare(from: cgImage, targetLongSide: 512))
        #expect(prepared.canvasWidth == 512)
        #expect(prepared.canvasHeight == 384)
        // JPEG SOI marker (0xFF 0xD8)
        #expect(prepared.jpegData.count > 100)
        #expect(prepared.jpegData[0] == 0xFF && prepared.jpegData[1] == 0xD8)
    }
}
