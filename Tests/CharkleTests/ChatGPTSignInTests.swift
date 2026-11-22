@testable import CharkleCore
import Foundation
import Security
import Testing

@Suite("Sign in with ChatGPT DevKit Protocol")
struct ChatGPTSignInTests {
    @Test("OIDC discovery validates issuer and rejects off-origin endpoints")
    func oidcDiscoveryValidation() throws {
        let validJSON = """
        {
          "issuer": "https://auth.openai.com",
          "authorization_endpoint": "https://auth.openai.com/api/accounts/authorize",
          "token_endpoint": "https://auth.openai.com/api/accounts/oauth/token",
          "revocation_endpoint": "https://auth.openai.com/api/accounts/oauth/revoke",
          "jwks_uri": "https://auth.openai.com/.well-known/jwks.json"
        }
        """
        let discovered = try ChatGPTSignInClient.parseDiscovery(Data(validJSON.utf8))
        #expect(discovered.issuer == "https://auth.openai.com")
        #expect(discovered.tokenEndpoint == "https://auth.openai.com/api/accounts/oauth/token")
        #expect(discovered.revocationEndpoint == "https://auth.openai.com/api/accounts/oauth/revoke")

        let spoofedJSON = """
        {
          "issuer": "https://auth.openai.com",
          "authorization_endpoint": "https://evil.example.com/authorize",
          "token_endpoint": "https://auth.openai.com/api/accounts/oauth/token",
          "jwks_uri": "https://auth.openai.com/.well-known/jwks.json"
        }
        """
        #expect(throws: ChatGPTAuthError.self) {
            _ = try ChatGPTSignInClient.parseDiscovery(Data(spoofedJSON.utf8))
        }
    }

    @Test("RS256 ID token verification validates real RSA-SHA256 JWKS signatures and OIDC claims")
    func rs256IDTokenVerification() throws {
        // Generate a real ephemeral 2048-bit RSA keypair via Security.framework
        let keyParams: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var cfError: Unmanaged<CFError>?
        let privateKey = try #require(SecKeyCreateRandomKey(keyParams as CFDictionary, &cfError))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let pkcs1DER = try #require(SecKeyCopyExternalRepresentation(publicKey, &cfError) as Data?)

        // Parse (n, e) out of PKCS#1 RSAPublicKey DER to build a real JWK
        let (modulus, exponent) = try parsePKCS1RSAPublicKey(pkcs1DER)
        let jwk = ChatGPTSignInClient.JWKKey(
            kty: "RSA",
            kid: "test-key-1",
            alg: "RS256",
            n: ChatGPTSignInClient.base64URLEncode(modulus),
            e: ChatGPTSignInClient.base64URLEncode(exponent)
        )

        let now = Date()
        let headerB64 = ChatGPTSignInClient.base64URLEncode(
            try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "test-key-1", "typ": "JWT"])
        )
        let payloadObj: [String: Any] = [
            "iss": ChatGPTSignInClient.issuer,
            "sub": "user-sub-12345",
            "aud": "client_charkle_abc",
            "nonce": "nonce_xyz",
            "iat": Int(now.timeIntervalSince1970) - 10,
            "exp": Int(now.timeIntervalSince1970) + 3600,
            "name": "Char Designer",
            "email": "char@example.com"
        ]
        let payloadB64 = ChatGPTSignInClient.base64URLEncode(try JSONSerialization.data(withJSONObject: payloadObj))
        let signingInput = Data("\(headerB64).\(payloadB64)".utf8)
        let sigData = try #require(
            SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, signingInput as CFData, &cfError) as Data?
        )
        let jwt = "\(headerB64).\(payloadB64).\(ChatGPTSignInClient.base64URLEncode(sigData))"

        let verified = try ChatGPTSignInClient.verifyRS256IDToken(
            jwt,
            keys: [jwk],
            expectedIssuer: ChatGPTSignInClient.issuer,
            expectedClientID: "client_charkle_abc",
            expectedNonce: "nonce_xyz",
            referenceDate: now
        )
        #expect(verified.subject == "user-sub-12345")
        #expect(verified.name == "Char Designer")
        #expect(verified.email == "char@example.com")

        // Wrong nonce must fail
        #expect(throws: ChatGPTAuthError.self) {
            _ = try ChatGPTSignInClient.verifyRS256IDToken(
                jwt,
                keys: [jwk],
                expectedIssuer: ChatGPTSignInClient.issuer,
                expectedClientID: "client_charkle_abc",
                expectedNonce: "wrong_nonce",
                referenceDate: now
            )
        }

        // Tampered payload must fail signature check
        let tamperedJWT = "\(headerB64).\(payloadB64)A.\(ChatGPTSignInClient.base64URLEncode(sigData))"
        #expect(throws: ChatGPTAuthError.self) {
            _ = try ChatGPTSignInClient.verifyRS256IDToken(
                tamperedJWT,
                keys: [jwk],
                expectedIssuer: ChatGPTSignInClient.issuer,
                expectedClientID: "client_charkle_abc",
                expectedNonce: "nonce_xyz",
                referenceDate: now
            )
        }
    }

    @Test("Model catalog filters visibility=list and SSE parser accumulates deltas cleanly")
    func modelCatalogAndSSEStream() throws {
        let catalogJSON = """
        {
          "models": [
            {"slug": "gpt-5.4-mini", "display_name": "GPT-5.4 mini", "visibility": "list"},
            {"slug": "internal-hidden", "display_name": "Hidden", "visibility": "hide"},
            {"slug": "gpt-5.4", "display_name": "GPT-5.4", "visibility": "list"}
          ]
        }
        """
        let models = try ChatGPTSignInClient.parseModelCatalog(Data(catalogJSON.utf8))
        #expect(models.map(\.slug) == ["gpt-5.4-mini", "gpt-5.4"])
        #expect(models.first?.displayName == "GPT-5.4 mini")

        var acc = ChatGPTSignInClient.SSEStreamAccumulator()
        try acc.consume(line: #"data: {"type":"response.output_text.delta","delta":"{\"description\":\"暖色调海报\","}"#, statusCode: 200, requestID: nil)
        try acc.consume(line: #"data: {"type":"response.output_text.delta","delta":"\"tags\":[\"editorial\",\"warm\"]}"}"#, statusCode: 200, requestID: nil)
        try acc.consume(line: #"data: {"type":"response.completed"}"#, statusCode: 200, requestID: nil)
        try acc.finish(statusCode: 200, requestID: nil)
        #expect(acc.accumulatedText == #"{"description":"暖色调海报","tags":["editorial","warm"]}"#)

        // Error event should surface localized subscription sharing message
        var errAcc = ChatGPTSignInClient.SSEStreamAccumulator()
        #expect(throws: ChatGPTAuthError.self) {
            try errAcc.consume(
                line: #"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#,
                statusCode: 200,
                requestID: "req_123"
            )
        }
    }

    // Minimal ASN.1 DER reader for PKCS#1 RSAPublicKey { INTEGER n, INTEGER e } used only in test setup.
    private func parsePKCS1RSAPublicKey(_ der: Data) throws -> (Data, Data) {
        let bytes = Array(der)
        var idx = 0
        func readLength() throws -> Int {
            guard idx < bytes.count else { throw LibraryDatabaseError("DER truncated") }
            let first = Int(bytes[idx]); idx += 1
            if first < 0x80 { return first }
            let count = first & 0x7F
            var val = 0
            for _ in 0..<count {
                guard idx < bytes.count else { throw LibraryDatabaseError("DER length truncated") }
                val = (val << 8) | Int(bytes[idx]); idx += 1
            }
            return val
        }
        guard bytes.first == 0x30 else { throw LibraryDatabaseError("Expected SEQUENCE") }
        idx += 1
        _ = try readLength()

        func readInteger() throws -> Data {
            guard idx < bytes.count, bytes[idx] == 0x02 else { throw LibraryDatabaseError("Expected INTEGER") }
            idx += 1
            let len = try readLength()
            var slice = Array(bytes[idx..<(idx + len)])
            idx += len
            while slice.count > 1 && slice.first == 0x00 { slice.removeFirst() }
            return Data(slice)
        }
        let n = try readInteger()
        let e = try readInteger()
        return (n, e)
    }
}
