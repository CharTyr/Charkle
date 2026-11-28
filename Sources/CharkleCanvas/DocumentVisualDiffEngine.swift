import AppKit
import CharkleCore
import CoreGraphics
import Foundation
import PDFKit

// MARK: - Compact Index View Layout & Micro-Folio Pure Geometry Metrics

public nonisolated enum CompactIndexLayoutMetrics {
    /// Responsive breakpoint below which 2-Column Tactile Index Grid collapses cleanly to 1 column.
    public static let twoColumnMinViewportWidth: CGFloat = 680

    public static func effectiveColumnCount(viewportWidth: CGFloat, preferredColumnMode: Int) -> Int {
        if viewportWidth < twoColumnMinViewportWidth {
            return 1
        }
        return preferredColumnMode == 1 ? 1 : 2
    }

    public struct MicroFolioLayerPose: Equatable, Sendable {
        public let offsetX: CGFloat
        public let offsetY: CGFloat
        public let rotationZDegrees: Double
        public let rotationYDegrees: Double

        public init(
            offsetX: CGFloat,
            offsetY: CGFloat,
            rotationZDegrees: Double,
            rotationYDegrees: Double
        ) {
            self.offsetX = offsetX
            self.offsetY = offsetY
            self.rotationZDegrees = rotationZDegrees
            self.rotationYDegrees = rotationYDegrees
        }
    }

    /// Computes pure composite transform poses (`[back, mid, front]`) for the 3D Micro-Folio stack artifact,
    /// honoring `reduceMotion` by suppressing 3D fan-out rotations while keeping static physical depth offsets.
    public static func microFolioLayerPoses(
        isHovered: Bool,
        reduceMotion: Bool
    ) -> (back: MicroFolioLayerPose, mid: MicroFolioLayerPose, front: MicroFolioLayerPose) {
        let activeHover = isHovered && !reduceMotion
        let back = MicroFolioLayerPose(
            offsetX: activeHover ? 8.0 : 4.0,
            offsetY: activeHover ? -3.5 : -3.0,
            rotationZDegrees: activeHover ? 8.0 : 3.0,
            rotationYDegrees: 0.0
        )
        let mid = MicroFolioLayerPose(
            offsetX: activeHover ? 4.0 : 2.0,
            offsetY: activeHover ? -2.0 : -1.5,
            rotationZDegrees: activeHover ? 4.0 : 1.5,
            rotationYDegrees: activeHover ? -14.0 : 0.0
        )
        let front = MicroFolioLayerPose(
            offsetX: activeHover ? -1.0 : 0.0,
            offsetY: 0.0,
            rotationZDegrees: 0.0,
            rotationYDegrees: activeHover ? -26.0 : 0.0
        )
        return (back, mid, front)
    }

    public enum MinimapBucketTone: Int, Equatable, Sendable {
        case unchanged = 0
        case addedOrModified = 1
        case highRisk = 2
    }

    /// Normalizes arbitrary `DocumentDiffSummary.minimapBuckets` into 12 deterministic visual segments.
    public static func normalizedMinimapTones(for summary: DocumentDiffSummary) -> [MinimapBucketTone] {
        DocumentDiffSummary.normalizeBuckets(summary.minimapBuckets).map {
            MinimapBucketTone(rawValue: min(2, max(0, $0))) ?? .unchanged
        }
    }
}

// MARK: - Quick Look High-Risk Radar Filter Engine

public nonisolated enum DocumentRiskRadarFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case numberOrCurrency
    case dateOrDeadline
    case tableMutation
    case nativeRevisionOrComment

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: "全部改动"
        case .numberOrCurrency: "数字与金额"
        case .dateOrDeadline: "日期与时限"
        case .tableMutation: "表格变动"
        case .nativeRevisionOrComment: "原生修订/批注"
        }
    }
}

