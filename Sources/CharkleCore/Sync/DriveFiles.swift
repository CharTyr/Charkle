import CryptoKit
import Darwin
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

    /// Streams raw file bytes using plain POSIX `open(O_WRONLY | O_CREAT | O_TRUNC)` without
    /// `O_EXCL` or `copyfile(3)` metadata/xattr copying.
    ///
    /// Crucial for `rclone nfsmount` (`gdirect`), which rejects NFSv3 `CREATE(EXCLUSIVE)` (`O_EXCL`)
    /// and fixed-mode chmod/xattr operations — causing `FileManager.copyItem` to abort mid-flight and
    /// leave behind 0-byte files plus `._*` AppleDouble clutter.
    static func writeStream(from source: URL, to destination: URL, removeOnFailure: Bool) throws {
        let sourceFD = source.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY)
        }
        guard sourceFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(sourceFD) }

        var sourceStat = stat()
        guard Darwin.fstat(sourceFD, &sourceStat) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let expectedBytes = Int64(sourceStat.st_size)

        let destFD = destination.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        }
        guard destFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var writtenTotal: Int64 = 0
        var writeFailed: Error?
        let bufferSize = 262_144
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        copyLoop: while true {
            let bytesRead = Darwin.read(sourceFD, buffer, bufferSize)
            if bytesRead == 0 {
                break copyLoop
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                writeFailed = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                break copyLoop
            }
            var offset = 0
            while offset < bytesRead {
                let bytesWritten = Darwin.write(destFD, buffer.advanced(by: offset), bytesRead - offset)
                if bytesWritten < 0 {
                    if errno == EINTR { continue }
                    writeFailed = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    break copyLoop
                }
                if bytesWritten == 0 {
                    writeFailed = POSIXError(.EIO)
                    break copyLoop
                }
                offset += bytesWritten
                writtenTotal += Int64(bytesWritten)
            }
        }

        let closeResult = Darwin.close(destFD)
        if writeFailed == nil && closeResult != 0 {
            writeFailed = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if writeFailed == nil && writtenTotal != expectedBytes {
            writeFailed = DriveTransportError.invalidResponse(
                "文件写入不完整（预期 \(expectedBytes) 字节，实际 \(writtenTotal) 字节）。"
            )
        }
        if let error = writeFailed {
            if removeOnFailure {
                try? FileManager.default.removeItem(at: destination)
            }
            throw error
        }
    }

    /// Writes raw bytes using plain POSIX `open(O_WRONLY | O_CREAT | O_TRUNC)` without `O_EXCL`.
    static func writeRawBytes(_ data: Data, to destination: URL, removeOnFailure: Bool) throws {
        let destFD = destination.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        }
        guard destFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var writeFailed: Error?
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, !raw.isEmpty else { return }
            var offset = 0
            while offset < raw.count {
                let bytesWritten = Darwin.write(destFD, base.advanced(by: offset), raw.count - offset)
                if bytesWritten < 0 {
                    if errno == EINTR { continue }
                    writeFailed = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    return
                }
                if bytesWritten == 0 {
                    writeFailed = POSIXError(.EIO)
                    return
                }
                offset += bytesWritten
            }
        }

        let closeResult = Darwin.close(destFD)
        if writeFailed == nil && closeResult != 0 {
            writeFailed = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if let error = writeFailed {
            if removeOnFailure {
                try? FileManager.default.removeItem(at: destination)
            }
            throw error
        }
    }

    static func writeFile(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appending(path: ".charkle-write-" + UUID().uuidString)
        try writeStream(from: source, to: temporary, removeOnFailure: true)
        defer { try? fm.removeItem(at: temporary) }
        if fm.fileExists(atPath: destination.path) {
            do {
                _ = try fm.replaceItemAt(destination, withItemAt: temporary, options: .usingNewMetadataOnly)
            } catch {
                // rclone NFS mounts may not support atomic RENAME_SWAP; fall back to unlink + rename
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: temporary, to: destination)
            }
        } else {
            try fm.moveItem(at: temporary, to: destination)
        }
    }
}
