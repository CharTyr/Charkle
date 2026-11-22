import CharkleCore
import Foundation
import Testing

@Suite("X / Twitter Post URL Parser")
struct XPostResolverTests {
    @Test("Parses canonical x.com, twitter.com, mobile, photo, and share URLs")
    func parsesSupportedURLs() throws {
        let cases: [(String, String, String)] = [
            ("https://x.com/jack/status/20", "jack", "20"),
            ("https://twitter.com/design_studio/status/1849123456789012345?s=20&t=abc", "design_studio", "1849123456789012345"),
            ("https://mobile.x.com/Apple/status/9988776655/photo/1", "Apple", "9988776655"),
            ("https://fxtwitter.com/i/web/status/1234567890", "i", "1234567890"),
            ("https://vxtwitter.com/someone/status/42/video/1", "someone", "42")
        ]

        for (raw, expectedHandle, expectedID) in cases {
            let url = try #require(URL(string: raw))
            let parsed = try #require(XPostURLParser.parse(url))
            #expect(parsed.handle == expectedHandle)
            #expect(parsed.tweetID == expectedID)
            #expect(parsed.canonicalURL.absoluteString == "https://x.com/\(expectedHandle)/status/\(expectedID)")
        }
    }

    @Test("Extracts X status URL from copied share text and ignores non-status links")
    func extractsFromShareText() throws {
        let share = "绝美排版灵感 https://x.com/editorial_lab/status/1777888999?s=46 推荐收藏"
        let extracted = try #require(XPostURLParser.extractStatusURL(from: share))
        let parsed = try #require(XPostURLParser.parse(extracted))
        #expect(parsed.handle == "editorial_lab")
        #expect(parsed.tweetID == "1777888999")

        let profileURL = try #require(URL(string: "https://x.com/jack"))
        #expect(XPostURLParser.parse(profileURL) == nil)
        let otherURL = try #require(URL(string: "https://apple.com/status/123"))
        #expect(XPostURLParser.parse(otherURL) == nil)
    }
}