public nonisolated enum DocumentRadarFilterEngine {
    public static func filterDiffHunks(
        _ hunks: [DocumentDiffHunk],
        radar: DocumentRiskRadarFilter,
        onlyChanged: Bool
    ) -> [DocumentDiffHunk] {
        hunks.filter { hunk in
            if onlyChanged && !hunk.changeKind.isChanged {
                return false
            }
            switch radar {
            case .all:
                return true
            case .numberOrCurrency:
                return hunk.riskFlags.contains(.numberOrCurrency)
            case .dateOrDeadline:
                return hunk.riskFlags.contains(.dateOrDeadline)
            case .tableMutation:
                return hunk.riskFlags.contains(.tableMutation)
                    || hunk.blockKind == .table
                    || !hunk.tableCellDiffs.isEmpty
            case .nativeRevisionOrComment:
                return hunk.riskFlags.contains(.nativeRevisionOrComment)
            }
        }
    }

    public static func radarBadgeCount(
        in report: DocumentComparisonReport,
        for filter: DocumentRiskRadarFilter
    ) -> Int {
        if !report.sheetDiffs.isEmpty && filter == .tableMutation {
            return report.sheetDiffs.reduce(0) {
                $0 + $1.addedRowCount + $1.removedRowCount + $1.modifiedRowCount
            }
        }
        if filter == .nativeRevisionOrComment {
            let hunkCount = filterDiffHunks(report.hunks, radar: .nativeRevisionOrComment, onlyChanged: true).count
            return hunkCount + report.commentDiffs.count
        }
        return filterDiffHunks(report.hunks, radar: filter, onlyChanged: true).count
    }

    public static func nextFocusedHunkID(
        in filteredHunks: [DocumentDiffHunk],
        currentFocusedID: String?,
        delta: Int
    ) -> String? {
        guard !filteredHunks.isEmpty else { return nil }
        let curIdx = currentFocusedID.flatMap { id in
            filteredHunks.firstIndex(where: { $0.id == id })
        } ?? (delta > 0 ? -1 : 0)
        let nextIdx = ((curIdx + delta) % filteredHunks.count + filteredHunks.count) % filteredHunks.count
        return filteredHunks[nextIdx].id
    }
}

// MARK: - Off-Main-Thread PDF Page Rasterizer & Red-Cyan Difference Compositor

