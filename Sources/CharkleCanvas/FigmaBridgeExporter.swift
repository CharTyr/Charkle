import AppKit
import CharkleCore
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import os
import SwiftUI
import UniformTypeIdentifiers

public nonisolated struct FigmaBridgeExportError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }

    public init(_ message: String) {
        self.message = message
    }
}

public nonisolated struct FigmaBridgeExportReport: Sendable {
    public let objectCount: Int
    public let imageCount: Int
    public let noteCount: Int
    public let groupCount: Int
    public let paletteCount: Int
    public let connectorCount: Int
    public let strokeCount: Int
    public let reviewCount: Int
    public let bundleURL: URL
}

/// Offline lossless Moodboard -> Figma / FigJam Bridge bundle exporter (`.charkleboard` ZIP).
///
/// Key guarantees:
/// - Independent editable layers for images, styled notes, group frames, vector palette strips,
///   connectors (native FigJam connectors / Figma vector arrows), and freehand ink strokes.
/// - Original pixel fidelity: >4096px images are split into lossless ≤4096×4096 PNG tiles with SHA-256 verification.
/// - Native GIF preservation: original GIF bytes archived in `originals/` for native `figma.createGif` in FigJam.
/// - Works identically for both Auto Editorial and Freeform moodboards; requires zero Figma API tokens.
public nonisolated enum FigmaBridgeExporter {
    public static func bundledPluginDirectoryURL() -> URL? {
        if let resURL = Bundle.main.resourceURL?.appending(path: "FigmaPlugin", directoryHint: .isDirectory),
           FileManager.default.fileExists(atPath: resURL.appending(path: "manifest.json").path) {
            return resURL
        }
        // Fallback for `swift run` / developer checkouts
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Resources/FigmaPlugin", directoryHint: .isDirectory),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Resources/FigmaPlugin", directoryHint: .isDirectory)
        ]
        for url in candidates {
            if FileManager.default.fileExists(atPath: url.appending(path: "manifest.json").path) {
                return url
            }
        }
        return nil
    }

    @concurrent
    public static func exportBundle(
        document: MoodboardDocument,
        assetsByID: [UUID: AssetRecord],
        containerWidth: Double = 1120,
        options: MoodboardExportOptions = MoodboardExportOptions(),
        resolveOriginalURL: @Sendable (UUID) async -> URL?,
        resolveThumbnailURL: @Sendable (UUID, ThumbnailTier) async -> URL?,
        to destinationURL: URL
    ) async throws -> FigmaBridgeExportReport {
        let resolvedFrames: [UUID: BoardRect]
        switch document.mode {
        case .autoEditorial(let cfg):
            resolvedFrames = EditorialLayoutSolver.solve(
                nodes: document.nodes,
                config: cfg,
                containerWidth: containerWidth,
                assetsByID: assetsByID
            ).frames
        case .freeform:
            resolvedFrames = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0.frame) })
        }

        let orderedNodes = document.nodes.sorted { lhs, rhs in
            let lGroup = if case .groupFrame = lhs.kind { true } else { false }
            let rGroup = if case .groupFrame = rhs.kind { true } else { false }
            if lGroup != rGroup { return lGroup }
            if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
            return lhs.editorialOrder < rhs.editorialOrder
        }

        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory.appending(path: "charkle-figma-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }
        try fm.createDirectory(at: stagingDir.appending(path: "tiles", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try fm.createDirectory(at: stagingDir.appending(path: "originals", directoryHint: .isDirectory), withIntermediateDirectories: true)

        var objects: [[String: Any]] = []
        var warnings: [[String: Any]] = []
        var originals: [[String: Any]] = []
        var archivedOriginals: [UUID: (file: String, sha256: String, isGIF: Bool)] = [:]
        var cachedTilePayloads: [String: [String: Any]] = [:]

        var imageCount = 0
        var noteCount = 0
        var groupCount = 0
        var paletteCount = 0

        // Optional top Board Palette Strip placed cleanly above content bounds
        if options.includePaletteStrip && !document.extractedPalette.isEmpty {
            let minX = resolvedFrames.values.map(\.minX).min() ?? 0
            let minY = resolvedFrames.values.map(\.minY).min() ?? 0
            let maxX = resolvedFrames.values.map(\.maxX).max() ?? 800
            let stripW = max(320, min(560, maxX - minX))
            let stripH = 54.0
            let swatches: [[String: Any]] = document.extractedPalette.prefix(7).map { swatch in
                let hex = swatch.hex.uppercased()
                return ["hex": hex, "isLight": Color.charkleIsLightHex(hex)]
            }
            objects.append([
                "id": "board-palette-header",
                "kind": "paletteStrip",
                "name": "板内色卡",
                "locked": false,
                "geometry": geometryJSON(
                    BoardRect(x: minX, y: minY - stripH - 24, width: stripW, height: stripH),
                    angle: 0,
                    flipX: false,
                    flipY: false
                ),
                "palette": ["swatches": swatches],
                "warnings": [String]()
            ])
            paletteCount += 1
        }

        for node in orderedNodes {
            guard let frame = resolvedFrames[node.id],
                  frame.x.isFinite, frame.y.isFinite,
                  frame.width.isFinite, frame.height.isFinite,
                  frame.width > 0, frame.height > 0 else { continue }
            let geom = geometryJSON(frame, angle: node.rotationDegrees, flipX: node.flipHorizontal, flipY: node.flipVertical)

            switch node.kind {
            case .assetRef(let assetID, let crop, _, _):
                let asset = assetsByID[assetID]
                let displayName = asset?.title ?? "素材"
                var itemWarnings: [String] = []

                let originalURL = await resolveOriginalURL(assetID)
                let fallbackPreviewURL: URL?
                if originalURL == nil {
                    if let p1400 = await resolveThumbnailURL(assetID, .preview1400) {
                        fallbackPreviewURL = p1400
                    } else {
                        fallbackPreviewURL = await resolveThumbnailURL(assetID, .grid520)
                    }
                } else {
                    fallbackPreviewURL = nil
                }

                guard let sourceURL = originalURL ?? fallbackPreviewURL else {
                    itemWarnings.append("素材原图与预览图均未缓存在本地，无法导入像素")
                    warnings.append(["id": node.id.uuidString, "name": displayName, "issues": itemWarnings])
                    objects.append([
                        "id": node.id.uuidString,
                        "kind": "unsupported",
                        "name": displayName,
                        "locked": node.isLocked,
                        "geometry": geom,
                        "warnings": itemWarnings
                    ])
                    continue
                }

                if originalURL == nil {
                    itemWarnings.append("原文件未缓存在本地，已使用高清预览图导出")
                }

                let fileData: Data
                do {
                    fileData = try Data(contentsOf: sourceURL)
                } catch {
                    itemWarnings.append("读取素材文件失败：\(error.localizedDescription)")
                    warnings.append(["id": node.id.uuidString, "name": displayName, "issues": itemWarnings])
                    objects.append([
                        "id": node.id.uuidString,
                        "kind": "unsupported",
                        "name": displayName,
                        "locked": node.isLocked,
                        "geometry": geom,
                        "warnings": itemWarnings
                    ])
                    continue
                }

                // Archive source file verbatim in `originals/` (never mislabel a fallback JPEG thumbnail with the original's .gif extension)
                let archivedInfo: (file: String, sha256: String, isGIF: Bool)
                if let existingArchive = archivedOriginals[assetID] {
                    archivedInfo = existingArchive
                } else {
                    let assetExt = ((asset?.fileName as NSString?)?.pathExtension ?? "").lowercased()
                    let urlExt = sourceURL.pathExtension.lowercased()
                    let rawExt: String
                    if originalURL == nil {
                        rawExt = urlExt.isEmpty ? "jpg" : urlExt
                    } else {
                        rawExt = assetExt.isEmpty ? urlExt : assetExt
                    }
                    let safeExt = rawExt.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
                    let fileName = assetID.uuidString + (safeExt.isEmpty ? "" : ".\(safeExt)")
                    let relPath = "originals/\(fileName)"
                    try fileData.write(to: stagingDir.appending(path: relPath), options: .atomic)
                    let digest = sha256Hex(fileData)
                    let isGIF = originalURL != nil && (safeExt == "gif" || asset?.mediaKind == .animatedImage)
                    originals.append([
                        "id": assetID.uuidString,
                        "name": asset?.fileName ?? fileName,
                        "file": relPath,
                        "sha256": digest,
                        "bytes": fileData.count
                    ])
                    archivedInfo = (relPath, digest, isGIF)
                    archivedOriginals[assetID] = archivedInfo
                }

                // Decode upright CGImage (from original, or fallback thumbnail for video/PDF/design docs)
                var decoded = decodeUprightCGImage(from: fileData)
                var isAnimatedGIF = archivedInfo.isGIF && (decoded?.frameCount ?? 0) > 1
                if decoded == nil {
                    var thumbURL = await resolveThumbnailURL(assetID, .preview1400)
                    if thumbURL == nil {
                        thumbURL = await resolveThumbnailURL(assetID, .grid520)
                    }
                    if let thumbURL, let thumbData = try? Data(contentsOf: thumbURL) {
                        decoded = decodeUprightCGImage(from: thumbData)
                        itemWarnings.append("非静态图片素材（\(asset?.mediaKind.localizedLabel ?? "附件")）已以静态预览导出，原始文件已归档在 originals/")
                        isAnimatedGIF = false
                    }
                }

                guard var cgImage = decoded?.image else {
                    itemWarnings.append("无法解码该素材的画面像素，原始文件已归档在 originals/")
                    warnings.append(["id": node.id.uuidString, "name": displayName, "issues": itemWarnings])
                    objects.append([
                        "id": node.id.uuidString,
                        "kind": "unsupported",
                        "name": displayName,
                        "locked": node.isLocked,
                        "geometry": geom,
                        "warnings": itemWarnings
                    ])
                    continue
                }

                // Apply normalized crop if present
                let cropKey: String
                if let crop, crop != .full, crop.width > 0.04, crop.height > 0.04 {
                    let safeCrop = crop.clamped()
                    let rx = max(0, min(Double(max(0, cgImage.width - 1)), safeCrop.x * Double(cgImage.width)))
                    let ry = max(0, min(Double(max(0, cgImage.height - 1)), safeCrop.y * Double(cgImage.height)))
                    let rw = max(1, min(Double(cgImage.width) - rx, safeCrop.width * Double(cgImage.width)))
                    let rh = max(1, min(Double(cgImage.height) - ry, safeCrop.height * Double(cgImage.height)))
                    if let cropped = cgImage.cropping(to: CGRect(x: rx, y: ry, width: rw, height: rh).integral) {
                        cgImage = cropped
                    }
                    cropKey = String(format: "%.4f-%.4f-%.4f-%.4f", safeCrop.x, safeCrop.y, safeCrop.width, safeCrop.height)
                } else {
                    cropKey = "full"
                }

                let tileCacheKey = "\(assetID.uuidString)-\(cropKey)"
                let imagePayload: [String: Any]
                if let cached = cachedTilePayloads[tileCacheKey] {
                    imagePayload = cached
                } else {
                    let cropHash = String(sha256Hex(Data(cropKey.utf8)).prefix(8))
                    let prefix = assetID.uuidString + (cropKey == "full" ? "" : "-C\(cropHash)")
                    let tiles = try writeLosslessTiles(for: cgImage, stagingDir: stagingDir, prefix: prefix)
                    var desc: [String: Any] = [
                        "pixelWidth": cgImage.width,
                        "pixelHeight": cgImage.height,
                        "tiles": tiles,
                        "animated": isAnimatedGIF
                    ]
                    if isAnimatedGIF && cropKey == "full" && archivedInfo.file.lowercased().hasSuffix(".gif") {
                        desc["animation"] = ["file": archivedInfo.file, "sha256": archivedInfo.sha256]
                        itemWarnings.append("动画 GIF 在 Figma Design 中以静态首帧导入，原始 GIF 已归档")
                    }
                    cachedTilePayloads[tileCacheKey] = desc
                    imagePayload = desc
                }

                if !itemWarnings.isEmpty {
                    warnings.append(["id": node.id.uuidString, "name": displayName, "issues": itemWarnings])
                }
                objects.append([
                    "id": node.id.uuidString,
                    "kind": "image",
                    "name": displayName,
                    "cornerRadius": 12,
                    "locked": node.isLocked,
                    "geometry": geom,
                    "image": imagePayload,
                    "warnings": itemWarnings
                ])
                imageCount += 1

            case .note(let title, let text, let style, let fontSize):
                let hex = noteStyleHex(style)
                let noteName: String = if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    title
                } else {
                    String(text.prefix(24))
                }
                objects.append([
                    "id": node.id.uuidString,
                    "kind": "note",
                    "name": noteName.isEmpty ? "灵感便签" : noteName,
                    "locked": node.isLocked,
                    "geometry": geom,
                    "note": [
                        "title": title ?? "",
                        "text": text,
                        "style": style.rawValue,
                        "fontSize": finiteDouble(fontSize, fallback: 14),
                        "backgroundHex": hex.background,
                        "foregroundHex": hex.foreground,
                        "borderHex": hex.border
                    ],
                    "warnings": [String]()
                ])
                noteCount += 1

            case .groupFrame(let title, let tint):
                objects.append([
                    "id": node.id.uuidString,
                    "kind": "groupFrame",
                    "name": title.isEmpty ? "分组区域" : title,
                    "locked": node.isLocked,
                    "geometry": geom,
                    "group": [
                        "title": title,
                        "tint": tint.rawValue,
                        "accentHex": groupTintHex(tint)
                    ],
                    "warnings": [String]()
                ])
                groupCount += 1

            case .paletteStrip(let colors, let autoSync):
                let activeColors = (autoSync && !document.extractedPalette.isEmpty) ? document.extractedPalette : colors
                let swatches: [[String: Any]] = (activeColors.isEmpty ? [LabColor.fromHex("#8B95A1")] : activeColors).map { swatch in
                    let hex = swatch.hex.uppercased()
                    return ["hex": hex, "isLight": Color.charkleIsLightHex(hex)]
                }
                objects.append([
                    "id": node.id.uuidString,
                    "kind": "paletteStrip",
                    "name": "色卡条",
                    "locked": node.isLocked,
                    "geometry": geom,
                    "palette": ["swatches": swatches],
                    "warnings": [String]()
                ])
                paletteCount += 1
            }
        }

        guard !objects.isEmpty else {
            throw FigmaBridgeExportError("当前情绪板里没有可导出的对象。")
        }

        var connectorJSONs: [[String: Any]] = []
        var strokeJSONs: [[String: Any]] = []
        if options.includeAnnotations {
            let exportedIDs = Set(objects.compactMap { $0["id"] as? String })
            for conn in document.connectors {
                let fromID = conn.fromNodeID.uuidString
                let toID = conn.toNodeID.uuidString
                guard exportedIDs.contains(fromID), exportedIDs.contains(toID) else { continue }
                var entry: [String: Any] = [
                    "id": conn.id.uuidString,
                    "fromNodeID": fromID,
                    "fromAnchor": conn.fromAnchor.rawValue,
                    "toNodeID": toID,
                    "toAnchor": conn.toAnchor.rawValue,
                    "style": conn.style.rawValue,
                    "colorHex": conn.colorHex,
                    "dashed": conn.dashed,
                    "label": conn.label ?? ""
                ]
                if let fp = conn.fromNormalizedPoint, fp.x.isFinite, fp.y.isFinite {
                    entry["fromNormalizedPoint"] = [
                        "x": max(0.0, min(1.0, fp.x)),
                        "y": max(0.0, min(1.0, fp.y))
                    ]
                }
                if let tp = conn.toNormalizedPoint, tp.x.isFinite, tp.y.isFinite {
                    entry["toNormalizedPoint"] = [
                        "x": max(0.0, min(1.0, tp.x)),
                        "y": max(0.0, min(1.0, tp.y))
                    ]
                }
                connectorJSONs.append(entry)
            }
            for stroke in document.inkStrokes where stroke.points.count >= 2 {
                let safePts: [[String: Double]] = stroke.points.compactMap { pt in
                    guard pt.x.isFinite, pt.y.isFinite else { return nil }
                    return ["x": pt.x, "y": pt.y]
                }
                guard safePts.count >= 2 else { continue }
                strokeJSONs.append([
                    "id": stroke.id.uuidString,
                    "points": safePts,
                    "colorHex": stroke.colorHex,
                    "lineWidth": max(0.5, finiteDouble(stroke.lineWidth, fallback: 3.0)),
                    "opacity": max(0.0, min(1.0, finiteDouble(stroke.opacity, fallback: 0.92)))
                ])
            }
        }

        let reportJSON: [String: Any] = [
            "objectCount": objects.count,
            "imageCount": imageCount,
            "noteCount": noteCount,
            "groupCount": groupCount,
            "paletteCount": paletteCount,
            "connectorCount": connectorJSONs.count,
            "strokeCount": strokeJSONs.count,
            "reviewCount": warnings.count,
            "warnings": warnings
        ]

        let boardJSON: [String: Any] = [
            "format": "charkle-figma-bridge",
            "version": 1,
            "boardId": document.id.uuidString,
            "name": document.title,
            "subtitle": document.subtitle,
            "mode": document.mode.isAutoEditorial ? "autoEditorial" : "freeform",
            "darkAppearance": options.darkAppearance,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "sourceOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "objects": objects,
            "connectors": connectorJSONs,
            "inkStrokes": strokeJSONs,
            "originals": originals,
            "report": reportJSON
        ]

        try writeJSON(boardJSON, to: stagingDir.appending(path: "board.json"))
        try writeJSON(reportJSON, to: stagingDir.appending(path: "migration-report.json"))

        // Zip cleanly via macOS `/usr/bin/ditto -c -k --norsrc --noextattr` and move atomically to destination
        let destParent = destinationURL.deletingLastPathComponent()
        try fm.createDirectory(at: destParent, withIntermediateDirectories: true)
        let stagingZip = destParent.appending(path: ".\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: stagingZip) }

        try await runDittoZip(sourceDirectory: stagingDir, destinationZip: stagingZip)

        if fm.fileExists(atPath: destinationURL.path) {
            _ = try fm.replaceItemAt(destinationURL, withItemAt: stagingZip)
        } else {
            try fm.moveItem(at: stagingZip, to: destinationURL)
        }

        return FigmaBridgeExportReport(
            objectCount: objects.count,
            imageCount: imageCount,
            noteCount: noteCount,
            groupCount: groupCount,
            paletteCount: paletteCount,
            connectorCount: connectorJSONs.count,
            strokeCount: strokeJSONs.count,
            reviewCount: warnings.count,
            bundleURL: destinationURL
        )
    }

    // MARK: - Helpers

    private static func finiteDouble(_ value: Double, fallback: Double = 0) -> Double {
        value.isFinite ? value : fallback
    }

    private static func geometryJSON(_ rect: BoardRect, angle: Double, flipX: Bool, flipY: Bool) -> [String: Any] {
        [
            "x": finiteDouble(rect.x, fallback: 0),
            "y": finiteDouble(rect.y, fallback: 0),
            "width": max(1, finiteDouble(rect.width, fallback: 240)),
            "height": max(1, finiteDouble(rect.height, fallback: 180)),
            "angle": finiteDouble(angle, fallback: 0),
            "flipX": flipX,
            "flipY": flipY
        ]
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeJSON(_ object: Any, to url: URL) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw FigmaBridgeExportError("导出数据结构包含无效数值，无法序列化为 JSON。")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func decodeUprightCGImage(from data: Data) -> (image: CGImage, frameCount: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let raw = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            return nil
        }
        let frameCount = CGImageSourceGetCount(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        if orientation != 1 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(raw.width, raw.height)
            ]
            if let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return (upright, frameCount)
            }
        }
        return (raw, frameCount)
    }

    private static func writeLosslessTiles(for image: CGImage, stagingDir: URL, prefix: String) throws -> [[String: Any]] {
        var tiles: [[String: Any]] = []
        let tileLimit = 4096
        for y in stride(from: 0, to: image.height, by: tileLimit) {
            for x in stride(from: 0, to: image.width, by: tileLimit) {
                let w = min(tileLimit, image.width - x)
                let h = min(tileLimit, image.height - y)
                guard let crop = image.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else {
                    throw FigmaBridgeExportError("大图无损分块失败。")
                }
                let relPath = "tiles/\(prefix)-\(x)-\(y).png"
                let fileURL = stagingDir.appending(path: relPath)
                let mutableData = NSMutableData()
                guard let dest = CGImageDestinationCreateWithData(mutableData as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
                    throw FigmaBridgeExportError("无法编码 PNG 分块数据。")
                }
                CGImageDestinationAddImage(dest, crop, nil)
                guard CGImageDestinationFinalize(dest) else {
                    throw FigmaBridgeExportError("保存 PNG 分块失败。")
                }
                let pngBytes = mutableData as Data
                try pngBytes.write(to: fileURL, options: .atomic)
                tiles.append([
                    "file": relPath,
                    "x": x,
                    "y": y,
                    "width": w,
                    "height": h,
                    "sha256": sha256Hex(pngBytes)
                ])
            }
        }
        return tiles
    }

    private nonisolated final class LockedProcessBox: @unchecked Sendable {
        let process: Process
        private struct State {
            var resumed = false
            var cancelled = false
        }
        private let state = OSAllocatedUnfairLock(initialState: State())

        init(_ process: Process) {
            self.process = process
        }

        func tryClaimResume() -> Bool {
            state.withLock { s in
                if s.resumed { return false }
                s.resumed = true
                return true
            }
        }

        var isCancelled: Bool {
            state.withLock { $0.cancelled }
        }

        func markCancelledAndTerminateIfRunning() {
            state.withLock { $0.cancelled = true }
            if process.isRunning {
                process.terminate()
            }
        }
    }

    @concurrent
    private static func runDittoZip(sourceDirectory: URL, destinationZip: URL) async throws {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", sourceDirectory.path, destinationZip.path]

        let box = LockedProcessBox(process)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.process.terminationHandler = { proc in
                    guard box.tryClaimResume() else { return }
                    if box.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if proc.terminationStatus == 0 {
                        continuation.resume(returning: ())
                    } else {
                        continuation.resume(throwing: FigmaBridgeExportError("打包 .charkleboard 文件失败（退出码 \(proc.terminationStatus)）。"))
                    }
                }
                if box.isCancelled {
                    if box.tryClaimResume() {
                        continuation.resume(throwing: CancellationError())
                    }
                    return
                }
                do {
                    try box.process.run()
                } catch {
                    if box.tryClaimResume() {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            box.markCancelledAndTerminateIfRunning()
        }
    }

    private static func noteStyleHex(_ style: NoteStyle) -> (background: String, foreground: String, border: String) {
        switch style {
        case .paper: ("#FFFFFF", "#1D1F23", "#D9DBDE")
        case .ink: ("#1D1F24", "#F1F2F4", "#3A3D45")
        case .warm: ("#F7F0E4", "#392F22", "#C9B79C")
        case .sage: ("#E8F0EA", "#203227", "#9AB5A3")
        case .slate: ("#E9EEF3", "#1F2B36", "#9EB0C2")
        }
    }

    private static func groupTintHex(_ tint: GroupTint) -> String {
        switch tint {
        case .neutral: "#7D838B"
        case .sand: "#B5956B"
        case .sage: "#6B8E76"
        case .slate: "#627A94"
        case .terracotta: "#BA6B55"
        case .ocean: "#4D7E97"
        }
    }
}
