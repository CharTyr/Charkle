import CryptoKit
import Foundation

nonisolated enum DriveFiles {
    static let rootID = "root"

    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DriveTransportError.invalidResponse("Invalid Drive file name.")
        }
    }

    static func stableUUID(_ key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func writeFile(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appending(path: ".charkle-write-" + UUID().uuidString)
        try fm.copyItem(at: source, to: temporary)
        defer { try? fm.removeItem(at: temporary) }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temporary, options: .usingNewMetadataOnly)
        } else {
            try fm.moveItem(at: temporary, to: destination)
        }
    }
}
