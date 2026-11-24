import Compression
import Foundation
import ImageIO

/// Extracted image metadata combining full camera EXIF/TIFF/GPS/IPTC properties and
/// embedded AI image generation prompts/parameters (A1111/Forge/Civitai, ComfyUI, NovelAI,
/// InvokeAI, Draw Things, Midjourney, XMP, and EXIF UserComment).
public nonisolated struct ExtractedImageMetadata: Hashable, Sendable {
    public let photoExif: PhotoExifMetadata?
    public let aiGeneration: AIGenerationMetadata?

    public init(photoExif: PhotoExifMetadata? = nil, aiGeneration: AIGenerationMetadata? = nil) {
        self.photoExif = photoExif
        self.aiGeneration = aiGeneration
    }
}

public nonisolated enum ImageMetadataExtractor {
    private static let maxPNGChunkScanCount = 4_096
    private static let maxPNGTextChunkBytes = 1_500_000

    public static func extract(from url: URL) -> ExtractedImageMetadata {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary)
        let props = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        let xmpEntries = source.map(extractXMPMetadata(from:)) ?? [:]

        let photoExif = parsePhotoExif(from: props)

        // Stream PNG chunk headers (seeking over IDAT payloads) so trailing tEXt/iTXt/zTXt chunks
        // are always found even on multi-megabyte 4K PNGs.
        let pngChunks = extractPNGTextChunks(fromFileAt: url)

        let aiGen = extractAIGeneration(
            pngChunks: pngChunks,
            imageProperties: props,
            xmpEntries: xmpEntries
        )

        return ExtractedImageMetadata(
            photoExif: photoExif?.isEmpty == false ? photoExif : nil,
            aiGeneration: aiGen?.isEmpty == false ? aiGen : nil
        )
    }

    // MARK: - 1. Camera EXIF / TIFF / GPS / IPTC Extraction

    private static func parsePhotoExif(from props: [CFString: Any]) -> PhotoExifMetadata? {
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let exifAux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]

        let make = cleanString(tiff[kCGImagePropertyTIFFMake])
        let model = cleanString(tiff[kCGImagePropertyTIFFModel])
        let lens = cleanString(exif[kCGImagePropertyExifLensModel])
            ?? cleanString(exifAux[kCGImagePropertyExifAuxLensModel])
        let rawDate = cleanString(exif[kCGImagePropertyExifDateTimeOriginal])
            ?? cleanString(exif[kCGImagePropertyExifDateTimeDigitized])
            ?? cleanString(tiff[kCGImagePropertyTIFFDateTime])
        let offset = cleanString(exif[kCGImagePropertyExifOffsetTimeOriginal])
        let capturedAt = formatExifDate(rawDate, offset: offset)

        let exposureSeconds = doubleValue(exif[kCGImagePropertyExifExposureTime])
        let exposureTime = exposureSeconds.flatMap(formatExposureTime)
        let fNumber = doubleValue(exif[kCGImagePropertyExifFNumber])
        let iso = firstIntValue(exif[kCGImagePropertyExifISOSpeedRatings])
        let focalMM = doubleValue(exif[kCGImagePropertyExifFocalLength])
        let focal35 = intValue(exif[kCGImagePropertyExifFocalLenIn35mmFilm])
        let exposureBias = doubleValue(exif[kCGImagePropertyExifExposureBiasValue])
        let metering = intValue(exif[kCGImagePropertyExifMeteringMode]).flatMap(meteringModeLabel)
        let flashFired: Bool? = intValue(exif[kCGImagePropertyExifFlash]).map { ($0 & 0x1) != 0 }
        let whiteBalance: String? = intValue(exif[kCGImagePropertyExifWhiteBalance]).map { $0 == 0 ? "自动" : "手动" }

        let colorProfile = cleanString(props[kCGImagePropertyProfileName])
            ?? cleanString(props[kCGImagePropertyColorModel])
        let bitDepth = intValue(props[kCGImagePropertyDepth])
        let dpiWidth = doubleValue(props[kCGImagePropertyDPIWidth]).flatMap { val -> Int? in
            guard val.isFinite, val > 0, val < 1_000_000 else { return nil }
            return Int(val.rounded())
        }

        let software = cleanString(tiff[kCGImagePropertyTIFFSoftware])
        let artist = cleanString(tiff[kCGImagePropertyTIFFArtist])
            ?? firstStringValue(iptc[kCGImagePropertyIPTCByline])
        let copyright = cleanString(tiff[kCGImagePropertyTIFFCopyright])
            ?? cleanString(iptc[kCGImagePropertyIPTCCopyrightNotice])

        var latitude = doubleValue(gps[kCGImagePropertyGPSLatitude])
        if let lat = latitude, cleanString(gps[kCGImagePropertyGPSLatitudeRef])?.uppercased() == "S" {
            latitude = -abs(lat)
        }
        var longitude = doubleValue(gps[kCGImagePropertyGPSLongitude])
        if let lon = longitude, cleanString(gps[kCGImagePropertyGPSLongitudeRef])?.uppercased() == "W" {
            longitude = -abs(lon)
        }
        var altitude = doubleValue(gps[kCGImagePropertyGPSAltitude])
        if let alt = altitude, intValue(gps[kCGImagePropertyGPSAltitudeRef]) == 1 {
            altitude = -abs(alt)
        }

        let meta = PhotoExifMetadata(
            cameraMake: make,
            cameraModel: model,
            lensModel: lens,
            capturedAt: capturedAt,
            exposureTime: exposureTime,
            fNumber: fNumber,
            iso: iso,
            focalLengthMM: focalMM,
            focalLength35mm: focal35,
            exposureBiasEV: exposureBias,
            meteringMode: metering,
            flashFired: flashFired,
            whiteBalance: whiteBalance,
            colorProfile: colorProfile,
            bitDepth: bitDepth,
            dpiWidth: dpiWidth,
            software: software,
            artist: artist,
            copyright: copyright,
            latitude: latitude,
            longitude: longitude,
            altitudeMeters: altitude
        )
        return meta.isEmpty ? nil : meta
    }

    static func formatExposureTime(_ seconds: Double) -> String? {
        guard seconds > 0, seconds.isFinite else { return nil }
        if seconds >= 0.5 {
            guard seconds < 1_000_000 else { return nil }
            if abs(seconds - seconds.rounded()) < 0.05 {
                return "\(Int(seconds.rounded()))s"
            }
            return String(format: "%.1fs", seconds)
        }
        let inv = (1.0 / seconds).rounded()
        guard inv.isFinite, inv >= 1, inv < 10_000_000 else { return nil }
        let denom = max(1, Int(inv))
        return "1/\(denom)s"
    }

    private static func formatExifDate(_ raw: String?, offset: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        // Standard EXIF format: "YYYY:MM:DD HH:MM:SS" -> "YYYY-MM-DD HH:MM:SS"
        var normalized = raw
        if normalized.count >= 10 {
            let idx4 = normalized.index(normalized.startIndex, offsetBy: 4)
            let idx7 = normalized.index(normalized.startIndex, offsetBy: 7)
            if normalized[idx4] == ":" && normalized[idx7] == ":" {
                normalized.replaceSubrange(idx4...idx4, with: "-")
                normalized.replaceSubrange(idx7...idx7, with: "-")
            }
        }
        if let offset, !offset.isEmpty, !normalized.contains(offset) {
            return "\(normalized) (\(offset))"
        }
        return normalized
    }

    private static func meteringModeLabel(_ code: Int) -> String? {
        switch code {
        case 1: "平均测光"
        case 2: "中央重点测光"
        case 3: "点测光"
        case 4: "多点测光"
        case 5: "评价测光"
        case 6: "局部测光"
        default: nil
        }
    }

    // MARK: - 2. PNG Binary Text Chunk Scanner (`tEXt`, `iTXt`, `zTXt`)

    /// Streams PNG chunk headers directly from disk, seeking past `IDAT` image data so trailing
    /// `tEXt`/`iTXt`/`zTXt` metadata chunks are always extracted regardless of file size.
    public static func extractPNGTextChunks(fromFileAt url: URL) -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let sig = try? handle.read(upToCount: 8),
              sig.count == 8,
              sig.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
            return [:]
        }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        guard fileSize > 16 else { return [:] }
        var offset: UInt64 = 8
        var chunks: [String: String] = [:]
        var scannedChunks = 0

        while offset + 12 <= fileSize && scannedChunks < maxPNGChunkScanCount {
            scannedChunks += 1
            do {
                try handle.seek(toOffset: offset)
                guard let header = try handle.read(upToCount: 8), header.count == 8 else { break }
                let length = UInt64(readBigEndianUInt32(header, at: 0))
                let dataStart = offset + 8
                let nextOffset = dataStart + length + 4
                guard nextOffset >= dataStart, nextOffset <= fileSize else { break }

                let chunkType = String(bytes: header[4..<8], encoding: .ascii) ?? ""
                if chunkType == "IEND" { break }
                if (chunkType == "tEXt" || chunkType == "iTXt" || chunkType == "zTXt"),
                   length > 0, length <= UInt64(maxPNGTextChunkBytes),
                   let payload = try handle.read(upToCount: Int(length)),
                   payload.count == Int(length) {
                    switch chunkType {
                    case "tEXt":
                        if let (k, v) = decodePNGtEXt(payload) { chunks[k] = v }
                    case "iTXt":
                        if let (k, v) = decodePNGiTXt(payload) { chunks[k] = v }
                    case "zTXt":
                        if let (k, v) = decodePNGzTXt(payload) { chunks[k] = v }
                    default:
                        break
                    }
                }
                offset = nextOffset
            } catch {
                break
            }
        }
        return chunks
    }

    public static func extractPNGTextChunks(from data: Data) -> [String: String] {
        guard data.count > 16,
              data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
            return [:]
        }
        var chunks: [String: String] = [:]
        var offset = 8
        let total = data.count

        while offset + 12 <= total {
            let length = Int(readBigEndianUInt32(data, at: offset))
            let typeStart = offset + 4
            let dataStart = offset + 8
            guard length >= 0, dataStart + length + 4 <= total else { break }

            let typeBytes = data[typeStart..<(typeStart + 4)]
            let chunkType = String(bytes: typeBytes, encoding: .ascii) ?? ""

            if chunkType == "IEND" { break }
            if length > 0 && length <= 1_500_000 {
                let payload = data[dataStart..<(dataStart + length)]
                switch chunkType {
                case "tEXt":
                    if let (k, v) = decodePNGtEXt(payload) { chunks[k] = v }
                case "iTXt":
                    if let (k, v) = decodePNGiTXt(payload) { chunks[k] = v }
                case "zTXt":
                    if let (k, v) = decodePNGzTXt(payload) { chunks[k] = v }
                default:
                    break
                }
            }

            offset = dataStart + length + 4
        }
        return chunks
    }

    private static func readBigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset]) << 24
        let b1 = UInt32(data[data.startIndex + offset + 1]) << 16
        let b2 = UInt32(data[data.startIndex + offset + 2]) << 8
        let b3 = UInt32(data[data.startIndex + offset + 3])
        return b0 | b1 | b2 | b3
    }

    private static func decodePNGtEXt(_ payload: Data) -> (String, String)? {
        guard let nul = payload.firstIndex(of: 0) else { return nil }
        guard let key = String(data: payload[payload.startIndex..<nul], encoding: .isoLatin1), !key.isEmpty else {
            return nil
        }
        let valSlice = payload[payload.index(after: nul)..<payload.endIndex]
        let value = String(data: valSlice, encoding: .utf8) ?? String(data: valSlice, encoding: .isoLatin1) ?? ""
        return (key, value)
    }

    private static func decodePNGzTXt(_ payload: Data) -> (String, String)? {
        guard let nul = payload.firstIndex(of: 0) else { return nil }
        let methodIndex = payload.index(after: nul)
        guard methodIndex < payload.endIndex, payload[methodIndex] == 0 else { return nil }
        guard let key = String(data: payload[payload.startIndex..<nul], encoding: .isoLatin1), !key.isEmpty else {
            return nil
        }
        let compressed = Data(payload[payload.index(after: methodIndex)..<payload.endIndex])
        guard let inflated = inflateZlib(compressed) else { return nil }
        let value = String(data: inflated, encoding: .utf8) ?? String(data: inflated, encoding: .isoLatin1) ?? ""
        return (key, value)
    }

    private static func decodePNGiTXt(_ payload: Data) -> (String, String)? {
        guard let nul1 = payload.firstIndex(of: 0) else { return nil }
        guard let key = String(data: payload[payload.startIndex..<nul1], encoding: .isoLatin1), !key.isEmpty else {
            return nil
        }
        let flagIdx = payload.index(after: nul1)
        let methodIdx = payload.index(after: flagIdx)
        guard methodIdx < payload.endIndex else { return nil }
        let isCompressed = payload[flagIdx] == 1
        let langStart = payload.index(after: methodIdx)
        guard langStart < payload.endIndex,
              let nul2 = payload[langStart..<payload.endIndex].firstIndex(of: 0) else { return nil }
        let translatedStart = payload.index(after: nul2)
        guard translatedStart < payload.endIndex,
              let nul3 = payload[translatedStart..<payload.endIndex].firstIndex(of: 0) else { return nil }
        let textStart = payload.index(after: nul3)
        guard textStart <= payload.endIndex else { return nil }

        let rawText = Data(payload[textStart..<payload.endIndex])
        let finalBytes: Data
        if isCompressed {
            guard let inflated = inflateZlib(rawText) else { return nil }
            finalBytes = inflated
        } else {
            finalBytes = rawText
        }
        let value = String(data: finalBytes, encoding: .utf8) ?? String(data: finalBytes, encoding: .isoLatin1) ?? ""
        return (key, value)
    }

    /// Inflates a standard RFC 1950 zlib stream (2-byte zlib header + optional 4-byte FDICT + raw deflate payload).
    private static func inflateZlib(_ data: Data) -> Data? {
        guard data.count > 6 else { return nil }
        let cmf = data[data.startIndex]
        let flg = data[data.index(after: data.startIndex)]
        // RFC 1950 check: deflate method == 8 and (CMF*256 + FLG) % 31 == 0
        let hasFDICT = (flg & 0x20) != 0
        let headerBytes = ((cmf & 0x0F) == 8 && ((Int(cmf) << 8) + Int(flg)) % 31 == 0)
            ? (hasFDICT ? 6 : 2)
            : 2
        guard data.count > headerBytes + 4 else { return nil }
        let deflateSlice = data.dropFirst(headerBytes)
        let cap = 4 * 1024 * 1024
        var capacity = min(max(data.count * 12, 65_536), cap)

        while true {
            var buffer = Data(count: capacity)
            let decodedSize = deflateSlice.withUnsafeBytes { srcPtr -> Int in
                guard let srcBase = srcPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return buffer.withUnsafeMutableBytes { dstPtr in
                    guard let dstBase = dstPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(
                        dstBase,
                        capacity,
                        srcBase,
                        deflateSlice.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            guard decodedSize > 0 else { return nil }
            if decodedSize == capacity && capacity < cap {
                capacity = min(capacity * 2, cap)
                continue
            }
            buffer.count = decodedSize
            return buffer
        }
    }

    // MARK: - 3. XMP Metadata Extraction

    private static func extractXMPMetadata(from source: CGImageSource) -> [String: String] {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else {
            return [:]
        }
        var out: [String: String] = [:]
        for tag in tags {
            let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
            let prefix = (CGImageMetadataTagCopyPrefix(tag) as String?) ?? ""
            let key = prefix.isEmpty ? name : "\(prefix):\(name)"
            if let str = extractXMPValueString(CGImageMetadataTagCopyValue(tag)), !str.isEmpty {
                out[key] = str
            }
        }
        return out
    }

    private static func extractXMPValueString(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if let s = value as? String {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let arr = value as? [Any] {
            for item in arr {
                if let tag = item as AnyObject?, CFGetTypeID(tag) == CGImageMetadataTagGetTypeID() {
                    let metaTag = unsafeDowncast(tag, to: CGImageMetadataTag.self)
                    if let s = extractXMPValueString(CGImageMetadataTagCopyValue(metaTag)), !s.isEmpty {
                        return s
                    }
                } else if let s = item as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return s.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    // MARK: - 4. AI Generation Prompt & Parameters Parsers

    private static func extractAIGeneration(
        pngChunks: [String: String],
        imageProperties: [CFString: Any],
        xmpEntries: [String: String]
    ) -> AIGenerationMetadata? {
        let lowerPNG = Dictionary(pngChunks.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })

        // A. Stable Diffusion WebUI (A1111 / Forge / reForge / Civitai) PNG `parameters`
        if let params = lowerPNG["parameters"]?.trimmingCharacters(in: .whitespacesAndNewlines), !params.isEmpty {
            if let parsed = parseA1111Parameters(params) {
                return parsed
            }
        }

        // B. ComfyUI PNG `prompt` (API graph JSON) + optional `workflow`
        if let promptJSON = lowerPNG["prompt"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           promptJSON.hasPrefix("{") {
            if let parsed = parseComfyUIPromptJSON(promptJSON) {
                return parsed
            }
        }

        // C. NovelAI PNG (`Software == "NovelAI"` or `Comment` JSON with `uc` / `prompt`)
        if let comment = lowerPNG["comment"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           comment.hasPrefix("{"),
           (lowerPNG["software"]?.localizedCaseInsensitiveContains("novelai") == true
            || comment.contains("\"uc\"")
            || comment.contains("\"v4_prompt\"")) {
            if let parsed = parseNovelAIMetadata(commentJSON: comment, description: lowerPNG["description"]) {
                return parsed
            }
        }

        // D. InvokeAI (`invokeai_metadata` or `sd-metadata`)
        if let invokeJSON = lowerPNG["invokeai_metadata"] ?? lowerPNG["sd-metadata"],
           invokeJSON.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            if let parsed = parseInvokeAIMetadata(invokeJSON) {
                return parsed
            }
        }

        // E. Midjourney PNG `Description` + `Author` / `Job ID:`
        if let desc = lowerPNG["description"]?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            let author = lowerPNG["author"] ?? ""
            if author.localizedCaseInsensitiveContains("midjourney")
                || desc.contains("Job ID:")
                || desc.contains("--v ")
                || desc.contains("--ar ")
                || desc.contains("--niji") {
                return parseMidjourneyDescription(desc)
            }
        }

        // F. Draw Things / XMP / EXIF UserComment / TIFF ImageDescription / IPTC Caption
        var textCandidates: [(source: String, text: String)] = []
        let exif = imageProperties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = imageProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let iptc = imageProperties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]

        if let uc = decodeExifUserComment(exif[kCGImagePropertyExifUserComment]) {
            textCandidates.append(("EXIF UserComment", uc))
        }
        if let xmpUC = xmpEntries["exif:UserComment"] ?? xmpEntries["UserComment"] {
            textCandidates.append(("XMP UserComment", xmpUC))
        }
        if let xmpDesc = xmpEntries["dc:description"] ?? xmpEntries["description"] {
            textCandidates.append(("XMP Description", xmpDesc))
        }
        if let tiffDesc = cleanString(tiff[kCGImagePropertyTIFFImageDescription]) {
            textCandidates.append(("TIFF Description", tiffDesc))
        }
        if let iptcCap = cleanString(iptc[kCGImagePropertyIPTCCaptionAbstract]) {
            textCandidates.append(("IPTC Caption", iptcCap))
        }
        if let pngXMP = lowerPNG["xml:com.adobe.xmp"], !pngXMP.isEmpty {
            if let extracted = extractTagContent(from: pngXMP, tagName: "exif:UserComment")
                ?? extractTagContent(from: pngXMP, tagName: "dc:description") {
                textCandidates.append(("PNG XMP", extracted))
            }
        }

        for candidate in textCandidates {
            let trimmed = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // JSON payload (Draw Things / ComfyUI / NovelAI / SwarmUI)
            if trimmed.hasPrefix("{") {
                if let parsed = parseGenericAIJSON(trimmed) {
                    return parsed
                }
            }

            // A1111 / Forge / Civitai parameters embedded in JPEG/WebP EXIF UserComment
            if trimmed.contains("Steps:") || trimmed.contains("Negative prompt:") || trimmed.contains("Sampler:") {
                if let parsed = parseA1111Parameters(trimmed) {
                    return parsed
                }
            }

            // Midjourney prompt embedded in Description/Caption
            if trimmed.contains("Job ID:") || trimmed.contains("--v ") || trimmed.contains("--niji") {
                return parseMidjourneyDescription(trimmed)
            }
        }

        // G. Generic PNG `prompt` plain text (e.g. DALL·E / SwarmUI / Flux tools)
        if let plainPrompt = lowerPNG["prompt"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plainPrompt.isEmpty, !plainPrompt.hasPrefix("{") {
            return AIGenerationMetadata(
                generator: lowerPNG["software"] ?? "AI 生成",
                prompt: plainPrompt,
                negativePrompt: lowerPNG["negative_prompt"] ?? lowerPNG["negative prompt"],
                rawParameters: String(plainPrompt.prefix(8000))
            )
        }

        return nil
    }

    /// Parses A1111 / Forge / reForge / Civitai `parameters` text block.
    public static func parseA1111Parameters(_ raw: String) -> AIGenerationMetadata? {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let lines = normalized.components(separatedBy: "\n")
        // Locate the final parameter key-value line (typically starts with "Steps: " or contains "Sampler: " + "Seed: ")
        var paramLineIndex: Int? = nil
        for idx in stride(from: lines.count - 1, through: 0, by: -1) {
            let line = lines[idx].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Steps:") || (line.contains("Sampler:") && line.contains("Seed:")) {
                paramLineIndex = idx
                break
            }
        }

        let headerLines: [String]
        let paramLine: String
        if let idx = paramLineIndex {
            headerLines = Array(lines[..<idx])
            paramLine = lines[idx...].joined(separator: ", ")
        } else {
            headerLines = lines
            paramLine = ""
        }

        let headerText = headerLines.joined(separator: "\n")
        let positivePrompt: String
        let negativePrompt: String?
        if let negRange = headerText.range(of: "Negative prompt:", options: [.caseInsensitive]) {
            positivePrompt = String(headerText[..<negRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let neg = String(headerText[negRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            negativePrompt = neg.isEmpty ? nil : neg
        } else {
            positivePrompt = headerText.trimmingCharacters(in: .whitespacesAndNewlines)
            negativePrompt = nil
        }

        let kv = parseCommaSeparatedKeyValues(paramLine)
        let steps = kv["Steps"].flatMap(Int.init)
        let sampler = kv["Sampler"]
        let scheduler = kv["Schedule type"] ?? kv["Scheduler"]
        let cfgScale = (kv["CFG scale"] ?? kv["Distilled CFG Scale"]).flatMap(Double.init)
        let seed = kv["Seed"]
        let sizeText = kv["Size"]?.replacingOccurrences(of: "x", with: " × ")
        let modelName = kv["Model"]
        let modelHash = kv["Model hash"]
        let clipSkip = kv["Clip skip"].flatMap(Int.init)

        var loras = extractLoraTags(from: positivePrompt)
        if let loraHashes = kv["Lora hashes"] {
            for pair in loraHashes.split(separator: ",") {
                let name = pair.split(separator: ":").first?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\""))) ?? ""
                if !name.isEmpty && !loras.contains(name) {
                    loras.append(name)
                }
            }
        }

        let knownKeys: Set<String> = [
            "Steps", "Sampler", "Schedule type", "Scheduler", "CFG scale",
            "Seed", "Size", "Model", "Model hash", "Clip skip", "Lora hashes"
        ]
        var extras: [String: String] = [:]
        for (k, v) in kv where !knownKeys.contains(k) && extras.count < 8 {
            extras[k] = v
        }

        let generator: String
        if let version = kv["Version"], !version.isEmpty {
            if version.localizedCaseInsensitiveContains("forge") {
                generator = "SD WebUI Forge"
            } else if version.localizedCaseInsensitiveContains("comfy") {
                generator = "ComfyUI"
            } else {
                generator = "Stable Diffusion (\(version))"
            }
        } else {
            generator = "Stable Diffusion (A1111)"
        }

        let meta = AIGenerationMetadata(
            generator: generator,
            prompt: positivePrompt.isEmpty ? nil : positivePrompt,
            negativePrompt: negativePrompt,
            modelName: modelName,
            modelHash: modelHash,
            sampler: sampler,
            scheduler: scheduler,
            steps: steps,
            cfgScale: cfgScale,
            seed: seed,
            sizeText: sizeText,
            clipSkip: clipSkip,
            loras: loras,
            extraParameters: extras,
            rawParameters: String(normalized.prefix(8000))
        )
        return meta.isEmpty ? nil : meta
    }

    /// Parses ComfyUI node-graph JSON (`prompt` chunk) by tracing sampler, conditioning, checkpoint, LoRA, and latent nodes.
    public static func parseComfyUIPromptJSON(_ rawJSON: String) -> AIGenerationMetadata? {
        guard let data = rawJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !root.isEmpty else {
            return nil
        }

        // Convert to typed node table `[nodeID: (classType, inputs)]`
        var nodes: [String: (classType: String, inputs: [String: Any])] = [:]
        for (nodeID, rawVal) in root {
            guard let dict = rawVal as? [String: Any],
                  let classType = dict["class_type"] as? String else { continue }
            let inputs = dict["inputs"] as? [String: Any] ?? [:]
            nodes[nodeID] = (classType, inputs)
        }
        guard !nodes.isEmpty else { return nil }

        func linkedNodeID(_ value: Any?) -> String? {
            guard let arr = value as? [Any], !arr.isEmpty else { return nil }
            if let s = arr[0] as? String { return s }
            if let n = arr[0] as? Int { return String(n) }
            return nil
        }

        func collectPrompts(from startID: String?, visited: inout Set<String>) -> [String] {
            guard let nodeID = startID, visited.insert(nodeID).inserted,
                  let node = nodes[nodeID] else { return [] }
            let inputs = node.inputs
            let lowerType = node.classType.lowercased()

            var found: [String] = []
            // Direct prompt text keys on CLIPTextEncode / Flux / SDXL / String nodes
            for key in ["text", "clip_l", "t5xxl", "text_g", "text_l", "prompt", "positive", "string", "value"] {
                if let str = inputs[key] as? String {
                    let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && !found.contains(trimmed) {
                        found.append(trimmed)
                    }
                } else if let linked = linkedNodeID(inputs[key]) {
                    found.append(contentsOf: collectPrompts(from: linked, visited: &visited))
                }
            }

            // Follow pass-through conditioning nodes (FluxGuidance, ControlNetApply, ConditioningCombine, etc.)
            if found.isEmpty || lowerType.contains("combine") || lowerType.contains("concat") {
                for key in ["conditioning", "conditioning_1", "conditioning_2", "conditioning_to", "conditioning_from", "positive", "guider"] {
                    if let linked = linkedNodeID(inputs[key]) {
                        found.append(contentsOf: collectPrompts(from: linked, visited: &visited))
                    }
                }
            }
            return found
        }

        var positiveTexts: [String] = []
        var negativeTexts: [String] = []
        var steps: Int?
        var cfg: Double?
        var sampler: String?
        var scheduler: String?
        var seed: String?
        var modelName: String?
        var sizeText: String?
        var loras: [String] = []

        // 1. Inspect Sampler / Scheduler / Noise / Guider nodes
        for (_, node) in nodes {
            let lower = node.classType.lowercased()
            let inputs = node.inputs

            if lower.contains("ksampler") || lower.contains("samplercustom") || lower.contains("sampler") {
                if steps == nil { steps = intValue(inputs["steps"]) }
                if cfg == nil { cfg = doubleValue(inputs["cfg"]) }
                if sampler == nil { sampler = cleanString(inputs["sampler_name"]) }
                if scheduler == nil { scheduler = cleanString(inputs["scheduler"]) }
                if seed == nil {
                    if let s = int64String(inputs["seed"] ?? inputs["noise_seed"]) {
                        seed = s
                    }
                }
                var vPos = Set<String>()
                if let posID = linkedNodeID(inputs["positive"]) {
                    positiveTexts.append(contentsOf: collectPrompts(from: posID, visited: &vPos))
                } else if let guiderID = linkedNodeID(inputs["guider"]) {
                    positiveTexts.append(contentsOf: collectPrompts(from: guiderID, visited: &vPos))
                }
                var vNeg = Set<String>()
                if let negID = linkedNodeID(inputs["negative"]) {
                    negativeTexts.append(contentsOf: collectPrompts(from: negID, visited: &vNeg))
                }
            }

            if lower.contains("randomnoise") && seed == nil {
                seed = int64String(inputs["noise_seed"])
            }
            if lower.contains("basicscheduler") {
                if steps == nil { steps = intValue(inputs["steps"]) }
                if scheduler == nil { scheduler = cleanString(inputs["scheduler"]) }
            }
            if lower.contains("ksamplerselect") && sampler == nil {
                sampler = cleanString(inputs["sampler_name"])
            }
            if lower.contains("fluxguidance") && cfg == nil {
                cfg = doubleValue(inputs["guidance"])
            }

            if (lower.contains("checkpointloader") || lower.contains("unetloader") || lower.contains("diffusionmodel")) && modelName == nil {
                if let ckpt = cleanString(inputs["ckpt_name"]) ?? cleanString(inputs["unet_name"]) ?? cleanString(inputs["model_name"]) {
                    modelName = (ckpt as NSString).lastPathComponent
                }
            }
            if lower.contains("lora") {
                if let lora = cleanString(inputs["lora_name"]) {
                    let clean = (lora as NSString).lastPathComponent
                    if !loras.contains(clean) { loras.append(clean) }
                }
            }
            if lower.contains("latentimage") && sizeText == nil {
                if let w = intValue(inputs["width"]), let h = intValue(inputs["height"]), w > 0, h > 0 {
                    sizeText = "\(w) × \(h)"
                }
            }
        }

        // Fallback if custom sampler node wasn't matched: collect CLIPTextEncode nodes directly
        if positiveTexts.isEmpty {
            let sortedIDs = nodes.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
            var candidates: [String] = []
            for id in sortedIDs {
                guard let node = nodes[id], node.classType.lowercased().contains("cliptextencode") else { continue }
                if let txt = cleanString(node.inputs["text"]) ?? cleanString(node.inputs["t5xxl"]) ?? cleanString(node.inputs["clip_l"]),
                   !candidates.contains(txt) {
                    candidates.append(txt)
                }
            }
            if let first = candidates.first { positiveTexts.append(first) }
            if candidates.count >= 2 && negativeTexts.isEmpty { negativeTexts.append(candidates[1]) }
        }

        let posJoined = deduplicatedLines(positiveTexts).joined(separator: "\n")
        let negJoined = deduplicatedLines(negativeTexts).joined(separator: "\n")

        let meta = AIGenerationMetadata(
            generator: "ComfyUI",
            prompt: posJoined.isEmpty ? nil : posJoined,
            negativePrompt: negJoined.isEmpty ? nil : negJoined,
            modelName: modelName,
            sampler: sampler,
            scheduler: scheduler,
            steps: steps,
            cfgScale: cfg,
            seed: seed,
            sizeText: sizeText,
            loras: loras,
            rawParameters: String(rawJSON.prefix(8000))
        )
        return meta.isEmpty ? nil : meta
    }

    private static func parseNovelAIMetadata(commentJSON: String, description: String?) -> AIGenerationMetadata? {
        guard let data = commentJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let prompt = cleanString(dict["prompt"]) ?? cleanString(description)
        let negative = cleanString(dict["uc"])
        let steps = intValue(dict["steps"])
        let sampler = cleanString(dict["sampler"])
        let cfg = doubleValue(dict["scale"])
        let seed = int64String(dict["seed"])
        var sizeText: String?
        if let w = intValue(dict["width"]), let h = intValue(dict["height"]), w > 0, h > 0 {
            sizeText = "\(w) × \(h)"
        }
        let meta = AIGenerationMetadata(
            generator: "NovelAI",
            prompt: prompt,
            negativePrompt: negative,
            sampler: sampler,
            steps: steps,
            cfgScale: cfg,
            seed: seed,
            sizeText: sizeText,
            rawParameters: String(commentJSON.prefix(8000))
        )
        return meta.isEmpty ? nil : meta
    }

    private static func parseInvokeAIMetadata(_ rawJSON: String) -> AIGenerationMetadata? {
        guard let data = rawJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let prompt = cleanString(dict["positive_prompt"]) ?? cleanString(dict["prompt"])
        let negative = cleanString(dict["negative_prompt"])
        let modelDict = dict["model"] as? [String: Any]
        let modelName = cleanString(modelDict?["name"]) ?? cleanString(dict["model_name"])
        let sampler = cleanString(dict["scheduler"]) ?? cleanString(dict["sampler"])
        let steps = intValue(dict["steps"])
        let cfg = doubleValue(dict["cfg_scale"])
        let seed = int64String(dict["seed"])
        var sizeText: String?
        if let w = intValue(dict["width"]), let h = intValue(dict["height"]), w > 0, h > 0 {
            sizeText = "\(w) × \(h)"
        }
        let meta = AIGenerationMetadata(
            generator: "InvokeAI",
            prompt: prompt,
            negativePrompt: negative,
            modelName: modelName,
            sampler: sampler,
            steps: steps,
            cfgScale: cfg,
            seed: seed,
            sizeText: sizeText,
            rawParameters: String(rawJSON.prefix(8000))
        )
        return meta.isEmpty ? nil : meta
    }

    private static func parseMidjourneyDescription(_ desc: String) -> AIGenerationMetadata {
        var cleanPrompt = desc
        var extras: [String: String] = [:]
        if let jobRange = cleanPrompt.range(of: "Job ID:") {
            let jobID = String(cleanPrompt[jobRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !jobID.isEmpty { extras["Job ID"] = jobID }
            cleanPrompt = String(cleanPrompt[..<jobRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var modelName: String?
        if let vRange = cleanPrompt.range(of: #"--(?:v|version)\s+([0-9.]+)"#, options: .regularExpression) {
            modelName = "Midjourney " + String(cleanPrompt[vRange]).replacingOccurrences(of: "--version", with: "v").replacingOccurrences(of: "--v", with: "v").replacingOccurrences(of: " ", with: "")
        } else if cleanPrompt.contains("--niji") {
            modelName = "Midjourney Niji"
        }
        var seed: String?
        if let sRegex = try? NSRegularExpression(pattern: #"--seed\s+(\d+)"#),
           let m = sRegex.firstMatch(in: cleanPrompt, range: NSRange(cleanPrompt.startIndex..., in: cleanPrompt)),
           let r = Range(m.range(at: 1), in: cleanPrompt) {
            seed = String(cleanPrompt[r])
        }
        return AIGenerationMetadata(
            generator: "Midjourney",
            prompt: cleanPrompt,
            modelName: modelName,
            seed: seed,
            extraParameters: extras,
            rawParameters: String(desc.prefix(8000))
        )
    }

    private static func parseGenericAIJSON(_ rawJSON: String) -> AIGenerationMetadata? {
        guard let data = rawJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Check SwarmUI `sui_image_params`
        if let sui = dict["sui_image_params"] as? [String: Any] {
            let prompt = cleanString(sui["prompt"])
            let neg = cleanString(sui["negativeprompt"])
            let model = cleanString(sui["model"])
            let steps = intValue(sui["steps"])
            let cfg = doubleValue(sui["cfgscale"])
            let seed = int64String(sui["seed"])
            let sampler = cleanString(sui["sampler"])
            let scheduler = cleanString(sui["scheduler"])
            let meta = AIGenerationMetadata(
                generator: "SwarmUI",
                prompt: prompt,
                negativePrompt: neg,
                modelName: model,
                sampler: sampler,
                scheduler: scheduler,
                steps: steps,
                cfgScale: cfg,
                seed: seed,
                rawParameters: String(rawJSON.prefix(8000))
            )
            if !meta.isEmpty { return meta }
        }
        // Check Draw Things JSON (`c` = prompt, `uc` = negative prompt, `model`, `steps`, `scale`, `seed`, `sampler`, `size`)
        if let cPrompt = cleanString(dict["c"]) {
            let meta = AIGenerationMetadata(
                generator: "Draw Things",
                prompt: cPrompt,
                negativePrompt: cleanString(dict["uc"]),
                modelName: cleanString(dict["model"]),
                sampler: cleanString(dict["sampler"]),
                steps: intValue(dict["steps"]),
                cfgScale: doubleValue(dict["scale"]),
                seed: int64String(dict["seed"]),
                sizeText: cleanString(dict["size"]),
                rawParameters: String(rawJSON.prefix(8000))
            )
            if !meta.isEmpty { return meta }
        }
        // ComfyUI graph JSON stored inside EXIF UserComment
        if let comfy = parseComfyUIPromptJSON(rawJSON) {
            return comfy
        }
        // NovelAI JSON stored inside EXIF UserComment
        if let nai = parseNovelAIMetadata(commentJSON: rawJSON, description: nil) {
            return nai
        }
        // Generic `prompt` JSON object
        if let prompt = cleanString(dict["prompt"]) ?? cleanString(dict["positive_prompt"]) {
            let meta = AIGenerationMetadata(
                generator: cleanString(dict["generator"]) ?? cleanString(dict["software"]) ?? "AI 生成",
                prompt: prompt,
                negativePrompt: cleanString(dict["negative_prompt"]) ?? cleanString(dict["uc"]),
                modelName: cleanString(dict["model"]),
                sampler: cleanString(dict["sampler"]),
                steps: intValue(dict["steps"]),
                cfgScale: doubleValue(dict["cfg_scale"] ?? dict["cfg"] ?? dict["scale"]),
                seed: int64String(dict["seed"]),
                rawParameters: String(rawJSON.prefix(8000))
            )
            if !meta.isEmpty { return meta }
        }
        return nil
    }

    // MARK: - Helpers

    private static func parseCommaSeparatedKeyValues(_ raw: String) -> [String: String] {
        guard !raw.isEmpty else { return [:] }
        var pairs: [String: String] = [:]
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var braceDepth = 0

        for ch in raw {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if !inQuotes && (ch == "{" || ch == "[") {
                braceDepth += 1
                current.append(ch)
            } else if !inQuotes && (ch == "}" || ch == "]") {
                braceDepth = max(0, braceDepth - 1)
                current.append(ch)
            } else if ch == "," && !inQuotes && braceDepth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }

        for part in parts {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let key = String(part[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            var val = String(part[part.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            if !key.isEmpty && !val.isEmpty {
                pairs[key] = val
            }
        }
        return pairs
    }

    private static func extractLoraTags(from prompt: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"<lora:([^:>]+)(?::([^>]+))?>"#) else { return [] }
        let matches = regex.matches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt))
        var out: [String] = []
        for m in matches {
            guard let nameR = Range(m.range(at: 1), in: prompt) else { continue }
            let name = String(prompt[nameR]).trimmingCharacters(in: .whitespacesAndNewlines)
            let label: String
            if let weightR = Range(m.range(at: 2), in: prompt) {
                label = "\(name):\(prompt[weightR])"
            } else {
                label = name
            }
            if !name.isEmpty && !out.contains(label) {
                out.append(label)
            }
        }
        return out
    }

    private static func decodeExifUserComment(_ raw: Any?) -> String? {
        if let str = raw as? String {
            return cleanExifCommentPrefix(str)
        }
        if let data = raw as? Data, !data.isEmpty {
            if data.count > 8 {
                let prefix = String(bytes: data.prefix(8), encoding: .ascii) ?? ""
                let body = data.dropFirst(8)
                if prefix.hasPrefix("UNICODE") {
                    if let s = decodeUTF16Smart(body) {
                        return s.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
                    }
                } else if prefix.hasPrefix("ASCII") {
                    if let s = String(data: body, encoding: .utf8) ?? String(data: body, encoding: .ascii) {
                        return s.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
                    }
                }
            }
            return (String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1))
                .flatMap(cleanExifCommentPrefix)
        }
        return nil
    }

    /// Detects UTF-16 byte order (BOM or null-byte lane heuristic) before decoding EXIF `UNICODE\0` comments
    /// so UTF-16LE payloads from A1111/Forge/Civitai JPEGs are never misread as UTF-16BE mojibake.
    private static func decodeUTF16Smart(_ body: Data) -> String? {
        guard body.count >= 2 else { return nil }
        let bytes = Array(body)
        if bytes[0] == 0xFE && bytes[1] == 0xFF {
            return String(data: body.dropFirst(2), encoding: .utf16BigEndian)
        }
        if bytes[0] == 0xFF && bytes[1] == 0xFE {
            return String(data: body.dropFirst(2), encoding: .utf16LittleEndian)
        }
        let sampleLen = min(bytes.count & ~1, 256)
        var evenZeros = 0
        var oddZeros = 0
        var i = 0
        while i + 1 < sampleLen {
            if bytes[i] == 0 { evenZeros += 1 }
            if bytes[i + 1] == 0 { oddZeros += 1 }
            i += 2
        }
        let preferLE = oddZeros > evenZeros
        let primary: String.Encoding = preferLE ? .utf16LittleEndian : .utf16BigEndian
        let secondary: String.Encoding = preferLE ? .utf16BigEndian : .utf16LittleEndian
        return String(data: body, encoding: primary) ?? String(data: body, encoding: secondary)
    }

    private static func cleanExifCommentPrefix(_ raw: String) -> String? {
        var s = raw.replacingOccurrences(of: "\0", with: "")
        for prefix in ["UNICODE", "ASCII", "JIS"] {
            if s.hasPrefix(prefix) && s.count > prefix.count {
                let rest = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if rest.hasPrefix("{") || rest.contains("Steps:") || rest.contains("Negative prompt:") {
                    s = rest
                }
            }
        }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func extractTagContent(from xml: String, tagName: String) -> String? {
        let pattern = #"<\#(tagName)\b[^>]*>([\s\S]*?)<\/\#(tagName)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let r = Range(m.range(at: 1), in: xml) else {
            return nil
        }
        let inner = String(xml[r])
        let liClean = inner.replacingOccurrences(of: #"<\/?rdf:[^>]+>"#, with: "", options: .regularExpression)
        let decoded = MarkdownDocumentParser.decodeHTMLEntities(liClean).trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    private static func deduplicatedLines(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && seen.insert(trimmed).inserted {
                out.append(trimmed)
            }
        }
        return out
    }

    private static func cleanString(_ value: Any?) -> String? {
        guard let str = value as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstStringValue(_ value: Any?) -> String? {
        if let s = cleanString(value) { return s }
        if let arr = value as? [Any] {
            for item in arr {
                if let s = cleanString(item) { return s }
            }
        }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d.isFinite ? d : nil }
        if let n = value as? NSNumber { return n.doubleValue.isFinite ? n.doubleValue : nil }
        if let s = value as? String, let parsed = Double(s.trimmingCharacters(in: .whitespaces)), parsed.isFinite {
            return parsed
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func firstIntValue(_ value: Any?) -> Int? {
        if let i = intValue(value) { return i }
        if let arr = value as? [Any], let first = arr.first { return intValue(first) }
        return nil
    }

    private static func int64String(_ value: Any?) -> String? {
        if let i = value as? Int64 { return String(i) }
        if let i = value as? Int { return String(i) }
        if let u = value as? UInt64 { return String(u) }
        if let n = value as? NSNumber { return n.stringValue }
        if let s = cleanString(value) { return s }
        return nil
    }
}
