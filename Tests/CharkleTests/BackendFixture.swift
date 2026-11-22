import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CharkleCore

enum BackendFixture {
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "CharkleTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeEngine(_ folder: URL, transport: (any DriveTransport)? = nil) throws -> LiveCharkleEngine {
        let database = try LibraryDatabase()
        let media = try MediaPipeline(directory: folder)
        return LiveCharkleEngine(database: database, media: media, transport: transport)
    }

    static func artwork(_ hex: String) throws -> Data {
        let color = LabColor.fromHex(hex)
        let image = try #require(MediaArtwork.swatch(color))
        return try #require(MediaArtwork.encode(image, type: .png))
    }

    static func syncConfig() -> DriveSyncConfig {
        DriveSyncConfig(mode: .directAPIWithGDirect, useGDirectIPAcceleration: false, autoSyncIntervalSeconds: 0,
                        syncThumbnails: true, syncEmbeddings: false)
    }
}