public nonisolated enum PDFVisualDiffRenderer {
    public struct RenderedComparisonPages: @unchecked Sendable {
        public let pageCount: Int
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let baseImage: NSImage?
        public let targetImage: NSImage?
        public let redCyanComposite: NSImage?
        public let compositeRGBA: [UInt8]

        public init(
            pageCount: Int,
            pixelWidth: Int = 0,
            pixelHeight: Int = 0,
            baseImage: NSImage?,
            targetImage: NSImage?,
            redCyanComposite: NSImage?,
            compositeRGBA: [UInt8] = []
        ) {
            self.pageCount = pageCount
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.baseImage = baseImage
            self.targetImage = targetImage
            self.redCyanComposite = redCyanComposite
            self.compositeRGBA = compositeRGBA
        }
    }

    @concurrent
    public static func renderComparisonPages(
        baseURL: URL,
        targetURL: URL,
        pageIndex: Int,
        maxDimension: Int = 1100
    ) async -> RenderedComparisonPages {
        guard let baseDoc = PDFDocument(url: baseURL),
              let targetDoc = PDFDocument(url: targetURL) else {
            return RenderedComparisonPages(pageCount: 0, baseImage: nil, targetImage: nil, redCyanComposite: nil)
        }
        let totalPages = max(baseDoc.pageCount, targetDoc.pageCount)
        guard totalPages > 0 else {
            return RenderedComparisonPages(pageCount: 0, baseImage: nil, targetImage: nil, redCyanComposite: nil)
        }
        let clampedIdx = max(0, min(totalPages - 1, pageIndex))
        let basePage = clampedIdx < baseDoc.pageCount ? baseDoc.page(at: clampedIdx) : nil
        let targetPage = clampedIdx < targetDoc.pageCount ? targetDoc.page(at: clampedIdx) : nil

        let refBounds = (targetPage ?? basePage)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 595, height: 842)
        let scale = CGFloat(maxDimension) / max(1, max(refBounds.width, refBounds.height))
        let pxW = max(64, Int((refBounds.width * scale).rounded()))
        let pxH = max(64, Int((refBounds.height * scale).rounded()))

        let baseRGBA = rasterizePageRGBA(page: basePage, width: pxW, height: pxH)
        let targetRGBA = rasterizePageRGBA(page: targetPage, width: pxW, height: pxH)

        let baseImg = makeNSImage(fromRGBA: baseRGBA, width: pxW, height: pxH)
        let targetImg = makeNSImage(fromRGBA: targetRGBA, width: pxW, height: pxH)
        let compositeRGBA = makeRedCyanOverlayRGBA(baseRGBA: baseRGBA, targetRGBA: targetRGBA, pixelCount: pxW * pxH)
        let compositeImg = makeNSImage(fromRGBA: compositeRGBA, width: pxW, height: pxH)

        return RenderedComparisonPages(
            pageCount: totalPages,
            pixelWidth: pxW,
            pixelHeight: pxH,
            baseImage: baseImg,
            targetImage: targetImg,
            redCyanComposite: compositeImg,
            compositeRGBA: compositeRGBA
        )
    }

    public static func makeRedCyanOverlayRGBA(
        baseRGBA: [UInt8],
        targetRGBA: [UInt8],
        pixelCount: Int
    ) -> [UInt8] {
        guard baseRGBA.count >= pixelCount * 4, targetRGBA.count >= pixelCount * 4 else {
            return targetRGBA
        }
        var out = [UInt8](repeating: 255, count: pixelCount * 4)
        for i in 0..<pixelCount {
            let o = i * 4
            // Convert each page's pixel darkness (0 = white paper, 255 = solid ink/stamp)
            let baseLum = (Int(baseRGBA[o]) * 299 + Int(baseRGBA[o + 1]) * 587 + Int(baseRGBA[o + 2]) * 114) / 1000
            let targetLum = (Int(targetRGBA[o]) * 299 + Int(targetRGBA[o + 1]) * 587 + Int(targetRGBA[o + 2]) * 114) / 1000

            let baseInk = 255 - baseLum
            let targetInk = 255 - targetLum
            let diff = abs(baseInk - targetInk)

            if diff <= 18 {
                // Unchanged ink -> calm neutral grey on white paper
                let avgLum = UInt8(clamping: 255 - ((baseInk + targetInk) / 2) * 3 / 4)
                out[o] = avgLum
                out[o + 1] = avgLum
                out[o + 2] = avgLum
                out[o + 3] = 255
            } else if baseInk > targetInk {
                // Present in Base (removed / shifted from old) -> vivid Red highlight
                let strength = min(255, diff * 3 / 2)
                out[o] = 235
                out[o + 1] = UInt8(clamping: 245 - strength)
                out[o + 2] = UInt8(clamping: 245 - strength)
                out[o + 3] = 255
            } else {
                // Added in Target (new signature / stamp / annotation) -> crisp Studio Cyan-Blue highlight
                let strength = min(255, diff * 3 / 2)
                out[o] = UInt8(clamping: 245 - strength)
                out[o + 1] = UInt8(clamping: 250 - strength / 2)
                out[o + 2] = 242
                out[o + 3] = 255
            }
        }
        return out
    }

    private static func rasterizePageRGBA(page: PDFPage?, width: Int, height: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 255, count: width * height * 4)
        guard let page else { return buffer }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        buffer.withUnsafeMutableBytes { rawPtr in
            guard let baseAddr = rawPtr.baseAddress,
                  let ctx = CGContext(
                      data: baseAddr,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return }
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let mediaBox = page.bounds(for: .mediaBox)
            let sx = CGFloat(width) / max(1, mediaBox.width)
            let sy = CGFloat(height) / max(1, mediaBox.height)
            let s = min(sx, sy)
            ctx.saveGState()
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -mediaBox.minX, y: -mediaBox.minY)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }
        return buffer
    }

    private static func makeNSImage(fromRGBA rgba: [UInt8], width: Int, height: Int) -> NSImage? {
        guard rgba.count >= width * height * 4 else { return nil }
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data),
              let cg = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }
}
