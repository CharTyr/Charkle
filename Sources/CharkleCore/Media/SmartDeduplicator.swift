import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

// MARK: - Smart Deduplication Models (100% Classical Non-AI Multi-Media Algorithms)

public enum DeduplicationSensitivity: String, CaseIterable, Codable, Hashable, Sendable {
    case strict
    case balanced
    case relaxed

    public var localizedLabel: String {
        switch self {
        case .strict: "精确"
        case .balanced: "智能平衡（推荐）"
        case .relaxed: "宽松"
        }
    }

    public var subtitle: String {
        switch self {
        case .strict: "仅检出完全一致、规范化链接一致或近无损转码版本"
        case .balanced: "检出不同分辨率、码率、压缩画质及格式转换的同内容版本"
        case .relaxed: "额外检出含轻微裁边、水印、二次截图或轻度剪辑差异的版本"
        }
    }

    struct Thresholds: Sendable {
        let maxAspectRatioFactor: Double
        let maxPHashHamming: Int
        let maxDHashHamming: Int
        let altTightPHash: Int
        let altLooseDHash: Int
        let minLumaZNCC: Double
        let maxColorMAD: Double
        let flatImageMaxColorMAD: Double
        let videoDurationAbsSeconds: Double
        let videoDurationRelRatio: Double
        let audioDurationAbsSeconds: Double
        let audioDurationRelRatio: Double
        let minAudioWaveformZNCC: Double
        let maxAudioEnvelopeMAD: Double
    }

    var thresholds: Thresholds {
        switch self {
        case .strict:
            Thresholds(
                maxAspectRatioFactor: 1.04,
                maxPHashHamming: 4,
                maxDHashHamming: 5,
                altTightPHash: 2,
                altLooseDHash: 8,
                minLumaZNCC: 0.985,
                maxColorMAD: 6.5 / 255.0,
                flatImageMaxColorMAD: 2.0 / 255.0,
                videoDurationAbsSeconds: 0.5,
                videoDurationRelRatio: 0.02,
                audioDurationAbsSeconds: 0.25,
                audioDurationRelRatio: 0.01,
                minAudioWaveformZNCC: 0.985,
                maxAudioEnvelopeMAD: 0.04
            )
        case .balanced:
            Thresholds(
                maxAspectRatioFactor: 1.10,
                maxPHashHamming: 8,
                maxDHashHamming: 10,
                altTightPHash: 5,
                altLooseDHash: 14,
                minLumaZNCC: 0.955,
                maxColorMAD: 12.0 / 255.0,
                flatImageMaxColorMAD: 2.5 / 255.0,
                videoDurationAbsSeconds: 1.5,
                videoDurationRelRatio: 0.06,
                audioDurationAbsSeconds: 0.65,
                audioDurationRelRatio: 0.025,
                minAudioWaveformZNCC: 0.96,
                maxAudioEnvelopeMAD: 0.075
            )
        case .relaxed:
            Thresholds(
                maxAspectRatioFactor: 1.18,
                maxPHashHamming: 12,
                maxDHashHamming: 14,
                altTightPHash: 9,
                altLooseDHash: 18,
                minLumaZNCC: 0.915,
                maxColorMAD: 18.0 / 255.0,
                flatImageMaxColorMAD: 3.5 / 255.0,
                videoDurationAbsSeconds: 3.0,
                videoDurationRelRatio: 0.12,
                audioDurationAbsSeconds: 1.5,
                audioDurationRelRatio: 0.05,
                minAudioWaveformZNCC: 0.92,
                maxAudioEnvelopeMAD: 0.12
            )
        }
    }
}

public enum DuplicateMatchKind: String, Codable, Hashable, Sendable {
    case exactBinary
    case nearIdentical
    case canonicalLink
    case normalizedText
    case audioWaveform

    public var localizedLabel: String {
        switch self {
        case .exactBinary: "完全相同"
        case .nearIdentical: "同画面不同版本"
        case .canonicalLink: "同一链接 / 帖子"
        case .normalizedText: "文本内容一致"
        case .audioWaveform: "同音频不同码率/格式"
        }
    }
}

public enum DuplicateDisposalMode: String, CaseIterable, Codable, Hashable, Sendable {
    case moveToTrash
    case permanentlyDelete

    public var localizedLabel: String {
        switch self {
        case .moveToTrash: "移至废纸篓（可恢复）"
        case .permanentlyDelete: "彻底删除并释放空间"
        }
    }
}

public enum DeduplicationScanScope: Hashable, Sendable {
    case allActive
    case folder(UUID, includeSubfolders: Bool)
    case inbox
}

public struct DeduplicationScanProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let phase: String

    public init(completed: Int, total: Int, phase: String) {
        self.completed = completed
        self.total = total
        self.phase = phase
    }
}

public struct DuplicateAssetCandidate: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID { asset.id }
    public let asset: AssetRecord
    public let qualityScore: Double
    public let resolutionPixels: Int64
    public let formatLabel: String
    public let isLosslessFormat: Bool
    public let sharpnessScore: Double
    public let isRecommendedKeep: Bool
    public let isReferencedByBoard: Bool
    public let similarityToKeeper: Double
    public let qualityReasons: [String]

    public init(
        asset: AssetRecord,
        qualityScore: Double,
        resolutionPixels: Int64,
        formatLabel: String,
        isLosslessFormat: Bool,
        sharpnessScore: Double,
        isRecommendedKeep: Bool,
        isReferencedByBoard: Bool,
        similarityToKeeper: Double,
        qualityReasons: [String]
    ) {
        self.asset = asset
        self.qualityScore = qualityScore
        self.resolutionPixels = resolutionPixels
        self.formatLabel = formatLabel
        self.isLosslessFormat = isLosslessFormat
        self.sharpnessScore = sharpnessScore
        self.isRecommendedKeep = isRecommendedKeep
        self.isReferencedByBoard = isReferencedByBoard
        self.similarityToKeeper = similarityToKeeper
        self.qualityReasons = qualityReasons
    }
}

public struct DuplicateGroup: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let primaryMediaKind: MediaKind
    public let matchKind: DuplicateMatchKind
    public let similarityScore: Double
    public let recommendedKeepAssetID: UUID
    public let candidates: [DuplicateAssetCandidate]

    public var reclaimableBytes: Int64 {
        candidates
            .filter { $0.asset.id != recommendedKeepAssetID }
            .reduce(Int64(0)) { $0 + max(Int64(0), $1.asset.fileSizeBytes) }
    }

    public init(
        id: UUID = UUID(),
        primaryMediaKind: MediaKind = .image,
        matchKind: DuplicateMatchKind,
        similarityScore: Double,
        recommendedKeepAssetID: UUID,
        candidates: [DuplicateAssetCandidate]
    ) {
        self.id = id
        self.primaryMediaKind = primaryMediaKind
        self.matchKind = matchKind
        self.similarityScore = similarityScore
        self.recommendedKeepAssetID = recommendedKeepAssetID
        self.candidates = candidates
    }
}

public struct DeduplicationScanReport: Codable, Hashable, Sendable {
    public let scannedAssetCount: Int
    public let skippedNonVisualCount: Int
    public let groups: [DuplicateGroup]
    public let totalDuplicateItems: Int
    public let totalReclaimableBytes: Int64
    public let durationSeconds: Double

