import Foundation
import zlib

public enum ZipArchiveError: LocalizedError, Sendable {
    case invalidArchive(String)
    case unsafeEntryPath(String)
    case unsupportedCompression(UInt16)
    case decompressionFailed(String)
    case checksumMismatch(String)
    case resourceLimitExceeded(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArchive(let detail):
            return "无效的 ZIP 归档结构：\(detail)"
        case .unsafeEntryPath(let path):
            return "归档包含不安全的路径条目：\(path)"
        case .unsupportedCompression(let method):
            return "不支持的 ZIP 压缩算法（method=\(method)）"
        case .decompressionFailed(let detail):
            return "解压归档条目失败：\(detail)"
        case .checksumMismatch(let name):
            return "归档条目校验失败（CRC32 不匹配）：\(name)"
        case .resourceLimitExceeded(let detail):
            return "归档超出安全读取限制：\(detail)"
        }
    }
}

public nonisolated struct ZipEntryMetadata: Hashable, Sendable {
    public let name: String
    public let compressionMethod: UInt16
    public let generalPurposeBitFlag: UInt16
    public let crc32: UInt32
    public let compressedSize: Int
    public let uncompressedSize: Int
    public let localHeaderOffset: Int
    public let dosTime: UInt16
    public let dosDate: UInt16
    public let externalAttributes: UInt32
}

