import Foundation
import Testing
@testable import CharkleCore

@Suite("Drive API transport")
struct DirectAPITransportTests {
    @Test("Drive v3 start and pagination tokens decode alongside file changes")
    func changes() async throws {
        let transport = DirectAPITransport(accessToken: { "fixture" }, session: makeSession())
        #expect(try await transport.fetchStartPageToken() == "start")
        let page = try await transport.listChanges(pageToken: "start")
        #expect(page.nextPageToken == "next")
        #expect(page.changes.first?.file?.name == "Studio.png")
        #expect(page.changes.first?.file?.size == 5)
        let final = try await transport.listChanges(pageToken: "next")
        #expect(final.newStartPageToken == "finished")
        #expect(final.changes.first?.removed == true)
    }

    @Test("Resumable upload queries committed bytes after a transient error and sends the remainder")
    func resume() async throws {
        let directory = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = DirectAPITransport(accessToken: { "fixture" }, session: makeSession(),
                                           transferDirectory: directory)
        let file = directory.appending(path: "original")
        try Data([0, 1, 2, 3, 4]).write(to: file)
        let remote = try await transport.uploadFile(from: file, name: "Studio.png", mimeType: "image/png",
                                                     parentID: "target", existingFileID: nil)
        #expect(remote.id == "uploaded")
        #expect(remote.size == 5)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names == ["original"])
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DriveFixtureHTTP.self]
        return URLSession(configuration: configuration)
    }
}

private final class DriveFixtureHTTP: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "www.googleapis.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let reply: (Int, [String: String], String)
        switch (request.httpMethod, url.path) {
        case ("GET", "/drive/v3/changes/startPageToken"):
            reply = (200, [:], #"{"startPageToken":"start"}"#)
        case ("GET", "/drive/v3/changes"):
            let token = params.first { $0.name == "pageToken" }?.value
            if token == "start" {
                reply = (200, [:], #"{"nextPageToken":"next","changes":[{"fileId":"one","file":{"id":"one","name":"Studio.png","mimeType":"image/png","size":"5","modifiedTime":"2026-11-22T00:00:00.000Z"}}]}"#)
            } else {
                reply = (200, [:], #"{"newStartPageToken":"finished","changes":[{"fileId":"one","removed":true}]}"#)
            }
        case ("POST", "/upload/drive/v3/files"):
            reply = (200, ["Location": "https://www.googleapis.com/fixture-upload"], "")
        case ("PUT", "/fixture-upload"):
            switch request.value(forHTTPHeaderField: "Content-Range") {
            case "bytes 0-4/5": reply = (503, [:], "")
            case "bytes */5": reply = (308, ["Range": "bytes=0-1"], "")
            case "bytes 2-4/5": reply = (201, [:], #"{"id":"uploaded","name":"Studio.png","mimeType":"image/png","size":"5","parents":["target"]}"#)
            default: reply = (400, [:], "Unexpected upload range")
            }
        default: reply = (500, [:], "Unexpected fixture request")
        }

        let headers = reply.1.merging(["Content-Type": "application/json"]) { old, _ in old }
        guard let response = HTTPURLResponse(url: url, statusCode: reply.0, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.2.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
