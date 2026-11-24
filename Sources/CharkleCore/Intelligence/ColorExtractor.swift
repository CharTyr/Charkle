import CoreGraphics
import Foundation
import ImageIO

/// Extracts perceptual dominant colors from images using downsampled CIELAB k-means clustering.
public nonisolated enum ColorExtractor: Sendable {

    /// Extract up to `count` dominant colors sorted by perceptual visual weight,
    /// optionally restricted to a normalized top-left `crop` region (e.g. from TypeSafe `Box` or Vision saliency).
    public static func extractDominantColors(
        from image: CGImage,
        crop: NormalizedCropRect?,
        count: Int = 6
    ) -> [LabColor] {
        guard let crop, crop != .full, crop.width > 0.04, crop.height > 0.04 else {
            return extractDominantColors(from: image, count: count)
        }
        let clamped = crop.clamped()
        let pixelRect = CGRect(
            x: (clamped.x * Double(image.width)).rounded(.down),
            y: (clamped.y * Double(image.height)).rounded(.down),
            width: max(4, (clamped.width * Double(image.width)).rounded()),
            height: max(4, (clamped.height * Double(image.height)).rounded())
        ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixelRect.width >= 4, pixelRect.height >= 4, let cropped = image.cropping(to: pixelRect) else {
            return extractDominantColors(from: image, count: count)
        }
        return extractDominantColors(from: cropped, count: count)
    }

    /// Extract up to `count` dominant colors sorted by perceptual visual weight.
    public static func extractDominantColors(from image: CGImage, count: Int = 6) -> [LabColor] {
        let targetSide = 48
        guard let pixels = sampleRGBPixels(from: image, maxSide: targetSide), !pixels.isEmpty else {
            return []
        }

        guard count > 0 else { return [] }
        let k = min(count, 8, pixels.count)
        // K-means++ style deterministic seeding for reproducible results across runs
        var centroids: [(l: Double, a: Double, b: Double)] = []
        centroids.reserveCapacity(k)

        let labPixels: [(l: Double, a: Double, b: Double)] = pixels.map {
            LabColor.sRGBToLab(r: $0.r, g: $0.g, b: $0.b)
        }
        let pixelCount = labPixels.count
        var minDists = Array(repeating: Double.greatestFiniteMagnitude, count: pixelCount)
        var newest = labPixels[pixelCount / 2]
        centroids.append(newest)

        while centroids.count < k {
            var farthestIndex = 0
            var maxMinDist = -1.0
            for idx in 0..<pixelCount {
                let p = labPixels[idx]
                let dl = p.l - newest.l
                let da = p.a - newest.a
                let db = p.b - newest.b
                let d = dl * dl + da * da + db * db
                if d < minDists[idx] { minDists[idx] = d }
                if minDists[idx] > maxMinDist {
                    maxMinDist = minDists[idx]
                    farthestIndex = idx
                }
            }
            if maxMinDist <= 1.0 { break }
            newest = labPixels[farthestIndex]
            centroids.append(newest)
        }

        let clusterCount = centroids.count
        var assignments = Array(repeating: 0, count: pixelCount)
        var sumL = Array(repeating: 0.0, count: clusterCount)
        var sumA = Array(repeating: 0.0, count: clusterCount)
        var sumB = Array(repeating: 0.0, count: clusterCount)
        var counts = Array(repeating: 0, count: clusterCount)

        if clusterCount > 1 {
            for iteration in 0..<8 {
                for cIdx in 0..<clusterCount {
                    sumL[cIdx] = 0.0
                    sumA[cIdx] = 0.0
                    sumB[cIdx] = 0.0
                    counts[cIdx] = 0
                }

                var changed = false
                for i in 0..<pixelCount {
                    let p = labPixels[i]
                    var bestIdx = 0
                    var bestDist = Double.greatestFiniteMagnitude
                    for cIdx in 0..<clusterCount {
                        let c = centroids[cIdx]
                        let dl = p.l - c.l
                        let da = p.a - c.a
                        let db = p.b - c.b
                        let dist = dl * dl + da * da + db * db
                        if dist < bestDist {
                            bestDist = dist
                            bestIdx = cIdx
                        }
                    }
                    if iteration == 0 || assignments[i] != bestIdx {
                        assignments[i] = bestIdx
                        changed = true
                    }
                    sumL[bestIdx] += p.l
                    sumA[bestIdx] += p.a
                    sumB[bestIdx] += p.b
                    counts[bestIdx] += 1
                }

                if !changed { break }

                for cIdx in 0..<clusterCount where counts[cIdx] > 0 {
                    let n = Double(counts[cIdx])
                    centroids[cIdx] = (sumL[cIdx] / n, sumA[cIdx] / n, sumB[cIdx] / n)
                }
            }
        }

        // Reuse accumulator buffers to compute representative average sRGB per cluster
        for cIdx in 0..<clusterCount {
            sumL[cIdx] = 0.0
            sumA[cIdx] = 0.0
            sumB[cIdx] = 0.0
            counts[cIdx] = 0
        }

        for i in pixels.indices {
            let cIdx = assignments[i]
            let rgb = pixels[i]
            sumL[cIdx] += rgb.r
            sumA[cIdx] += rgb.g
            sumB[cIdx] += rgb.b
            counts[cIdx] += 1
        }

        let total = Double(pixels.count)
        var rawSwatches: [LabColor] = []
        rawSwatches.reserveCapacity(clusterCount)
        for cIdx in 0..<clusterCount where counts[cIdx] > 0 {
            let n = Double(counts[cIdx])
            let rByte = UInt8(max(0, min(255, Int((sumL[cIdx] / n * 255.0).rounded()))))
            let gByte = UInt8(max(0, min(255, Int((sumA[cIdx] / n * 255.0).rounded()))))
            let bByte = UInt8(max(0, min(255, Int((sumB[cIdx] / n * 255.0).rounded()))))
            let hex = Self.formatHex(r: rByte, g: gByte, b: bByte)
            let swatch = LabColor.fromHex(hex, proportion: n / total)
            rawSwatches.append(swatch)
        }

        // Deduplicate near-identical swatches (deltaE < 8)
        let sorted = rawSwatches.sorted { $0.proportion > $1.proportion }
        var merged: [LabColor] = []
        for swatch in sorted {
            if !merged.contains(where: { $0.deltaESquared(to: swatch) < 64.0 }) {
                merged.append(swatch)
            }
        }
        return Array(merged.prefix(count))
    }

    private static let hexDigits: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
        0x38, 0x39, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46
    )

    private static func hexNibble(_ v: UInt8) -> UInt8 {
        withUnsafeBytes(of: hexDigits) { $0[Int(v & 0x0F)] }
    }

    private static func formatHex(r: UInt8, g: UInt8, b: UInt8) -> String {
        let bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
            0x23,
            hexNibble(r >> 4), hexNibble(r),
            hexNibble(g >> 4), hexNibble(g),
            hexNibble(b >> 4), hexNibble(b)
        )
        return withUnsafeBytes(of: bytes) { String(decoding: $0, as: UTF8.self) }
    }

    public static func extractDominantColors(from url: URL, count: Int = 6) -> [LabColor] {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return [] }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 96,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return []
            }
            return extractDominantColors(from: cgImage, count: count)
        }
    }

    private static func sampleRGBPixels(from image: CGImage, maxSide: Int) -> [(r: Double, g: Double, b: Double)]? {
        autoreleasepool {
            let origW = image.width
            let origH = image.height
            guard origW > 0, origH > 0 else { return nil }

            let scale = min(1.0, Double(maxSide) / Double(max(origW, origH)))
            let width = max(1, Int((Double(origW) * scale).rounded()))
            let height = max(1, Int((Double(origH) * scale).rounded()))

            let bytesPerPixel = 4
            guard let context = MediaArtwork.context(width: width, height: height) else { return nil }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let data = context.data else { return nil }
            let buffer = data.assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = context.bytesPerRow

            var samples: [(r: Double, g: Double, b: Double)] = []
            samples.reserveCapacity(width * height)
            for y in 0..<height {
                let rowOffset = y * bytesPerRow
                for x in 0..<width {
                    let i = rowOffset + x * bytesPerPixel
                    let alpha = buffer[i + 3]
                    if alpha < 40 { continue } // ignore transparent backdrop pixels
                    let invAlpha = 1.0 / Double(alpha)
                    let r = min(Double(buffer[i]) * invAlpha, 1.0)
                    let g = min(Double(buffer[i + 1]) * invAlpha, 1.0)
                    let b = min(Double(buffer[i + 2]) * invAlpha, 1.0)
                    samples.append((r, g, b))
                }
            }
            return samples
        }
    }

    /// Best perceptual color match distance between a target swatch and an item's palette.
    public static func bestDeltaE(target: LabColor, palette: [LabColor]) -> Double? {
        guard !palette.isEmpty else { return nil }
        var bestSq = Double.greatestFiniteMagnitude
        for swatch in palette {
            let d = target.deltaESquared(to: swatch)
            if d < bestSq { bestSq = d }
        }
        return bestSq.squareRoot()
    }
}