/// Pure-Swift + `zlib` safe ZIP reader working identically on macOS 15+ and iOS 18+ (zero external processes).
/// Enforces path-traversal, symlink, entry-count, and zip-bomb decompression limits, and exposes raw compressed
/// slices so Scheme B `.docx` 2-Way synthesis preserves untouched archive entries byte-for-byte.
public nonisolated struct ZipArchiveReader: Sendable {
    public static let maxEntryCount = 50_000
    public static let maxSingleEntryBytes = 64 * 1024 * 1024
    public static let maxTotalExtractedBytes = 256 * 1024 * 1024

    public let data: Data
    public let entries: [ZipEntryMetadata]
    private let entriesByName: [String: ZipEntryMetadata]

    public init(url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let fileData = try Data(contentsOf: url, options: [.mappedIfSafe])
        try self.init(data: fileData)
    }

    public init(data: Data) throws {
        guard data.count >= 22 else {
            throw ZipArchiveError.invalidArchive("文件过小（\(data.count) bytes）")
        }
        self.data = data

        let eocdOffset = try Self.findEndOfCentralDirectory(in: data)
        let totalEntries = Int(data.readUInt16LE(at: eocdOffset + 10))
        let centralDirSize = Int(data.readUInt32LE(at: eocdOffset + 12))
        let centralDirOffset = Int(data.readUInt32LE(at: eocdOffset + 16))

        if totalEntries > Self.maxEntryCount {
            throw ZipArchiveError.resourceLimitExceeded("条目数过多（\(totalEntries)）")
        }
        guard centralDirOffset >= 0,
              centralDirSize >= 0,
              centralDirOffset + centralDirSize <= eocdOffset else {
            throw ZipArchiveError.invalidArchive("中央目录偏移越界")
        }

        var parsedEntries: [ZipEntryMetadata] = []
        parsedEntries.reserveCapacity(totalEntries)
        var lookup: [String: ZipEntryMetadata] = [:]

        var cursor = centralDirOffset
        let cdEnd = centralDirOffset + centralDirSize
        while cursor + 46 <= cdEnd && parsedEntries.count < Self.maxEntryCount {
            let sig = data.readUInt32LE(at: cursor)
            guard sig == 0x0201_4B50 else {
                throw ZipArchiveError.invalidArchive("中央目录条目标记不合法")
            }
            let bitFlag = data.readUInt16LE(at: cursor + 8)
            let method = data.readUInt16LE(at: cursor + 10)
            let dosTime = data.readUInt16LE(at: cursor + 12)
            let dosDate = data.readUInt16LE(at: cursor + 14)
            let crc = data.readUInt32LE(at: cursor + 16)
            let compSize32 = data.readUInt32LE(at: cursor + 20)
            let uncompSize32 = data.readUInt32LE(at: cursor + 24)
            let nameLen = Int(data.readUInt16LE(at: cursor + 28))
            let extraLen = Int(data.readUInt16LE(at: cursor + 30))
            let commentLen = Int(data.readUInt16LE(at: cursor + 32))
            let extAttrs = data.readUInt32LE(at: cursor + 38)
            let localOffset32 = data.readUInt32LE(at: cursor + 42)

            let nameStart = cursor + 46
            let nextCursor = nameStart + nameLen + extraLen + commentLen
            guard nextCursor <= cdEnd else {
                throw ZipArchiveError.invalidArchive("中央目录变长字段越界")
            }

            if compSize32 == 0xFFFF_FFFF || uncompSize32 == 0xFFFF_FFFF || localOffset32 == 0xFFFF_FFFF {
                throw ZipArchiveError.resourceLimitExceeded("暂不支持超大 ZIP64 归档")
            }

            // Reject UNIX symlink entries ((mode & S_IFMT) == S_IFLNK -> 0o120000)
            let unixFileType = (extAttrs >> 16) & 0o170000
            if unixFileType == 0o120000 {
                throw ZipArchiveError.unsafeEntryPath("symlink")
            }

            let nameSlice = data.subdata(in: nameStart..<(nameStart + nameLen))
            let rawName = String(data: nameSlice, encoding: .utf8)
                ?? String(data: nameSlice, encoding: .isoLatin1)
                ?? ""
            let normalizedName = try Self.validateSafeRelativePath(rawName)

            let entry = ZipEntryMetadata(
                name: normalizedName,
                compressionMethod: method,
                generalPurposeBitFlag: bitFlag,
                crc32: crc,
                compressedSize: Int(compSize32),
                uncompressedSize: Int(uncompSize32),
                localHeaderOffset: Int(localOffset32),
                dosTime: dosTime,
                dosDate: dosDate,
                externalAttributes: extAttrs
            )
            parsedEntries.append(entry)
            lookup[normalizedName] = entry
            cursor = nextCursor
        }

        self.entries = parsedEntries
        self.entriesByName = lookup
    }

    public func contains(_ name: String) -> Bool {
        entriesByName[name] != nil
    }

    public func entry(named name: String) -> ZipEntryMetadata? {
        entriesByName[name]
    }

    public func readEntry(_ name: String) throws -> Data? {
        guard let meta = entriesByName[name] else { return nil }
        return try readEntry(meta)
    }

    public func readEntry(_ meta: ZipEntryMetadata) throws -> Data {
        if meta.name.hasSuffix("/") && meta.compressedSize == 0 {
            return Data()
        }
        guard meta.uncompressedSize <= Self.maxSingleEntryBytes else {
            throw ZipArchiveError.resourceLimitExceeded("\(meta.name) 超过单文件解压上限")
        }
        let payloadRange = try compressedDataRange(for: meta)
        let compressedSlice = data.subdata(in: payloadRange)

        let output: Data
        switch meta.compressionMethod {
        case 0:
            output = compressedSlice
        case 8:
            output = try Self.inflateRawDeflate(
                compressedSlice,
                expectedSize: meta.uncompressedSize,
                maxBytes: Self.maxSingleEntryBytes
            )
        default:
            throw ZipArchiveError.unsupportedCompression(meta.compressionMethod)
        }

        let computedCRC = Self.computeCRC32(output)
        if computedCRC != meta.crc32 {
            throw ZipArchiveError.checksumMismatch(meta.name)
        }
        return output
    }

    /// Returns the exact compressed payload bytes for `meta` so `ZipArchiveWriter` can copy untouched
    /// entries into a synthesized `.docx` archive with zero re-compression.
    public func rawCompressedPayload(for meta: ZipEntryMetadata) throws -> Data {
        let range = try compressedDataRange(for: meta)
        return data.subdata(in: range)
    }

    private func compressedDataRange(for meta: ZipEntryMetadata) throws -> Range<Int> {
        let offset = meta.localHeaderOffset
        guard offset >= 0, offset + 30 <= data.count else {
            throw ZipArchiveError.invalidArchive("本地文件头偏移越界：\(meta.name)")
        }
        let sig = data.readUInt32LE(at: offset)
        guard sig == 0x0403_4B50 else {
            throw ZipArchiveError.invalidArchive("本地文件头标记不合法：\(meta.name)")
        }
        let localNameLen = Int(data.readUInt16LE(at: offset + 26))
        let localExtraLen = Int(data.readUInt16LE(at: offset + 28))
        let start = offset + 30 + localNameLen + localExtraLen
        let end = start + meta.compressedSize
        guard start >= 0, end >= start, end <= data.count else {
            throw ZipArchiveError.invalidArchive("压缩数据范围越界：\(meta.name)")
        }
        return start..<end
    }

    static func validateSafeRelativePath(_ rawPath: String) throws -> String {
        if rawPath.contains("\0") {
            throw ZipArchiveError.unsafeEntryPath(rawPath)
        }
        let unified = rawPath.replacingOccurrences(of: "\\", with: "/")
        if unified.hasPrefix("/") || unified.hasPrefix("~") {
            throw ZipArchiveError.unsafeEntryPath(rawPath)
        }
        let parts = unified.split(separator: "/", omittingEmptySubsequences: false)
        for part in parts where part == ".." {
            throw ZipArchiveError.unsafeEntryPath(rawPath)
        }
        return unified
    }

    private static func findEndOfCentralDirectory(in data: Data) throws -> Int {
        let maxComment = 65_535
        let minEOCDSize = 22
        let searchFloor = max(0, data.count - (minEOCDSize + maxComment))
        var pos = data.count - minEOCDSize
        while pos >= searchFloor {
            if data.readUInt32LE(at: pos) == 0x0605_4B50 {
                let commentLen = Int(data.readUInt16LE(at: pos + 20))
                if pos + minEOCDSize + commentLen == data.count {
                    return pos
                }
            }
            pos -= 1
        }
        // Fallback tolerant scan if trailing zero padding exists
        pos = data.count - minEOCDSize
        while pos >= searchFloor {
            if data.readUInt32LE(at: pos) == 0x0605_4B50 {
                return pos
            }
            pos -= 1
        }
        throw ZipArchiveError.invalidArchive("未找到 ZIP EOCD 结尾签名")
    }

    static func computeCRC32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { rawBuffer -> UInt32 in
            let initial = zlib.crc32(0, nil, 0)
            guard let base = rawBuffer.bindMemory(to: Bytef.self).baseAddress, !rawBuffer.isEmpty else {
                return UInt32(initial)
            }
            var running = initial
            var remaining = rawBuffer.count
            var ptr = base
            while remaining > 0 {
                let chunk = min(remaining, 64 * 1024 * 1024)
                running = zlib.crc32(running, ptr, uInt(chunk))
                ptr = ptr.advanced(by: chunk)
                remaining -= chunk
            }
            return UInt32(running & 0xFFFF_FFFF)
        }
    }

    static func inflateRawDeflate(_ compressed: Data, expectedSize: Int, maxBytes: Int) throws -> Data {
        if compressed.isEmpty && expectedSize == 0 {
            return Data()
        }
        return try compressed.withUnsafeBytes { srcBuffer -> Data in
            var stream = z_stream()
            let initStatus = inflateInit2_(
                &stream,
                -MAX_WBITS,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
            guard initStatus == Z_OK else {
                throw ZipArchiveError.decompressionFailed("inflateInit2 失败 (\(initStatus))")
            }
            defer { inflateEnd(&stream) }

            let initialCap = max(256, min(maxBytes, expectedSize > 0 ? expectedSize : compressed.count * 4))
            var output = Data()
            output.reserveCapacity(initialCap)

            let chunkSize = 65_536
            var chunk = [UInt8](repeating: 0, count: chunkSize)

            guard let srcBase = srcBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return Data()
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: srcBase)
            stream.avail_in = uInt(srcBuffer.count)

            while true {
                let status: Int32 = chunk.withUnsafeMutableBufferPointer { dstBuf in
                    stream.next_out = dstBuf.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    if output.count + produced > maxBytes {
                        throw ZipArchiveError.resourceLimitExceeded("解压输出超过安全阈值（>\(maxBytes) bytes）")
                    }
                    output.append(chunk, count: produced)
                }
                if status == Z_STREAM_END {
                    break
                }
                if status != Z_OK {
                    if status == Z_BUF_ERROR && stream.avail_in == 0 {
                        break
                    }
                    throw ZipArchiveError.decompressionFailed("zlib inflate 错误 (\(status))")
                }
            }
            return output
        }
    }

    static func deflateRaw(_ uncompressed: Data, level: Int32 = Z_DEFAULT_COMPRESSION) throws -> Data {
        if uncompressed.isEmpty {
            return Data()
        }
        return try uncompressed.withUnsafeBytes { srcBuffer -> Data in
            var stream = z_stream()
            let initStatus = deflateInit2_(
                &stream,
                level,
                Z_DEFLATED,
                -MAX_WBITS,
                8,
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
            guard initStatus == Z_OK else {
                throw ZipArchiveError.decompressionFailed("deflateInit2 失败 (\(initStatus))")
            }
            defer { deflateEnd(&stream) }

            guard let srcBase = srcBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return Data()
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: srcBase)
            stream.avail_in = uInt(srcBuffer.count)

            var output = Data()
            output.reserveCapacity(max(64, uncompressed.count / 2))
            let chunkSize = 65_536
            var chunk = [UInt8](repeating: 0, count: chunkSize)

            while true {
                let flushMode: Int32 = stream.avail_in == 0 ? Z_FINISH : Z_NO_FLUSH
                let status: Int32 = chunk.withUnsafeMutableBufferPointer { dstBuf in
                    stream.next_out = dstBuf.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return deflate(&stream, flushMode)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(chunk, count: produced)
                }
                if status == Z_STREAM_END {
                    break
                }
                if status != Z_OK {
                    throw ZipArchiveError.decompressionFailed("zlib deflate 错误 (\(status))")
                }
            }
            return output
        }
    }
}

