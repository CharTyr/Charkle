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
        centroids.append(labPixels[labPixels.count / 2])

        while centroids.count < k {
            var farthestIndex = 0
            var maxMinDist = -1.0
            for (idx, p) in labPixels.enumerated() {
                var minDist = Double.greatestFiniteMagnitude
                for c in centroids {
                    let dl = p.l - c.l
                    let da = p.a - c.a
                    let db = p.b - c.b
                    let d = dl * dl + da * da + db * db
                    if d < minDist { minDist = d }
                }
                if minDist > maxMinDist {
                    maxMinDist = minDist
                    farthestIndex = idx
                }
            }
            if maxMinDist <= 1.0 { break }
            centroids.append(labPixels[farthestIndex])
        }

        let clusterCount = centroids.count
        var assignments = Array(repeating: 0, count: labPixels.count)

        for _ in 0..<8 {
            var sumL = Array(repeating: 0.0, count: clusterCount)
            var sumA = Array(repeating: 0.0, count: clusterCount)
            var sumB = Array(repeating: 0.0, count: clusterCount)
            var counts = Array(repeating: 0, count: clusterCount)

            for (i, p) in labPixels.enumerated() {
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
                assignments[i] = bestIdx
                sumL[bestIdx] += p.l
                sumA[bestIdx] += p.a
                sumB[bestIdx] += p.b
                counts[bestIdx] += 1
            }

            for cIdx in 0..<clusterCount where counts[cIdx] > 0 {
                let n = Double(counts[cIdx])
                centroids[cIdx] = (sumL[cIdx] / n, sumA[cIdx] / n, sumB[cIdx] / n)
            }
        }

        // Compute representative average sRGB per cluster
        var sumR = Array(repeating: 0.0, count: clusterCount)
        var sumG = Array(repeating: 0.0, count: clusterCount)
        var sumBl = Array(repeating: 0.0, count: clusterCount)
        var clusterSize = Array(repeating: 0, count: clusterCount)

        for (i, rgb) in pixels.enumerated() {
            let cIdx = assignments[i]
            sumR[cIdx] += rgb.r
            sumG[cIdx] += rgb.g
            sumBl[cIdx] += rgb.b
            clusterSize[cIdx] += 1
        }

        let total = Double(pixels.count)
        var rawSwatches: [LabColor] = []
        rawSwatches.reserveCapacity(clusterCount)
        for cIdx in 0..<clusterCount where clusterSize[cIdx] > 0 {
            let n = Double(clusterSize[cIdx])
            let rgb = [sumR[cIdx] / n, sumG[cIdx] / n, sumBl[cIdx] / n]
            let hex = "#" + rgb.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
            let swatch = LabColor.fromHex(hex, proportion: n / total)
            rawSwatches.append(swatch)
        }

        // Deduplicate near-identical swatches (deltaE < 8)
        let sorted = rawSwatches.sorted { $0.proportion > $1.proportion }
        var merged: [LabColor] = []
        for swatch in sorted {
            if !merged.contains(where: { $0.deltaE(to: swatch) < 8.0 }) {
                merged.append(swatch)
            }
        }
        return Array(merged.prefix(count))
    }

    public static func extractDominantColors(from url: URL, count: Int = 6) -> [LabColor] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 96,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return []
        }
        return extractDominantColors(from: cgImage, count: count)
    }

    private static func sampleRGBPixels(from image: CGImage, maxSide: Int) -> [(r: Double, g: Double, b: Double)]? {
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

        var samples: [(r: Double, g: Double, b: Double)] = []
        samples.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * context.bytesPerRow + x * bytesPerPixel
                let alpha = buffer[i + 3]
                if alpha < 40 { continue } // ignore transparent backdrop pixels
                let a = Double(alpha) / 255.0
                let r = min(Double(buffer[i]) / 255.0 / a, 1.0)
                let g = min(Double(buffer[i + 1]) / 255.0 / a, 1.0)
                let b = min(Double(buffer[i + 2]) / 255.0 / a, 1.0)
                samples.append((r, g, b))
            }
        }
        return samples
    }

    /// Best perceptual color match distance between a target swatch and an item's palette.
    public static func bestDeltaE(target: LabColor, palette: [LabColor]) -> Double? {
        guard !palette.isEmpty else { return nil }
        return palette.map { target.deltaE(to: $0) }.min()
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