public extension LabColor {
    /// CIEDE2000 with the standard unit weighting for lightness, chroma, and hue.
    nonisolated func deltaE2000(to other: LabColor) -> Double {
        func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
        func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
        func hue(_ a: Double, _ b: Double) -> Double {
            if a == 0, b == 0 { return 0 }
            let angle = degrees(atan2(b, a))
            return angle < 0 ? angle + 360 : angle
        }

        let meanChroma = (hypot(a, b) + hypot(other.a, other.b)) * 0.5
        let chromaPower = pow(meanChroma, 7)
        let g = 0.5 * (1 - sqrt(chromaPower / (chromaPower + pow(25, 7))))
        let a1 = (1 + g) * a
        let a2 = (1 + g) * other.a
        let c1 = hypot(a1, b)
        let c2 = hypot(a2, other.b)
        let h1 = hue(a1, b)
        let h2 = hue(a2, other.b)
        let difference = h2 - h1
        let deltaHue: Double = if c1 * c2 == 0 { 0 }
            else if abs(difference) <= 180 { difference }
            else { difference > 180 ? difference - 360 : difference + 360 }
        let meanHue: Double = if c1 * c2 == 0 { h1 + h2 }
            else if abs(difference) <= 180 { (h1 + h2) / 2 }
            else { (h1 + h2 + (h1 + h2 < 360 ? 360 : -360)) / 2 }
        let meanLightness = (l + other.l) / 2
        let meanAdjustedChroma = (c1 + c2) / 2
        let t = 1 - 0.17 * cos(radians(meanHue - 30)) + 0.24 * cos(radians(2 * meanHue))
            + 0.32 * cos(radians(3 * meanHue + 6)) - 0.20 * cos(radians(4 * meanHue - 63))
        let lightnessOffset = pow(meanLightness - 50, 2)
        let lightnessScale = 1 + 0.015 * lightnessOffset / sqrt(20 + lightnessOffset)
        let chromaScale = 1 + 0.045 * meanAdjustedChroma
        let hueScale = 1 + 0.015 * meanAdjustedChroma * t
        let adjustedPower = pow(meanAdjustedChroma, 7)
        let rotation = -2 * sqrt(adjustedPower / (adjustedPower + pow(25, 7)))
            * sin(radians(60 * exp(-pow((meanHue - 275) / 25, 2))))
        let dl = (other.l - l) / lightnessScale
        let dc = (c2 - c1) / chromaScale
        let dh = 2 * sqrt(c1 * c2) * sin(radians(deltaHue / 2)) / hueScale
        return sqrt(max(0, dl * dl + dc * dc + dh * dh + rotation * dc * dh))
    }
}