/// Pure-Swift + `zlib` standard PKZIP archive writer supporting both fresh entry compression and
/// byte-preserving copy of untouched entries from an existing `ZipArchiveReader` (used for `.docx` 2-Way synthesis).
public nonisolated struct ZipArchiveWriter: Sendable {
    private struct PreparedEntry: Sendable {
        let name: String
        let nameUTF8: Data
        let method: UInt16
        let bitFlag: UInt16
        let dosTime: UInt16
        let dosDate: UInt16
        let crc32: UInt32
        let compressedPayload: Data
        let uncompressedSize: UInt32
        let externalAttributes: UInt32
    }

    private var entries: [PreparedEntry] = []

    public init() {}

    public mutating func addEntry(
        name: String,
        data: Data,
        compress: Bool = true,
        dosTime: UInt16 = 0x6000,
        dosDate: UInt16 = 0x597C
    ) throws {
        let safeName = try ZipArchiveReader.validateSafeRelativePath(name)
        let nameBytes = Data(safeName.utf8)
        let crc = ZipArchiveReader.computeCRC32(data)
        let method: UInt16
        let payload: Data
        if compress && data.count >= 64 {
            let deflated = try ZipArchiveReader.deflateRaw(data)
            if deflated.count < data.count {
                method = 8
                payload = deflated
            } else {
                method = 0
                payload = data
            }
        } else {
            method = 0
            payload = data
        }
        // General purpose bit 11 (0x0800) marks UTF-8 filename encoding; clear bit 3 (data descriptor)
        // because exact sizes & CRC32 are written directly into the local file header.
        entries.append(PreparedEntry(
            name: safeName,
            nameUTF8: nameBytes,
            method: method,
            bitFlag: 0x0800,
            dosTime: dosTime,
            dosDate: dosDate,
            crc32: crc,
            compressedPayload: payload,
            uncompressedSize: UInt32(data.count),
            externalAttributes: 0
        ))
    }

    public mutating func copyRawEntry(_ meta: ZipEntryMetadata, from reader: ZipArchiveReader) throws {
        let safeName = try ZipArchiveReader.validateSafeRelativePath(meta.name)
        let rawPayload = try reader.rawCompressedPayload(for: meta)
        // Strip bit 3 (data descriptor flag) because we write exact known crc32 & sizes into the local header.
        let cleanFlags = (meta.generalPurposeBitFlag & ~UInt16(0x0008)) | UInt16(0x0800)
        entries.append(PreparedEntry(
            name: safeName,
            nameUTF8: Data(safeName.utf8),
            method: meta.compressionMethod,
            bitFlag: cleanFlags,
            dosTime: meta.dosTime,
            dosDate: meta.dosDate,
            crc32: meta.crc32,
            compressedPayload: rawPayload,
            uncompressedSize: UInt32(meta.uncompressedSize),
            externalAttributes: meta.externalAttributes
        ))
    }

    public func finalize() throws -> Data {
        guard entries.count <= UInt16.max else {
            throw ZipArchiveError.resourceLimitExceeded("写入条目数超过标准 ZIP 上限")
        }

        var archive = Data()
        var localOffsets: [UInt32] = []
        localOffsets.reserveCapacity(entries.count)

        for entry in entries {
            localOffsets.append(UInt32(archive.count))
            archive.appendUInt32LE(0x0403_4B50) // Local file header signature
            archive.appendUInt16LE(20)          // Version needed to extract (2.0)
            archive.appendUInt16LE(entry.bitFlag)
            archive.appendUInt16LE(entry.method)
            archive.appendUInt16LE(entry.dosTime)
            archive.appendUInt16LE(entry.dosDate)
            archive.appendUInt32LE(entry.crc32)
            archive.appendUInt32LE(UInt32(entry.compressedPayload.count))
            archive.appendUInt32LE(entry.uncompressedSize)
            archive.appendUInt16LE(UInt16(entry.nameUTF8.count))
            archive.appendUInt16LE(0)           // Extra field length
            archive.append(entry.nameUTF8)
            archive.append(entry.compressedPayload)
        }

        let centralDirOffset = UInt32(archive.count)
        for (idx, entry) in entries.enumerated() {
            archive.appendUInt32LE(0x0201_4B50) // Central directory file header signature
            archive.appendUInt16LE(20)          // Version made by
            archive.appendUInt16LE(20)          // Version needed to extract
            archive.appendUInt16LE(entry.bitFlag)
            archive.appendUInt16LE(entry.method)
            archive.appendUInt16LE(entry.dosTime)
            archive.appendUInt16LE(entry.dosDate)
            archive.appendUInt32LE(entry.crc32)
            archive.appendUInt32LE(UInt32(entry.compressedPayload.count))
            archive.appendUInt32LE(entry.uncompressedSize)
            archive.appendUInt16LE(UInt16(entry.nameUTF8.count))
            archive.appendUInt16LE(0)           // Extra field length
            archive.appendUInt16LE(0)           // File comment length
            archive.appendUInt16LE(0)           // Disk number start
            archive.appendUInt16LE(0)           // Internal file attributes
            archive.appendUInt32LE(entry.externalAttributes)
            archive.appendUInt32LE(localOffsets[idx])
            archive.append(entry.nameUTF8)
        }
        let centralDirSize = UInt32(archive.count) - centralDirOffset

        // End of Central Directory record
        archive.appendUInt32LE(0x0605_4B50)
        archive.appendUInt16LE(0) // Number of this disk
        archive.appendUInt16LE(0) // Disk where central directory starts
        archive.appendUInt16LE(UInt16(entries.count))
        archive.appendUInt16LE(UInt16(entries.count))
        archive.appendUInt32LE(centralDirSize)
        archive.appendUInt32LE(centralDirOffset)
        archive.appendUInt16LE(0) // Comment length

        return archive
    }
}

private nonisolated extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        let b0 = UInt16(self[startIndex + offset])
        let b1 = UInt16(self[startIndex + offset + 1])
        return b0 | (b1 << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[startIndex + offset])
        let b1 = UInt32(self[startIndex + offset + 1])
        let b2 = UInt32(self[startIndex + offset + 2])
        let b3 = UInt32(self[startIndex + offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