    public init(
        scannedAssetCount: Int,
        skippedNonVisualCount: Int,
        groups: [DuplicateGroup],
        totalDuplicateItems: Int,
        totalReclaimableBytes: Int64,
        durationSeconds: Double
    ) {
        self.scannedAssetCount = scannedAssetCount
        self.skippedNonVisualCount = skippedNonVisualCount
        self.groups = groups
        self.totalDuplicateItems = totalDuplicateItems
        self.totalReclaimableBytes = totalReclaimableBytes
        self.durationSeconds = durationSeconds
    }
}

public struct DeduplicationResolutionPlan: Codable, Hashable, Sendable {
    public let keepAssetID: UUID
    public let removeAssetIDs: [UUID]

    public init(keepAssetID: UUID, removeAssetIDs: [UUID]) {
        self.keepAssetID = keepAssetID
        self.removeAssetIDs = removeAssetIDs
    }
}

public struct DeduplicationCleanupResult: Codable, Hashable, Sendable {
    public let resolvedGroupCount: Int
    public let removedAssetCount: Int
    public let reclaimedBytes: Int64
    public let mergedMetadataCount: Int
    public let updatedBoardCount: Int

    public init(
        resolvedGroupCount: Int,
        removedAssetCount: Int,
        reclaimedBytes: Int64,
        mergedMetadataCount: Int,
        updatedBoardCount: Int
    ) {
        self.resolvedGroupCount = resolvedGroupCount
        self.removedAssetCount = removedAssetCount
        self.reclaimedBytes = reclaimedBytes
        self.mergedMetadataCount = mergedMetadataCount
        self.updatedBoardCount = updatedBoardCount
    }
}

// MARK: - Classical Non-AI Perceptual Image Fingerprint

public nonisolated struct ClassicalImageFingerprint: Codable, Hashable, Sendable {
    /// 64-bit 2D-DCT perceptual hash (8×8 low frequencies from 32×32 luminance).
    public let pHash: UInt64
    /// 64-bit horizontal gradient difference hash (9×8 luminance).
    public let dHash: UInt64
    /// Normalized 16×16 luminance grid (256 samples, 0...255).
    public let luma16: [UInt8]
    /// Normalized 8×8 sRGB color grid (192 bytes: R, G, B per pixel).
    public let rgb8: [UInt8]
    /// Standard deviation of `luma16` (guards against solid-color swatches falsely matching).
    public let lumaStdDev: Float
    /// Deterministic Laplacian edge-sharpness estimate (0...100).
    public let sharpness: Float
    /// Decoded pixel aspect ratio (`width / height`).
    public let aspectRatio: Double

    public init(
        pHash: UInt64,
        dHash: UInt64,
        luma16: [UInt8],
        rgb8: [UInt8],
        lumaStdDev: Float,
        sharpness: Float,
        aspectRatio: Double
    ) {
        self.pHash = pHash
        self.dHash = dHash
        self.luma16 = luma16
        self.rgb8 = rgb8
        self.lumaStdDev = lumaStdDev
        self.sharpness = sharpness
        self.aspectRatio = aspectRatio
    }
}

// MARK: - Non-AI Multi-Media Smart Deduplication Engine

public nonisolated enum SmartDeduplicator {
    /// Precomputed 8×32 DCT-II cosine table: `cos((2x + 1) * u * pi / 64)`.
    private static let dctCosTable: [[Double]] = {
        var table = Array(repeating: Array(repeating: 0.0, count: 32), count: 8)
        for u in 0..<8 {
            let scale = (u == 0) ? sqrt(1.0 / 32.0) : sqrt(2.0 / 32.0)
            for x in 0..<32 {
                table[u][x] = scale * cos((2.0 * Double(x) + 1.0) * Double(u) * .pi / 64.0)
            }
        }
        return table
    }()

    /// Isolated comparison domains so incompatible kinds never accidentally replace one another
    /// (e.g., an exported PNG never deletes an editable PSD; a static thumbnail never deletes a video).
    private enum MediaComparisonBucket: Hashable {
        case rasterVisual // .image + .animatedImage
        case video
        case audio
        case designFile
        case webBookmark
        case document
        case model3D

        static func bucket(for kind: MediaKind) -> MediaComparisonBucket {
            switch kind {
            case .image, .animatedImage: .rasterVisual
            case .video: .video
            case .audio: .audio
            case .designFile: .designFile
            case .webBookmark: .webBookmark
            case .document: .document
            case .model3D: .model3D
            }
        }
    }

    public static func needsVisualFingerprint(for kind: MediaKind) -> Bool {
        switch kind {
        case .image, .animatedImage, .video, .designFile, .model3D:
            true
        case .audio, .webBookmark, .document:
            false
        }
    }

    // MARK: - Deterministic Visual Fingerprint Computation

    public static func computeFingerprint(from url: URL, declaredAspectRatio: Double? = nil) -> ClassicalImageFingerprint? {
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary) else {
            return nil
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256
        ]
        let cgImage: CGImage?
        if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) {
            cgImage = thumb
        } else {
            cgImage = CGImageSourceCreateImageAtIndex(source, 0, opts as CFDictionary)
        }
        guard let image = cgImage else { return nil }
        return computeFingerprint(from: image, declaredAspectRatio: declaredAspectRatio)
    }

    public static func computeFingerprint(from image: CGImage, declaredAspectRatio: Double? = nil) -> ClassicalImageFingerprint? {
        guard image.width >= 4, image.height >= 4 else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        // 1. Render 32×32 RGBA8888 (for DCT pHash, 16×16 luma ZNCC, and 8×8 RGB color MAD)
        var rgba32 = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let rendered32 = rgba32.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress,
                width: 32,
                height: 32,
                bitsPerComponent: 8,
                bytesPerRow: 32 * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        guard rendered32 else { return nil }

        // 2. Render 9×8 RGBA8888 for horizontal gradient dHash
        var rgba9x8 = [UInt8](repeating: 0, count: 9 * 8 * 4)
        let rendered9x8 = rgba9x8.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress,
                width: 9,
                height: 8,
                bitsPerComponent: 8,
                bytesPerRow: 9 * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 9, height: 8))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            return true
        }
        guard rendered9x8 else { return nil }

        // 3. Extract 32×32 Rec.709 luminance matrix
        var luma32 = [Double](repeating: 0, count: 32 * 32)
        for i in 0..<(32 * 32) {
            let o = i * 4
            luma32[i] = 0.2126 * Double(rgba32[o]) + 0.7152 * Double(rgba32[o + 1]) + 0.0722 * Double(rgba32[o + 2])
        }

        let pHash = computePHash(fromLuma32: luma32)

        var dHash: UInt64 = 0
        var bitIndex: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                let leftOff = (y * 9 + x) * 4
                let rightOff = leftOff + 4
                let lLuma = 0.2126 * Double(rgba9x8[leftOff]) + 0.7152 * Double(rgba9x8[leftOff + 1]) + 0.0722 * Double(rgba9x8[leftOff + 2])
                let rLuma = 0.2126 * Double(rgba9x8[rightOff]) + 0.7152 * Double(rgba9x8[rightOff + 1]) + 0.0722 * Double(rgba9x8[rightOff + 2])
                if lLuma < rLuma {
                    dHash |= (1 &<< bitIndex)
                }
                bitIndex += 1
            }
        }

        var luma16 = [UInt8](repeating: 0, count: 16 * 16)
        var sumL: Double = 0
        var sumL2: Double = 0
        for y in 0..<16 {
            for x in 0..<16 {
                let y2 = y * 2
                let x2 = x * 2
                let avg = (luma32[y2 * 32 + x2]
                    + luma32[y2 * 32 + x2 + 1]
                    + luma32[(y2 + 1) * 32 + x2]
                    + luma32[(y2 + 1) * 32 + x2 + 1]) * 0.25
                let clamped = UInt8(max(0, min(255, Int(avg.rounded()))))
                luma16[y * 16 + x] = clamped
                let v = Double(clamped)
                sumL += v
                sumL2 += v * v
            }
        }
        let meanL = sumL / 256.0
        let varianceL = max(0.0, (sumL2 / 256.0) - meanL * meanL)
        let lumaStdDev = Float(sqrt(varianceL))

        var rgb8 = [UInt8](repeating: 0, count: 8 * 8 * 3)
        for by in 0..<8 {
            for bx in 0..<8 {
                var sr = 0
                var sg = 0
                var sb = 0
                for dy in 0..<4 {
                    let row = (by * 4 + dy) * 32
                    for dx in 0..<4 {
                        let o = (row + bx * 4 + dx) * 4
                        sr += Int(rgba32[o])
                        sg += Int(rgba32[o + 1])
                        sb += Int(rgba32[o + 2])
                    }
                }
                let outOff = (by * 8 + bx) * 3
                rgb8[outOff] = UInt8(sr >> 4)
                rgb8[outOff + 1] = UInt8(sg >> 4)
                rgb8[outOff + 2] = UInt8(sb >> 4)
            }
        }

        let sharpness = computeLaplacianSharpness(image: image, colorSpace: colorSpace)
        let aspect: Double = {
            if let declared = declaredAspectRatio, declared.isFinite, declared > 0.02, declared < 50 {
                return declared
            }
            return Double(image.width) / Double(max(1, image.height))
        }()

        return ClassicalImageFingerprint(
            pHash: pHash,
            dHash: dHash,
            luma16: luma16,
            rgb8: rgb8,
            lumaStdDev: lumaStdDev,
            sharpness: sharpness,
            aspectRatio: aspect
        )
    }

    private static func computePHash(fromLuma32 luma: [Double]) -> UInt64 {
        var rowDCT = [Double](repeating: 0, count: 32 * 8)
        for y in 0..<32 {
            let rowBase = y * 32
            for u in 0..<8 {
                let cosU = dctCosTable[u]
                var acc = 0.0
                for x in 0..<32 {
                    acc += luma[rowBase + x] * cosU[x]
                }
                rowDCT[y * 8 + u] = acc
            }
        }

        var coeffs = [Double](repeating: 0, count: 64)
        for v in 0..<8 {
            let cosV = dctCosTable[v]
            for u in 0..<8 {
                var acc = 0.0
                for y in 0..<32 {
                    acc += rowDCT[y * 8 + u] * cosV[y]
                }
                coeffs[v * 8 + u] = acc
            }
        }

        let ac = Array(coeffs.dropFirst()).sorted()
        let median = ac[ac.count / 2]

        var hash: UInt64 = 0
        for i in 1..<64 {
            if coeffs[i] > median {
                hash |= (1 &<< UInt64(i))
            }
        }
        if coeffs[0] > 32.0 * 128.0 {
            hash |= 1
        }
        return hash
    }

    private static func computeLaplacianSharpness(image: CGImage, colorSpace: CGColorSpace) -> Float {
        let maxSide = 128
        let srcW = max(1, image.width)
        let srcH = max(1, image.height)
        let scale = min(1.0, Double(maxSide) / Double(max(srcW, srcH)))
        let w = max(8, Int((Double(srcW) * scale).rounded()))
        let h = max(8, Int((Double(srcH) * scale).rounded()))

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return 0 }

        var luma = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let o = i * 4
            luma[i] = 0.2126 * Float(rgba[o]) + 0.7152 * Float(rgba[o + 1]) + 0.0722 * Float(rgba[o + 2])
        }

        var sum: Double = 0
        var sumSq: Double = 0
        var count = 0
        for y in 1..<(h - 1) {
            let row = y * w
            for x in 1..<(w - 1) {
                let c = luma[row + x]
                let lap = Double(luma[row - w + x] + luma[row + w + x] + luma[row + x - 1] + luma[row + x + 1] - 4.0 * c)
                sum += lap
                sumSq += lap * lap
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / Double(count)
        let variance = max(0.0, (sumSq / Double(count)) - mean * mean)
        return Float(min(100.0, log1p(variance) * 11.5))
    }

    // MARK: - Canonical Keys for Web Bookmarks & Normalized Documents

    private static let trackingQueryParams: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id",
        "fbclid", "gclid", "dclid", "msclkid", "igshid", "mc_cid", "mc_eid",
        "ref", "ref_src", "ref_url", "spm", "spm_id_from", "from", "share_source",
        "share_medium", "share_session_id", "s", "t", "xsec_token", "xsec_source"
    ]

    public static func canonicalBookmarkKey(for asset: AssetRecord) -> String? {
        guard asset.mediaKind == .webBookmark else { return nil }
        if let repo = asset.richMetadata?.githubRepo {
            return "github:\(repo.owner.lowercased())/\(repo.repo.lowercased())"
        }
        let raw = asset.richMetadata?.socialPost?.originalURL ?? asset.sourceURL
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed) else {
            return nil
        }
        if let social = SocialPostURLParser.parse(url) {
            return social.dedupKey
        }
        if let repoRef = GitHubRepoURLParser.parse(url) {
            return "github:\(repoRef.owner.lowercased())/\(repoRef.repo.lowercased())"
        }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawHost = comps.host?.lowercased(), !rawHost.isEmpty else {
            return "web:\(trimmed.lowercased())"
        }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        var path = comps.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        let filteredQuery: [URLQueryItem] = (comps.queryItems ?? [])
            .filter { item in
                let lower = item.name.lowercased()
                return !lower.hasPrefix("utm_") && !trackingQueryParams.contains(lower)
            }
            .sorted { ($0.name.lowercased(), $0.value ?? "") < ($1.name.lowercased(), $1.value ?? "") }

        comps.scheme = "https"
        comps.host = host
        comps.path = path
        comps.fragment = nil
        comps.queryItems = filteredQuery.isEmpty ? nil : filteredQuery
        return "web:\((comps.url?.absoluteString ?? trimmed).lowercased())"
    }

    public static func normalizedDocumentTextHash(for asset: AssetRecord, cachedFileURL: URL?) -> String? {
        guard asset.mediaKind == .document else { return nil }
        let rawText: String? = {
            if asset.isPlainTextDocument, let fileURL = cachedFileURL,
               let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
               data.count <= 2 * 1024 * 1024 {
                return String(decoding: data, as: UTF8.self)
            }
            if let ocr = asset.ocrText, ocr.trimmingCharacters(in: .whitespacesAndNewlines).count >= 64 {
                return ocr
            }
            if let excerpt = asset.richMetadata?.textExcerpt, excerpt.trimmingCharacters(in: .whitespacesAndNewlines).count >= 64 {
                return excerpt
            }
            return nil
        }()
        guard let rawText else { return nil }
        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard normalized.count >= 48 else { return nil }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Pairwise Classical Verification (Visual, Video & Audio)

    public static func visualSimilarity(
        between lhs: ClassicalImageFingerprint,
        and rhs: ClassicalImageFingerprint,
        sensitivity: DeduplicationSensitivity
    ) -> Double? {
        let th = sensitivity.thresholds

        let rA = max(0.05, lhs.aspectRatio)
        let rB = max(0.05, rhs.aspectRatio)
        let aspectFactor = max(rA / rB, rB / rA)
        guard aspectFactor <= th.maxAspectRatioFactor else { return nil }

        let colorMAD = rgbMeanAbsoluteDifference(lhs.rgb8, rhs.rgb8)

        let minStd = min(lhs.lumaStdDev, rhs.lumaStdDev)
        let maxStd = max(lhs.lumaStdDev, rhs.lumaStdDev)
        if minStd < 3.5 {
            guard maxStd < 6.0, colorMAD <= th.flatImageMaxColorMAD else { return nil }
            return max(0.0, min(1.0, 1.0 - colorMAD * 4.0))
        }

        let pDist = (lhs.pHash ^ rhs.pHash).nonzeroBitCount
        let dDist = (lhs.dHash ^ rhs.dHash).nonzeroBitCount
        let passesHash = (pDist <= th.maxPHashHamming && dDist <= th.maxDHashHamming)
            || (pDist <= th.altTightPHash && dDist <= th.altLooseDHash)
        guard passesHash else { return nil }

        guard colorMAD <= th.maxColorMAD else { return nil }

        let zncc = lumaZNCC(lhs.luma16, rhs.luma16)
        guard zncc >= th.minLumaZNCC else { return nil }

        let hashSim = 1.0 - (Double(pDist) * 0.6 + Double(dDist) * 0.4) / 64.0
        let colorSim = max(0.0, 1.0 - colorMAD * 2.2)
        let combined = 0.45 * zncc + 0.30 * hashSim + 0.25 * colorSim
        return max(0.0, min(0.999, combined))
    }

    public static func audioWaveformSimilarity(
        durationA: Double?,
        peaksA: [Float],
        durationB: Double?,
        peaksB: [Float],
        sensitivity: DeduplicationSensitivity
    ) -> Double? {
        guard peaksA.count >= 12, peaksB.count >= 12 else { return nil }
        let th = sensitivity.thresholds

        if let dA = durationA, let dB = durationB, dA > 0.2, dB > 0.2 {
            let maxDiff = max(th.audioDurationAbsSeconds, min(dA, dB) * th.audioDurationRelRatio)
            guard abs(dA - dB) <= maxDiff else { return nil }
        }

        let a = resampleNormalizedEnvelope(peaksA, targetCount: 64)
        let b = resampleNormalizedEnvelope(peaksB, targetCount: 64)

        var meanA = 0.0
        var meanB = 0.0
        var mad = 0.0
        for i in 0..<64 {
            meanA += a[i]
            meanB += b[i]
            mad += abs(a[i] - b[i])
        }
        meanA /= 64.0
        meanB /= 64.0
        mad /= 64.0
        guard mad <= th.maxAudioEnvelopeMAD else { return nil }

        var num = 0.0
        var denA = 0.0
        var denB = 0.0
        for i in 0..<64 {
            let da = a[i] - meanA
            let db = b[i] - meanB
            num += da * db
            denA += da * da
            denB += db * db
        }
        let stdA = sqrt(denA / 64.0)
        let stdB = sqrt(denB / 64.0)
        if min(stdA, stdB) < 0.015 {
            guard max(stdA, stdB) < 0.03, mad <= 0.018 else { return nil }
            return max(0.0, min(0.999, 1.0 - mad * 4.0))
        }

        let denom = sqrt(denA * denB)
        guard denom > 1e-6 else { return nil }
        let zncc = num / denom
        guard zncc >= th.minAudioWaveformZNCC else { return nil }
        return max(0.0, min(0.999, 0.65 * zncc + 0.35 * max(0.0, 1.0 - mad * 2.0)))
    }

    private static func resampleNormalizedEnvelope(_ peaks: [Float], targetCount: Int) -> [Double] {
        guard !peaks.isEmpty else { return Array(repeating: 0, count: targetCount) }
        var out = [Double](repeating: 0, count: targetCount)
        let maxIdx = Double(max(0, peaks.count - 1))
        var maxPeak = 0.0
        for i in 0..<targetCount {
            let pos = (Double(i) / Double(max(1, targetCount - 1))) * maxIdx
            let lo = Int(floor(pos))
            let hi = min(peaks.count - 1, lo + 1)
            let frac = pos - Double(lo)
            let val = max(0.0, Double(peaks[lo]) * (1.0 - frac) + Double(peaks[hi]) * frac)
            out[i] = val
            if val > maxPeak { maxPeak = val }
        }
        if maxPeak > 1e-5 {
            for i in 0..<targetCount { out[i] /= maxPeak }
        }
        return out
    }

    private static func rgbMeanAbsoluteDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 1.0 }
        var total = 0
        for i in 0..<n {
            total += abs(Int(a[i]) - Int(b[i]))
        }
        return Double(total) / (Double(n) * 255.0)
    }

    private static func lumaZNCC(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var meanA = 0.0
        var meanB = 0.0
        for i in 0..<n {
            meanA += Double(a[i])
            meanB += Double(b[i])
        }
        meanA /= Double(n)
        meanB /= Double(n)

        var num = 0.0
        var denA = 0.0
        var denB = 0.0
        for i in 0..<n {
            let da = Double(a[i]) - meanA
            let db = Double(b[i]) - meanB
            num += da * db
            denA += da * da
            denB += db * db
        }
        let denom = sqrt(denA * denB)
        guard denom > 1e-6 else { return 0 }
        return num / denom
    }

    // MARK: - Deterministic Highest-Quality Scoring Across All 8 Media Kinds

    public struct QualityEvaluation: Sendable {
        public let score: Double
        public let resolutionPixels: Int64
        public let formatLabel: String
        public let isLosslessFormat: Bool
        public let sharpnessScore: Double
    }

    public static func evaluateQuality(
        for asset: AssetRecord,
        sharpness: Float,
        isReferencedByBoard: Bool
    ) -> QualityEvaluation {
        let ext = (asset.fileName as NSString).pathExtension.lowercased()
        let mime = asset.mimeType.lowercased()
        let sharpnessDouble = max(0.0, min(100.0, Double(sharpness)))
        let tieBreaker = metadataTieBreaker(for: asset, isReferencedByBoard: isReferencedByBoard)

        switch asset.mediaKind {
        case .image, .animatedImage:
            let pixels = Int64(max(1, asset.pixelWidth)) * Int64(max(1, asset.pixelHeight))
            let (formatLabel, isLossless, formatBonus, bppNormFactor): (String, Bool, Double, Double) = {
                if asset.mediaKind == .animatedImage {
                    let label = ext == "apng" ? "APNG 动图" : "GIF 动图"
                    return (label, ext == "apng", 120.0, 0.5)
                }
                switch ext {
                case "png": return ("PNG 无损", true, 32.0, 0.28)
                case "tif", "tiff": return ("TIFF 无损", true, 34.0, 0.22)
                case "bmp": return ("BMP 无损", true, 26.0, 0.16)
                case "jxl": return ("JPEG XL", true, 32.0, 1.3)
                case "heic", "heif": return ("HEIC", false, 18.0, 1.35)
                case "avif": return ("AVIF", false, 18.0, 1.45)
                case "webp": return ("WebP", false, 16.0, 1.2)
                case "jpg", "jpeg": return ("JPG", false, 8.0, 1.0)
                case "gif": return ("GIF", false, 0.0, 0.7)
                default:
                    if mime.contains("png") { return ("PNG 无损", true, 32.0, 0.28) }
                    if mime.contains("webp") { return ("WebP", false, 16.0, 1.2) }
                    if mime.contains("jpeg") || mime.contains("jpg") { return ("JPG", false, 8.0, 1.0) }
                    return (ext.isEmpty ? "图片" : ext.uppercased(), false, 4.0, 1.0)
                }
            }()
            let resolutionScore = log2(max(1.0, Double(pixels))) * 100.0
            let rawBpp = Double(max(Int64(0), asset.fileSizeBytes)) / Double(max(Int64(1), pixels))
            let densityBonus = log2(1.0 + min(4.0, rawBpp * bppNormFactor) * 10.0) * 18.0
            let total = resolutionScore + formatBonus + densityBonus + sharpnessDouble * 0.22 + tieBreaker
            return QualityEvaluation(
                score: total,
                resolutionPixels: pixels,
                formatLabel: formatLabel,
                isLosslessFormat: isLossless,
                sharpnessScore: sharpnessDouble
            )

        case .video:
            let pixels = Int64(max(1, asset.pixelWidth)) * Int64(max(1, asset.pixelHeight))
            let resolutionScore = log2(max(1.0, Double(pixels))) * 100.0
            let duration = max(0.5, asset.durationSeconds ?? 1.0)
            let kbps = (Double(max(Int64(0), asset.fileSizeBytes)) * 8.0) / duration / 1000.0
            let bitrateBonus = log2(1.0 + max(0.0, kbps) / 200.0) * 32.0
            let (formatLabel, formatBonus): (String, Double) = switch ext {
            case "mov": ("MOV 视频", 18.0)
            case "mp4", "m4v": ("MP4 视频", 16.0)
            case "mkv": ("MKV 视频", 16.0)
            case "webm": ("WebM 视频", 10.0)
            default: (ext.isEmpty ? "视频" : "\(ext.uppercased()) 视频", 8.0)
            }
            let total = resolutionScore + bitrateBonus + formatBonus + sharpnessDouble * 0.15 + tieBreaker
            return QualityEvaluation(
                score: total,
                resolutionPixels: pixels,
                formatLabel: formatLabel,
                isLosslessFormat: false,
                sharpnessScore: sharpnessDouble
            )

        case .audio:
            let duration = max(0.5, asset.durationSeconds ?? 1.0)
            let kbps = (Double(max(Int64(0), asset.fileSizeBytes)) * 8.0) / duration / 1000.0
            let (formatLabel, isLossless, formatBonus): (String, Bool, Double) = switch ext {
            case "flac": ("FLAC 无损", true, 320.0)
            case "wav": ("WAV 无损", true, 315.0)
            case "aiff", "aif": ("AIFF 无损", true, 315.0)
            case "alac": ("ALAC 无损", true, 315.0)
            case "caf": ("CAF 音频", true, 300.0)
            case "m4a", "aac": ("AAC / M4A", false, 160.0)
            case "opus": ("Opus 音频", false, 165.0)
            case "ogg": ("OGG 音频", false, 150.0)
            case "mp3": ("MP3", false, 130.0)
            default: (ext.isEmpty ? "音频" : ext.uppercased(), false, 110.0)
            }
            let bitrateScore = log2(1.0 + max(0.0, kbps) / 16.0) * 45.0
            let total = formatBonus + bitrateScore + tieBreaker
            return QualityEvaluation(
                score: total,
                resolutionPixels: 0,
                formatLabel: formatLabel,
                isLosslessFormat: isLossless,
                sharpnessScore: 0
            )

        case .designFile:
            let pixels = Int64(max(1, asset.pixelWidth)) * Int64(max(1, asset.pixelHeight))
            let (formatLabel, isLossless, formatBonus): (String, Bool, Double) = switch ext {
            case "svg": ("SVG 矢量", true, 260.0)
            case "ai", "eps": ("矢量源文件", true, 255.0)
            case "psd", "psb": ("PSD 分层源文件", true, 250.0)
            case "fig": ("Figma 源文件", true, 245.0)
            case "sketch": ("Sketch 源文件", true, 240.0)
            case "afdesign", "afphoto": ("Affinity 源文件", true, 235.0)
            default: (ext.isEmpty ? "设计文件" : ext.uppercased(), true, 200.0)
            }
            let sizeScore = log2(1.0 + Double(max(Int64(0), asset.fileSizeBytes)) / 1024.0) * 14.0
            let resScore = log2(max(1.0, Double(pixels))) * 40.0
            return QualityEvaluation(
                score: formatBonus + resScore + sizeScore + tieBreaker,
                resolutionPixels: pixels,
                formatLabel: formatLabel,
                isLosslessFormat: isLossless,
                sharpnessScore: sharpnessDouble
            )

        case .webBookmark:
            var score = 100.0
            let label: String
            if let post = asset.richMetadata?.socialPost {
                label = post.platform.postTypeLabel
                score += Double(post.effectiveAttachments.count) * 28.0
                if !post.mediaFetchFailed { score += 45.0 }
                if post.videoURL != nil || (asset.fileSizeBytes > 50_000 && post.hasVideo) { score += 35.0 }
                score += min(40.0, Double(post.bodyText.count) * 0.08)
                if post.authorAvatarURL != nil { score += 6.0 }
            } else if let repo = asset.richMetadata?.githubRepo {
                label = "GitHub 仓库"
                score += 60.0
                if !(repo.readmeMarkdown ?? "").isEmpty { score += 35.0 }
                if !(repo.description ?? "").isEmpty { score += 10.0 }
            } else {
                label = "网页书签"
                if asset.pixelWidth > 0 && asset.pixelHeight > 0 { score += 20.0 }
            }
            score += log2(1.0 + Double(max(Int64(0), asset.fileSizeBytes)) / 512.0) * 5.0
            return QualityEvaluation(
                score: score + tieBreaker * 2.0,
                resolutionPixels: Int64(max(0, asset.pixelWidth)) * Int64(max(0, asset.pixelHeight)),
                formatLabel: label,
                isLosslessFormat: false,
                sharpnessScore: 0
            )

        case .document:
            let formatLabel = ext.isEmpty ? "文档" : ext.uppercased()
            let sizeScore = log2(1.0 + Double(max(Int64(0), asset.fileSizeBytes)) / 512.0) * 22.0
            let formatBonus: Double = switch ext {
            case "pdf": 40.0
            case "md", "markdown": 32.0
            case "docx", "pptx", "key", "pages": 36.0
            default: 20.0
            }
            return QualityEvaluation(
                score: formatBonus + sizeScore + tieBreaker * 2.0,
                resolutionPixels: Int64(max(0, asset.pixelWidth)) * Int64(max(0, asset.pixelHeight)),
                formatLabel: formatLabel,
                isLosslessFormat: true,
                sharpnessScore: 0
            )

        case .model3D:
            let (formatLabel, formatBonus): (String, Double) = switch ext {
            case "blend": ("Blender 工程", 240.0)
            case "usdz", "usda", "usdc": ("USDZ 3D", 230.0)
            case "glb", "gltf": ("glTF / GLB", 225.0)
            case "fbx": ("FBX 3D", 220.0)
            case "obj": ("OBJ 网格", 190.0)
            case "stl": ("STL 网格", 180.0)
            default: (ext.isEmpty ? "3D 模型" : "\(ext.uppercased()) 3D", 170.0)
            }
            let sizeScore = log2(1.0 + Double(max(Int64(0), asset.fileSizeBytes)) / 4096.0) * 25.0
            return QualityEvaluation(
                score: formatBonus + sizeScore + tieBreaker,
                resolutionPixels: Int64(max(0, asset.pixelWidth)) * Int64(max(0, asset.pixelHeight)),
                formatLabel: formatLabel,
                isLosslessFormat: true,
                sharpnessScore: sharpnessDouble
            )
        }
    }

    private static func metadataTieBreaker(for asset: AssetRecord, isReferencedByBoard: Bool) -> Double {
        var score = 0.0
        if isReferencedByBoard { score += 3.0 }
        if asset.folderID != nil { score += 1.5 }
        if asset.rating > 0 { score += Double(min(5, asset.rating)) * 0.3 }
        if !asset.tags.isEmpty { score += min(1.2, Double(asset.tags.count) * 0.25) }
        if !asset.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { score += 0.4 }
        if asset.sourceURL != nil { score += 0.3 }
        if asset.richMetadata?.photoExif?.hasMeaningfulCameraExif == true { score += 0.4 }
        if asset.richMetadata?.aiGeneration?.isEmpty == false { score += 0.4 }
        if asset.pinnedOffline { score += 0.4 }
        return score
    }

    // MARK: - Full Multi-Media Clustering Pipeline

    public struct IndexedMediaAsset: Sendable {
        public let asset: AssetRecord
        public let fingerprint: ClassicalImageFingerprint?
        public let canonicalBookmarkKey: String?
        public let normalizedTextHash: String?

        public init(
            asset: AssetRecord,
            fingerprint: ClassicalImageFingerprint? = nil,
            canonicalBookmarkKey: String? = nil,
            normalizedTextHash: String? = nil
        ) {
            self.asset = asset
            self.fingerprint = fingerprint
            self.canonicalBookmarkKey = canonicalBookmarkKey
            self.normalizedTextHash = normalizedTextHash
        }
    }

    /// Groups exact SHA-256 duplicates AND classical perceptual/canonical duplicates across all 8 media kinds,
    /// always selecting the highest quality version in each group.
    public static func clusterDuplicates(
        items: [IndexedMediaAsset],
        sensitivity: DeduplicationSensitivity,
        boardReferencedAssetIDs: Set<UUID>
    ) -> [DuplicateGroup] {
        guard items.count >= 2 else { return [] }

        let byBucket = Dictionary(grouping: items) { MediaComparisonBucket.bucket(for: $0.asset.mediaKind) }
        var allGroups: [DuplicateGroup] = []

        for (bucket, bucketItems) in byBucket where bucketItems.count >= 2 {
            let bucketGroups = clusterWithinBucket(
                bucket: bucket,
                items: bucketItems,
                sensitivity: sensitivity,
                boardReferencedAssetIDs: boardReferencedAssetIDs
            )
            allGroups.append(contentsOf: bucketGroups)
        }

        allGroups.sort { lhs, rhs in
            if lhs.matchKind != rhs.matchKind {
                return lhs.matchKind == .exactBinary
            }
            if lhs.reclaimableBytes != rhs.reclaimableBytes {
                return lhs.reclaimableBytes > rhs.reclaimableBytes
            }
            return lhs.candidates.count > rhs.candidates.count
        }
        return allGroups
    }

    private static func clusterWithinBucket(
        bucket: MediaComparisonBucket,
        items: [IndexedMediaAsset],
        sensitivity: DeduplicationSensitivity,
        boardReferencedAssetIDs: Set<UUID>
    ) -> [DuplicateGroup] {
        // 1. Pre-group exact SHA-256 binary matches within this bucket
        var exactGroupsByHash: [String: [Int]] = [:]
        for (idx, item) in items.enumerated() {
            let hash = item.asset.contentHash.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hash.isEmpty {
                exactGroupsByHash[hash, default: []].append(idx)
            }
        }

        var repIndices: [Int] = []
        var repToMembers: [Int: [Int]] = [:]
        var handledHashes = Set<String>()

        for (idx, item) in items.enumerated() {
            let hash = item.asset.contentHash.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hash.isEmpty, let group = exactGroupsByHash[hash], group.count >= 2 {
                guard handledHashes.insert(hash).inserted else { continue }
                let rep = group.first(where: { items[$0].fingerprint != nil }) ?? group[0]
                repIndices.append(rep)
                repToMembers[rep] = group
            } else {
                repIndices.append(idx)
                repToMembers[idx] = [idx]
            }
        }

        // 2. Bucket-specific classical matching across representatives
        var verifiedEdges: [(a: Int, b: Int, similarity: Double, kind: DuplicateMatchKind)] = []

        switch bucket {
        case .webBookmark:
            var byLinkKey: [String: [Int]] = [:]
            for (repPos, itemIdx) in repIndices.enumerated() {
                if let key = items[itemIdx].canonicalBookmarkKey ?? canonicalBookmarkKey(for: items[itemIdx].asset) {
                    byLinkKey[key, default: []].append(repPos)
                }
            }
            for positions in byLinkKey.values where positions.count >= 2 {
                for i in 1..<positions.count {
                    verifiedEdges.append((positions[0], positions[i], 1.0, .canonicalLink))
                }
            }

        case .document:
            var byTextHash: [String: [Int]] = [:]
            for (repPos, itemIdx) in repIndices.enumerated() {
                if let th = items[itemIdx].normalizedTextHash, !th.isEmpty {
                    byTextHash[th, default: []].append(repPos)
                }
            }
            for positions in byTextHash.values where positions.count >= 2 {
                for i in 1..<positions.count {
                    verifiedEdges.append((positions[0], positions[i], 1.0, .normalizedText))
                }
            }

        case .audio:
            // Compare audio tracks via duration + normalized waveform envelope ZNCC
            let audioReps = repIndices.enumerated().filter { items[$0.element].asset.waveformPeaks.count >= 12 }
            for i in 0..<audioReps.count {
                let (posA, idxA) = audioReps[i]
                let a = items[idxA].asset
                for j in (i + 1)..<audioReps.count {
                    let (posB, idxB) = audioReps[j]
                    let b = items[idxB].asset
                    if let sim = audioWaveformSimilarity(
                        durationA: a.durationSeconds,
                        peaksA: a.waveformPeaks,
                        durationB: b.durationSeconds,
                        peaksB: b.waveformPeaks,
                        sensitivity: sensitivity
                    ) {
                        verifiedEdges.append((posA, posB, sim, .audioWaveform))
                    }
                }
            }

        case .rasterVisual, .video, .designFile, .model3D:
            let effectiveSensitivity: DeduplicationSensitivity =
                (bucket == .designFile || bucket == .model3D) && sensitivity == .relaxed ? .balanced : sensitivity
            let th = effectiveSensitivity.thresholds
            let maxP = max(th.maxPHashHamming, th.altTightPHash)
            let maxD = max(th.maxDHashHamming, th.altLooseDHash)

            let fpReps: [(repPos: Int, itemIdx: Int, fp: ClassicalImageFingerprint)] = repIndices.enumerated().compactMap { pos, itemIdx in
                guard let fp = items[itemIdx].fingerprint else { return nil }
                return (pos, itemIdx, fp)
            }

            func checkVisualPair(_ left: (repPos: Int, itemIdx: Int, fp: ClassicalImageFingerprint),
                                 _ right: (repPos: Int, itemIdx: Int, fp: ClassicalImageFingerprint)) {
                if bucket == .video {
                    if let dA = items[left.itemIdx].asset.durationSeconds,
                       let dB = items[right.itemIdx].asset.durationSeconds,
                       dA > 0.2, dB > 0.2 {
                        let maxDiff = max(th.videoDurationAbsSeconds, min(dA, dB) * th.videoDurationRelRatio)
                        guard abs(dA - dB) <= maxDiff else { return }
                    }
                }
                if let sim = visualSimilarity(between: left.fp, and: right.fp, sensitivity: effectiveSensitivity) {
                    verifiedEdges.append((left.repPos, right.repPos, sim, .nearIdentical))
                }
            }

            if fpReps.count <= 4_000 {
                for i in 0..<fpReps.count {
                    let left = fpReps[i]
                    for j in (i + 1)..<fpReps.count {
                        let right = fpReps[j]
                        if left.fp.lumaStdDev >= 3.5 && right.fp.lumaStdDev >= 3.5 {
                            if (left.fp.pHash ^ right.fp.pHash).nonzeroBitCount > maxP { continue }
                            if (left.fp.dHash ^ right.fp.dHash).nonzeroBitCount > maxD { continue }
                        }
                        checkVisualPair(left, right)
                    }
                }
            } else {
                var pBuckets: [[UInt16: [Int]]] = Array(repeating: [:], count: 4)
                var dBuckets: [[UInt16: [Int]]] = Array(repeating: [:], count: 4)
                var flatIndices: [Int] = []

                for (pos, entry) in fpReps.enumerated() {
                    if entry.fp.lumaStdDev < 3.5 { flatIndices.append(pos) }
                    for band in 0..<4 {
                        let pSlice = UInt16((entry.fp.pHash >> UInt64(band * 16)) & 0xFFFF)
                        let dSlice = UInt16((entry.fp.dHash >> UInt64(band * 16)) & 0xFFFF)
                        pBuckets[band][pSlice, default: []].append(pos)
                        dBuckets[band][dSlice, default: []].append(pos)
                    }
                }

                var checkedPairs = Set<UInt64>()
                func checkIndexPair(_ i: Int, _ j: Int) {
                    let lo = min(i, j)
                    let hi = max(i, j)
                    guard lo != hi else { return }
                    let pairKey = (UInt64(lo) << 32) | UInt64(hi)
                    guard checkedPairs.insert(pairKey).inserted else { return }
                    checkVisualPair(fpReps[lo], fpReps[hi])
                }

                for band in 0..<4 {
                    for bucketList in pBuckets[band].values where bucketList.count >= 2 && bucketList.count <= 256 {
                        for a in 0..<bucketList.count {
                            for b in (a + 1)..<bucketList.count { checkIndexPair(bucketList[a], bucketList[b]) }
                        }
                    }
                    for bucketList in dBuckets[band].values where bucketList.count >= 2 && bucketList.count <= 256 {
                        for a in 0..<bucketList.count {
                            for b in (a + 1)..<bucketList.count { checkIndexPair(bucketList[a], bucketList[b]) }
                        }
                    }
                }
                if flatIndices.count >= 2 && flatIndices.count <= 512 {
                    for a in 0..<flatIndices.count {
                        for b in (a + 1)..<flatIndices.count { checkIndexPair(flatIndices[a], flatIndices[b]) }
                    }
                }
            }
        }

        // 3. Anti-chaining clustering
        verifiedEdges.sort { $0.similarity > $1.similarity }
        var parent = Array(0..<repIndices.count)
        var clusterMembers: [[Int]] = (0..<repIndices.count).map { [$0] }
        var clusterNonExactKind: [Int: DuplicateMatchKind] = [:]

        func find(_ x: Int) -> Int {
            var cur = x
            while parent[cur] != cur {
                parent[cur] = parent[parent[cur]]
                cur = parent[cur]
            }
            return cur
        }

        for edge in verifiedEdges {
            let ra = find(edge.a)
            let rb = find(edge.b)
            guard ra != rb else { continue }

            if edge.kind == .nearIdentical,
               let fpA = items[repIndices[ra]].fingerprint,
               let fpB = items[repIndices[rb]].fingerprint,
               visualSimilarity(between: fpA, and: fpB, sensitivity: sensitivity) == nil {
                continue
            }

            let keepRoot = clusterMembers[ra].count >= clusterMembers[rb].count ? ra : rb
            let mergeRoot = keepRoot == ra ? rb : ra
            parent[mergeRoot] = keepRoot
            clusterMembers[keepRoot].append(contentsOf: clusterMembers[mergeRoot])
            clusterMembers[mergeRoot].removeAll()
            clusterNonExactKind[keepRoot] = edge.kind
        }

        // 4. Materialize DuplicateGroup objects with quality scoring
        var groups: [DuplicateGroup] = []
        var visitedRoots = Set<Int>()

        for repPos in 0..<repIndices.count {
            let root = find(repPos)
            guard visitedRoots.insert(root).inserted else { continue }
            let repPositions = clusterMembers[root]
            var memberItemIndices: [Int] = []
            for rp in repPositions {
                memberItemIndices.append(contentsOf: repToMembers[repIndices[rp]] ?? [repIndices[rp]])
            }
            guard memberItemIndices.count >= 2 else { continue }

            let uniqueHashes = Set(memberItemIndices.map { items[$0].asset.contentHash }.filter { !$0.isEmpty })
            let isAllExactBinary = uniqueHashes.count == 1 && memberItemIndices.allSatisfy { !items[$0].asset.contentHash.isEmpty }
            let matchKind: DuplicateMatchKind = isAllExactBinary ? .exactBinary : (clusterNonExactKind[root] ?? .nearIdentical)

            struct ScoredEntry {
                let itemIdx: Int
                let eval: QualityEvaluation
                let isBoardRef: Bool
            }

            let scored: [ScoredEntry] = memberItemIndices.map { idx in
                let item = items[idx]
                let boardRef = boardReferencedAssetIDs.contains(item.asset.id)
                let eval = evaluateQuality(
                    for: item.asset,
                    sharpness: item.fingerprint?.sharpness ?? 0,
                    isReferencedByBoard: boardRef
                )
                return ScoredEntry(itemIdx: idx, eval: eval, isBoardRef: boardRef)
            }.sorted { lhs, rhs in
                if abs(lhs.eval.score - rhs.eval.score) > 0.001 {
                    return lhs.eval.score > rhs.eval.score
                }
                let la = items[lhs.itemIdx].asset
                let ra = items[rhs.itemIdx].asset
                if la.createdAt != ra.createdAt {
                    return la.createdAt < ra.createdAt
                }
                return la.id.uuidString < ra.id.uuidString
            }

            guard let winner = scored.first else { continue }
            let winnerItem = items[winner.itemIdx]
            let runnerUp = scored.count > 1 ? scored[1] : nil

            var groupMinSim = 1.0
            var builtCandidates: [DuplicateAssetCandidate] = []
            builtCandidates.reserveCapacity(scored.count)

            for (rank, entry) in scored.enumerated() {
                let item = items[entry.itemIdx]
                let isKeeper = rank == 0
                let simToKeeper: Double = {
                    if isKeeper || isAllExactBinary || matchKind == .canonicalLink || matchKind == .normalizedText {
                        return 1.0
                    }
                    if !item.asset.contentHash.isEmpty && item.asset.contentHash == winnerItem.asset.contentHash {
                        return 1.0
                    }
                    if matchKind == .audioWaveform {
                        return audioWaveformSimilarity(
                            durationA: winnerItem.asset.durationSeconds,
                            peaksA: winnerItem.asset.waveformPeaks,
                            durationB: item.asset.durationSeconds,
                            peaksB: item.asset.waveformPeaks,
                            sensitivity: sensitivity
                        ) ?? 0.96
                    }
                    if let wFP = winnerItem.fingerprint, let cFP = item.fingerprint {
                        return visualSimilarity(between: wFP, and: cFP, sensitivity: sensitivity)
                            ?? visualSimilarity(between: wFP, and: cFP, sensitivity: .relaxed)
                            ?? 0.94
                    }
                    return 0.95
                }()
                if !isKeeper {
                    groupMinSim = min(groupMinSim, simToKeeper)
                }

                let reasons = buildReasons(
                    entry: entry.eval,
                    asset: item.asset,
                    isKeeper: isKeeper,
                    isBoardRef: entry.isBoardRef,
                    comparedTo: isKeeper ? runnerUp?.eval : winner.eval,
                    comparedAsset: isKeeper ? runnerUp.map { items[$0.itemIdx].asset } : winnerItem.asset,
                    matchKind: matchKind
                )

                builtCandidates.append(
                    DuplicateAssetCandidate(
                        asset: item.asset,
                        qualityScore: entry.eval.score,
                        resolutionPixels: entry.eval.resolutionPixels,
                        formatLabel: entry.eval.formatLabel,
                        isLosslessFormat: entry.eval.isLosslessFormat,
                        sharpnessScore: entry.eval.sharpnessScore,
                        isRecommendedKeep: isKeeper,
                        isReferencedByBoard: entry.isBoardRef,
                        similarityToKeeper: simToKeeper,
                        qualityReasons: reasons
                    )
                )
            }

            groups.append(
                DuplicateGroup(
                    primaryMediaKind: winnerItem.asset.mediaKind,
                    matchKind: matchKind,
                    similarityScore: isAllExactBinary ? 1.0 : groupMinSim,
                    recommendedKeepAssetID: winnerItem.asset.id,
                    candidates: builtCandidates
                )
            )
        }

        return groups
    }

    private static func buildReasons(
        entry: QualityEvaluation,
        asset: AssetRecord,
        isKeeper: Bool,
        isBoardRef: Bool,
        comparedTo other: QualityEvaluation?,
        comparedAsset: AssetRecord?,
        matchKind: DuplicateMatchKind
    ) -> [String] {
        var reasons: [String] = []
        if isKeeper {
            switch matchKind {
            case .exactBinary:
                if isBoardRef { reasons.append("情绪板引用中") }
                if asset.folderID != nil && comparedAsset?.folderID == nil { reasons.append("已整理至文件夹") }
                if !asset.tags.isEmpty || asset.rating > 0 { reasons.append("含标签或评分") }
                if reasons.isEmpty { reasons.append("最早导入原件") }

            case .canonicalLink:
                if asset.richMetadata?.socialPost?.mediaFetchFailed == false
                    && comparedAsset?.richMetadata?.socialPost?.mediaFetchFailed == true {
                    reasons.append("媒体加载完整")
                }
                let myAtts = asset.richMetadata?.socialPost?.effectiveAttachments.count ?? 0
                let otherAtts = comparedAsset?.richMetadata?.socialPost?.effectiveAttachments.count ?? 0
                if myAtts > otherAtts {
                    reasons.append("附件更完整（\(myAtts) 项）")
                }
                if isBoardRef { reasons.append("情绪板引用中") }
                if reasons.isEmpty { reasons.append("内容更完整") }

            case .normalizedText:
                if asset.fileSizeBytes > (comparedAsset?.fileSizeBytes ?? 0) {
                    reasons.append("原件更完整")
                }
                if !asset.tags.isEmpty || asset.rating > 0 { reasons.append("含标签或评分") }
                if reasons.isEmpty { reasons.append("推荐保留原件") }

            case .audioWaveform:
                if entry.isLosslessFormat && other?.isLosslessFormat != true {
                    reasons.append("无损音质（\(entry.formatLabel)）")
                } else if asset.fileSizeBytes > Int64(Double(comparedAsset?.fileSizeBytes ?? 0) * 1.15) {
                    reasons.append("比特率更高")
                }
                if isBoardRef { reasons.append("情绪板引用中") }
                if reasons.isEmpty { reasons.append("音质最优") }

            case .nearIdentical:
                if let other, let otherAsset = comparedAsset {
                    if asset.mediaKind == .animatedImage && otherAsset.mediaKind == .image {
                        reasons.append("保留完整动图")
                    }
                    if entry.resolutionPixels > Int64(Double(other.resolutionPixels) * 1.05) {
                        let ratio = Double(entry.resolutionPixels) / Double(max(Int64(1), other.resolutionPixels))
                        if ratio >= 1.5 {
                            reasons.append(String(format: "分辨率 %.1f×", ratio))
                        } else {
                            reasons.append("分辨率更高")
                        }
                    }
                    if entry.isLosslessFormat && !other.isLosslessFormat {
                        reasons.append("无损/源格式")
                    } else if asset.fileSizeBytes > Int64(Double(otherAsset.fileSizeBytes) * 1.2)
                        && entry.resolutionPixels >= Int64(Double(other.resolutionPixels) * 0.95) {
                        reasons.append(asset.mediaKind == .video ? "视频码率更高" : "压缩损失更少")
                    }
                    if entry.sharpnessScore > other.sharpnessScore + 3.0 {
                        reasons.append("细节更锐利")
                    }
                }
                if isBoardRef { reasons.append("情绪板引用中") }
                if reasons.isEmpty { reasons.append("综合画质最优") }
            }
        } else {
            switch matchKind {
            case .exactBinary:
                reasons.append("完全重复副本")
            case .canonicalLink:
                reasons.append("重复收藏链接")
            case .normalizedText:
                reasons.append("重复文本副本")
            case .audioWaveform:
                if !entry.isLosslessFormat && other?.isLosslessFormat == true {
                    reasons.append("有损压缩音质")
                } else {
                    reasons.append("较低码率音频副本")
                }
            case .nearIdentical:
                if let other {
                    if entry.resolutionPixels < Int64(Double(other.resolutionPixels) * 0.95) {
                        reasons.append("分辨率较低")
                    } else if !entry.isLosslessFormat && other.isLosslessFormat {
                        reasons.append("有损压缩版本")
                    } else if asset.fileSizeBytes < Int64(Double(comparedAsset?.fileSizeBytes ?? 0) * 0.85) {
                        reasons.append(asset.mediaKind == .video ? "较低码率视频" : "高压缩低码率")
                    } else {
                        reasons.append("较低画质副本")
                    }
                }
            }
            if isBoardRef {
                reasons.append("清理时自动迁移情绪板引用")
            }
        }
        return reasons
    }
}
