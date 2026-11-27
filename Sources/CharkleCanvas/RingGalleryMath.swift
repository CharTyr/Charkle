import CharkleCore
import CoreGraphics
import Foundation

/// Configurable live tuning parameters for the 3D Outside Ring Gallery.
/// All defaults mirror the calibrated eye-level Outside ring geometry and depth-of-field spec.
public struct RingGalleryParameters: Equatable, Sendable {
    public var slotCount: Int = 22
    public var cardWidth: Double = 180
    public var cardHeight: Double = 300
    public var cardGap: Double = 18
    public var perspective: Double = 1500
    public var depthBlur: Double = 2
    public var farFade: Double = 0.96
    public var cornerRadius: Double = 32
    public var nearPlane: Double = 140

    public init(
        slotCount: Int = 22,
        cardWidth: Double = 180,
        cardHeight: Double = 300,
        cardGap: Double = 18,
        perspective: Double = 1500,
        depthBlur: Double = 2,
        farFade: Double = 0.96,
        cornerRadius: Double = 32,
        nearPlane: Double = 140
    ) {
        self.slotCount = slotCount
        self.cardWidth = cardWidth
        self.cardHeight = cardHeight
        self.cardGap = cardGap
        self.perspective = perspective
        self.depthBlur = depthBlur
        self.farFade = farFade
        self.cornerRadius = cornerRadius
        self.nearPlane = nearPlane
    }

    public static let `default` = RingGalleryParameters()

    public var step: Double { cardWidth + cardGap }
    public var circumference: Double { Double(slotCount) * step }
    public var radius: Double { circumference / (2.0 * .pi) }
    /// Outside view (`bend = -1`): signed curvature `c = -1 / R`.
    public var curvature: Double { -1.0 / max(1.0, radius) }
}

/// Deterministic CSS-equivalent `cubic-bezier(x1, y1, x2, y2)` solver.
public struct RingCubicBezier: Sendable, Equatable {
    public let x1: Double
    public let y1: Double
    public let x2: Double
    public let y2: Double

    public static let dragGlide = RingCubicBezier(x1: 0.25, y1: 0.60, x2: 0.20, y2: 1.00)
    public static let pressIn = RingCubicBezier(x1: 0.23, y1: 1.00, x2: 0.32, y2: 1.00)
    public static let pressOut = RingCubicBezier(x1: 0.22, y1: 1.00, x2: 0.36, y2: 1.00)

    public init(x1: Double, y1: Double, x2: Double, y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    private func sampleX(_ t: Double) -> Double {
        let u = 1.0 - t
        return 3.0 * u * u * t * x1 + 3.0 * u * t * t * x2 + t * t * t
    }

    private func sampleDX(_ t: Double) -> Double {
        let u = 1.0 - t
        return 3.0 * u * u * x1 + 6.0 * u * t * (x2 - x1) + 3.0 * t * t * (1.0 - x2)
    }

    private func sampleY(_ t: Double) -> Double {
        let u = 1.0 - t
        return 3.0 * u * u * t * y1 + 3.0 * u * t * t * y2 + t * t * t
    }

    public func evaluate(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        var t = x
        for _ in 0..<8 {
            let err = sampleX(t) - x
            if abs(err) < 1e-6 { break }
            let dx = sampleDX(t)
            if abs(dx) < 1e-6 { break }
            t = min(1.0, max(0.0, t - err / dx))
        }
        var lo = 0.0
        var hi = 1.0
        if abs(sampleX(t) - x) > 1e-4 {
            for _ in 0..<12 {
                let mid = 0.5 * (lo + hi)
                if sampleX(mid) < x { lo = mid } else { hi = mid }
            }
            t = 0.5 * (lo + hi)
        }
        return sampleY(t)
    }
}

/// Precomputed variable-width arc track mirroring Horizontal Justified Masonry:
/// every card shares `cardHeight`, takes its natural aspect-ratio width, and sits strictly `cardGap` apart.
public struct RingCardTrack: Equatable, Sendable {
    public let cardWidths: [Double]
    public let centerArcs: [Double]
    public let totalTrackLength: Double
    public let cardHeight: Double
    public let cardGap: Double

    public var count: Int { cardWidths.count }
    public var isEmpty: Bool { cardWidths.isEmpty }

    public init(cardWidths: [Double], cardHeight: Double, cardGap: Double) {
        self.cardWidths = cardWidths
        self.cardHeight = cardHeight
        self.cardGap = cardGap

        guard !cardWidths.isEmpty else {
            self.centerArcs = []
            self.totalTrackLength = 0
            return
        }

        var centers: [Double] = []
        centers.reserveCapacity(cardWidths.count)
        centers.append(0)
        for i in 1..<cardWidths.count {
            let prev = centers[i - 1]
            centers.append(prev + 0.5 * cardWidths[i - 1] + cardGap + 0.5 * cardWidths[i])
        }
        self.centerArcs = centers
        self.totalTrackLength = cardWidths.reduce(0.0) { $0 + $1 + cardGap }
    }

    public static func build(from assets: [AssetRecord], params: RingGalleryParameters) -> RingCardTrack {
        let widths = assets.map { RingGalleryMath.cardWidth(for: $0, cardHeight: params.cardHeight) }
        return RingCardTrack(cardWidths: widths, cardHeight: params.cardHeight, cardGap: params.cardGap)
    }

    public static func uniform(count: Int, params: RingGalleryParameters) -> RingCardTrack {
        RingCardTrack(
            cardWidths: Array(repeating: params.cardWidth, count: max(0, count)),
            cardHeight: params.cardHeight,
            cardGap: params.cardGap
        )
    }

    public func cardWidth(forVirtualIndex vIdx: Int) -> Double {
        guard !cardWidths.isEmpty else { return 180 }
        return cardWidths[RingGalleryMath.positiveMod(vIdx, count: cardWidths.count)]
    }

    public func centerArc(forVirtualIndex vIdx: Int) -> Double {
        guard !cardWidths.isEmpty else { return 0 }
        let n = cardWidths.count
        let lap = RingGalleryMath.floorDiv(vIdx, n)
        let idx = RingGalleryMath.positiveMod(vIdx, count: n)
        return Double(lap) * totalTrackLength + centerArcs[idx]
    }

    /// Finds the closest virtual card index to `offset` in `O(log N)`.
    public func nearestVirtualIndex(to offset: Double) -> Int {
        let n = cardWidths.count
        guard n > 0, totalTrackLength > 0 else { return 0 }
        if n <= 3 {
            var best = 0
            var bestDist = abs(centerArcs[0] - offset)
            for i in 1..<n {
                let d = abs(centerArcs[i] - offset)
                if d < bestDist {
                    bestDist = d
                    best = i
                }
            }
            return best
        }

        let lap = Int(floor(offset / totalTrackLength))
        let rem = offset - Double(lap) * totalTrackLength

        // Binary search first index with centerArcs[idx] >= rem
        var lo = 0
        var hi = n
        while lo < hi {
            let mid = (lo + hi) / 2
            if centerArcs[mid] < rem {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        let candidates = [lap * n + lo - 1, lap * n + lo, lap * n + lo + 1]
        var bestIdx = candidates[1]
        var bestDist = abs(centerArc(forVirtualIndex: bestIdx) - offset)
        for cand in candidates {
            let d = abs(centerArc(forVirtualIndex: cand) - offset)
            if d < bestDist {
                bestDist = d
                bestIdx = cand
            }
        }
        return bestIdx
    }

    /// Smoothly interpolates the front card width at the current continuous `offset`
    /// so the depth-of-field sharp center zone never jumps when scrolling between portrait and landscape cards.
    public func interpolatedFrontCardWidth(at offset: Double) -> Double {
        guard !cardWidths.isEmpty else { return 180 }
        let nearest = nearestVirtualIndex(to: offset)
        let c0 = centerArc(forVirtualIndex: nearest)
        let w0 = cardWidth(forVirtualIndex: nearest)
        let neighbor = offset >= c0 ? (nearest + 1) : (nearest - 1)
        if count <= 3 && (neighbor < 0 || neighbor >= count) {
            return w0
        }
        let c1 = centerArc(forVirtualIndex: neighbor)
        let w1 = cardWidth(forVirtualIndex: neighbor)
        let span = abs(c1 - c0)
        guard span > 1e-4 else { return w0 }
        let t = RingGalleryMath.clamp(abs(offset - c0) / span, 0.0, 1.0)
        return w0 + (w1 - w0) * t
    }
}

/// Projected visibility & screen-space hit-test geometry for one slot on the Outside Ring.
public struct RingProjectedCard: Equatable, Sendable {
    public let virtualIndex: Int
    public let assetIndex: Int
    public let arcS: Double
    public let cardWidth: Double
    public let centerX: Double
    public let centerZ: Double
    public let minScreenX: Double
    public let maxScreenX: Double
    public let maxHalfScreenY: Double
    public let uMin: Double
    public let uMax: Double
    public let isFarSide: Bool
    public let seamAlpha: Double

    public func contains(screenX: Double, screenY: Double) -> Bool {
        screenX >= minScreenX && screenX <= maxScreenX && abs(screenY) <= maxHalfScreenY
    }
}

/// Pure geometric, projection, depth-of-field, adaptive scaling, and gesture-glide math for the 3D Outside Ring Gallery.
public enum RingGalleryMath {
    public static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, v))
    }

    public static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let denom = edge1 - edge0
        if abs(denom) < 1e-9 { return x < edge0 ? 0.0 : 1.0 }
        let t = clamp((x - edge0) / denom, 0.0, 1.0)
        return t * t * (3.0 - 2.0 * t)
    }

    /// Wraps signed arc coordinate into `[-circumference / 2, circumference / 2)`.
    public static func wrapArc(_ value: Double, circumference: Double) -> Double {
        guard circumference > 0 else { return 0 }
        let half = circumference * 0.5
        var r = value.truncatingRemainder(dividingBy: circumference)
        if r >= half { r -= circumference }
        if r < -half { r += circumference }
        return r
    }

    /// Positive modulo index in `[0, count)`.
    public static func positiveMod(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let m = index % count
        return m >= 0 ? m : m + count
    }

    /// Euclidean floor division (`floor(a / b)`) supporting negative indices cleanly.
    public static func floorDiv(_ a: Int, _ b: Int) -> Int {
        guard b > 0 else { return 0 }
        let q = a / b
        let r = a % b
        return (r != 0 && a < 0) ? (q - 1) : q
    }

    /// Natural aspect ratio per asset matching Horizontal Justified Masonry (zero landscape cropping).
    public static func effectiveAspectRatio(for asset: AssetRecord) -> Double {
        let raw: Double = switch asset.mediaKind {
        case .audio:
            1.55
        case .webBookmark:
            if asset.pixelWidth > 0 && asset.pixelHeight > 0 {
                asset.aspectRatio
            } else if asset.isSocialPost {
                asset.richMetadata?.socialPost?.platform.isVerticalFeedPlatform == true
                    ? 0.625
                    : (asset.richMetadata?.socialPost?.platform.isVideoPlatform == true ? 1.26 : 1.12)
            } else if asset.isGitHubRepo {
                1.32
            } else {
                1.60
            }
        case .document:
            if asset.fileName.lowercased().hasSuffix(".swatch") {
                1.0
            } else if asset.pixelWidth > 0 && asset.pixelHeight > 0 {
                asset.aspectRatio
            } else {
                0.84
            }
        case .model3D:
            asset.pixelWidth > 0 && asset.pixelHeight > 0 ? asset.aspectRatio : 1.0
        default:
            asset.aspectRatio
        }
        return clamp(raw, 0.52, 2.25)
    }

    /// Computes a card's unscaled arc width from its natural aspect ratio at fixed `cardHeight`.
    public static func cardWidth(forAspectRatio aspect: Double, cardHeight: Double) -> Double {
        let clampedAspect = clamp(aspect, 0.52, 2.25)
        return (cardHeight * clampedAspect).rounded()
    }

    public static func cardWidth(for asset: AssetRecord, cardHeight: Double) -> Double {
        cardWidth(forAspectRatio: effectiveAspectRatio(for: asset), cardHeight: cardHeight)
    }

    /// Exact closed-form unscaled half-width of the projected Outside cylinder silhouette:
    /// `x_sil = R * P / sqrt(P^2 + 2 * P * R)`.
    public static func outsideProjectedHalfWidth(radius: Double, perspective: Double) -> Double {
        let r = max(1.0, radius)
        let p = max(1.0, perspective)
        return (r * p) / sqrt(p * p + 2.0 * p * r)
    }

    /// Computes live viewport-adaptive `cardScale` so the Outside ring fills ~94% of the window width
    /// while staying cleanly within vertical headroom between top chrome and bottom navigation pill.
    public static func adaptiveCardScale(
        viewportSize: CGSize,
        topSafeInset: Double,
        bottomSafeInset: Double = 72.0,
        params: RingGalleryParameters
    ) -> Double {
        let w = max(240.0, Double(viewportSize.width))
        let h = max(220.0, Double(viewportSize.height))
        let naturalHalfW = outsideProjectedHalfWidth(radius: params.radius, perspective: params.perspective)

        let horizontalMargin = clamp(w * 0.03, 18.0, 44.0)
        let targetHalfW = max(110.0, w * 0.5 - horizontalMargin)
        let scaleForWidth = targetHalfW / max(1.0, naturalHalfW)

        let usableH = max(150.0, h - topSafeInset - bottomSafeInset)
        let scaleForHeight = (usableH * 0.78) / max(1.0, params.cardHeight)

        return clamp(min(scaleForWidth, scaleForHeight), 0.34, 2.8)
    }

    /// Computes visual vertical center offset (Y-up points from viewport center) between top & bottom chrome.
    public static func verticalCenterBias(topSafeInset: Double, bottomSafeInset: Double = 72.0) -> Double {
        (bottomSafeInset - topSafeInset) * 0.5
    }

    /// Continuous front-center virtual index for uniform-width tracks (`round(offset / step)`).
    public static func frontVirtualIndex(offset: Double, step: Double) -> Int {
        guard step > 0 else { return 0 }
        return Int((offset / step).rounded())
    }

    /// Places a point at signed arc coordinate `s` on a ring with signed curvature `c = bend / R`.
    public static func placePoint(arcS s: Double, curvature c: Double) -> (x: Double, z: Double, angle: Double) {
        if abs(c) < 1e-9 {
            return (s, 0, 0)
        }
        let a = s * c
        return (sin(a) / c, (1.0 - cos(a)) / c, a)
    }

    /// Eye-level straight-on perspective projection `(x, y, z) -> (sx, sy)` from viewport center.
    public static func project(
        x: Double,
        y: Double,
        z: Double,
        perspective P: Double,
        nearPlane: Double = 140
    ) -> (sx: Double, sy: Double)? {
        let depth = P - z
        guard depth >= nearPlane else { return nil }
        let scale = P / depth
        return (x * scale, y * scale)
    }

    /// Per-pixel Outside depth-of-field blur radius in screen points:
    /// `max(blur * smoothstep(sharpHalf, halfW, |screenX|)^1.4, blur * smoothstep(0.25, 0.8, back)^1.2)`.
    public static func depthOfFieldBlur(
        screenX: Double,
        halfViewportWidth: Double,
        z: Double,
        radius: Double,
        maxBlur: Double,
        sharpHalfWidth: Double = 110.0
    ) -> Double {
        guard maxBlur > 0 else { return 0 }
        let halfW = max(sharpHalfWidth + 10.0, halfViewportWidth)
        let back = clamp(-z / (2.0 * max(1.0, radius)), 0.0, 1.0)
        let sideBlur = maxBlur * pow(smoothstep(sharpHalfWidth, halfW, abs(screenX)), 1.4)
        let depthBlur = maxBlur * pow(smoothstep(0.25, 0.8, back), 1.2)
        return max(sideBlur, depthBlur)
    }

    /// Far-side fade fraction toward the page background: `fade * smoothstep(0.3, 1.0, back)`.
    public static func farFadeAmount(z: Double, radius: Double, fade: Double) -> Double {
        let back = clamp(-z / (2.0 * max(1.0, radius)), 0.0, 1.0)
        return clamp(fade, 0.0, 1.0) * smoothstep(0.3, 1.0, back)
    }

    /// Computes post-drag momentum target (snapped to nearest card on uniform step) and glide duration.
    public static func releaseGlide(
        offset: Double,
        velocity: Double,
        step: Double,
        reducedMotion: Bool
    ) -> (targetOffset: Double, duration: Double) {
        guard step > 0 else { return (offset, 0.2) }
        if reducedMotion {
            let snapped = (offset / step).rounded() * step
            let dist = abs(snapped - offset)
            return (snapped, min(0.20, max(0.08, dist * 0.0012)))
        }
        let projected = offset - velocity * 0.260
        let snapped = (projected / step).rounded() * step
        let dist = abs(snapped - offset)
        let duration = clamp(dist * 0.0016, 0.420, 1.100)
        return (snapped, duration)
    }

    /// Computes post-drag momentum target snapped to the nearest variable-width card on `track`.
    public static func releaseGlide(
        offset: Double,
        velocityArcPerSec: Double,
        track: RingCardTrack,
        reducedMotion: Bool
    ) -> (targetOffset: Double, duration: Double) {
        guard !track.isEmpty else { return (offset, 0.2) }
        if reducedMotion {
            let snapIdx = track.nearestVirtualIndex(to: offset)
            let snapped = track.centerArc(forVirtualIndex: snapIdx)
            let dist = abs(snapped - offset)
            return (snapped, min(0.20, max(0.08, dist * 0.0012)))
        }
        let projected = offset - velocityArcPerSec * 0.260
        let snapIdx = track.nearestVirtualIndex(to: projected)
        let snapped = track.centerArc(forVirtualIndex: snapIdx)
        let dist = abs(snapped - offset)
        let duration = clamp(dist * 0.0016, 0.420, 1.100)
        return (snapped, duration)
    }

    /// Computes the silhouette horizon angle `thetaSil = acos(R / (P + R))` on the Outside ring
    /// where projected `sx(theta)` transitions between front-facing and far-facing slopes.
    public static func outsideSilhouetteAngle(radius: Double, perspective: Double) -> Double {
        let ratio = clamp(radius / max(1.0, perspective + radius), -1.0, 1.0)
        return acos(ratio)
    }

    /// Projects all visible uniform-width ring cards (convenience wrapper kept for tests & callers).
    public static func visibleOutsideCards(
        assetCount: Int,
        offset: Double,
        params: RingGalleryParameters,
        viewportSize: CGSize,
        cardScale: Double = 1.0,
        pressScaleForVirtualIndex: (Int) -> Double = { _ in 1.0 }
    ) -> [RingProjectedCard] {
        let track = RingCardTrack.uniform(count: assetCount, params: params)
        return visibleOutsideCards(
            track: track,
            offset: offset,
            params: params,
            viewportSize: viewportSize,
            cardScale: cardScale,
            pressScaleForVirtualIndex: pressScaleForVirtualIndex
        )
    }

    /// Projects all visible variable-width ring cards packed around the full Outside circumference,
    /// sorted farthest-first (painter's order). Zero horizontal cropping for landscape assets.
    public static func visibleOutsideCards(
        track: RingCardTrack,
        offset: Double,
        params: RingGalleryParameters,
        viewportSize: CGSize,
        cardScale: Double = 1.0,
        pressScaleForVirtualIndex: (Int) -> Double = { _ in 1.0 }
    ) -> [RingProjectedCard] {
        let assetCount = track.count
        guard assetCount > 0, viewportSize.width > 10, viewportSize.height > 10 else { return [] }

        let radius = params.radius
        let halfCirc = params.circumference * 0.5
        let c = params.curvature
        let P = params.perspective
        let halfW = Double(viewportSize.width) * 0.5
        let halfH = Double(viewportSize.height) * 0.5
        let pad = params.depthBlur * clamp(cardScale, 0.72, 1.38) + 4.0
        let thetaSil = outsideSilhouetteAngle(radius: radius, perspective: P)

        let centerVirtual = track.nearestVirtualIndex(to: offset)

        // Collect virtual indices walking outward from front center in both directions without
        // overlapping at the far back seam `s = ±halfCirc`.
        var virtualIndices: [Int] = []
        virtualIndices.reserveCapacity(min(64, params.slotCount + 8))
        if assetCount <= 3 {
            for i in 0..<assetCount { virtualIndices.append(i) }
        } else {
            let seamLimit = halfCirc - params.cardGap * 0.5
            virtualIndices.append(centerVirtual)

            // Walk forward (+s)
            var vRight = centerVirtual + 1
            var safety = 0
            while safety < 64 {
                let s = track.centerArc(forVirtualIndex: vRight) - offset
                let w = track.cardWidth(forVirtualIndex: vRight)
                if s + w * 0.5 > seamLimit { break }
                virtualIndices.append(vRight)
                vRight += 1
                safety += 1
            }

            // Walk backward (-s)
            var vLeft = centerVirtual - 1
            safety = 0
            while safety < 64 {
                let s = track.centerArc(forVirtualIndex: vLeft) - offset
                let w = track.cardWidth(forVirtualIndex: vLeft)
                if s - w * 0.5 < -seamLimit { break }
                virtualIndices.append(vLeft)
                vLeft -= 1
                safety += 1
            }
        }

        var cards: [RingProjectedCard] = []
        cards.reserveCapacity(virtualIndices.count)

        for virtualIdx in virtualIndices {
            let s = track.centerArc(forVirtualIndex: virtualIdx) - offset
            let baseCardW = track.cardWidth(forVirtualIndex: virtualIdx)
            let pScale = pressScaleForVirtualIndex(virtualIdx)
            let halfCardW = baseCardW * 0.5 * pScale
            let halfCardH = params.cardHeight * 0.5 * pScale

            // Smooth fade near the exact far-back seam (`|s| + halfW -> halfCirc`) so cards
            // entering/leaving the rear seam behind the front cards never pop visibly.
            let seamMargin = max(0.0, halfCirc - (abs(s) + halfCardW))
            let seamAlpha = assetCount <= 3 ? 1.0 : smoothstep(0.0, 140.0, seamMargin)
            if seamAlpha < 0.005 { continue }

            // Determine monotonic facing slice so a card straddling the exact silhouette tangent
            // never self-overlaps and double-blends a crease.
            let thetaStart = (s - halfCardW) / radius
            let thetaEnd = (s + halfCardW) / radius
            let absStart = abs(thetaStart)
            let absEnd = abs(thetaEnd)

            var uMin = -halfCardW
            var uMax = halfCardW
            var isFarSide = abs(s / radius) > thetaSil

            if (absStart < thetaSil && absEnd > thetaSil) || (absEnd < thetaSil && absStart > thetaSil) {
                let sign: Double = s >= 0 ? 1.0 : -1.0
                let silS = sign * thetaSil * radius
                let uSil = clamp(silS - s, -halfCardW, halfCardW)
                let pStart = placePoint(arcS: s - halfCardW, curvature: c)
                let pSil = placePoint(arcS: s + uSil, curvature: c)
                let pEnd = placePoint(arcS: s + halfCardW, curvature: c)
                if let sxStart = project(x: pStart.x, y: 0, z: pStart.z, perspective: P, nearPlane: params.nearPlane)?.sx,
                   let sxSil = project(x: pSil.x, y: 0, z: pSil.z, perspective: P, nearPlane: params.nearPlane)?.sx,
                   let sxEnd = project(x: pEnd.x, y: 0, z: pEnd.z, perspective: P, nearPlane: params.nearPlane)?.sx {
                    let spanA = abs(sxSil - sxStart)
                    let spanB = abs(sxEnd - sxSil)
                    let startIsFront = absStart < thetaSil
                    if spanA >= spanB {
                        uMin = -halfCardW
                        uMax = uSil
                        isFarSide = !startIsFront
                    } else {
                        uMin = uSil
                        uMax = halfCardW
                        isFarSide = startIsFront
                    }
                }
            }

            guard uMax - uMin > 0.25 else { continue }

            var minSX = Double.greatestFiniteMagnitude
            var maxSX = -Double.greatestFiniteMagnitude
            var maxHalfSY = 0.0
            var tooClose = false

            for k in 0...8 {
                let u = uMin + (uMax - uMin) * (Double(k) / 8.0)
                let pt = placePoint(arcS: s + u, curvature: c)
                if P - pt.z < params.nearPlane {
                    tooClose = true
                    break
                }
                let scale = (P / (P - pt.z)) * cardScale
                let sx = pt.x * scale
                let sy = halfCardH * scale
                if sx < minSX { minSX = sx }
                if sx > maxSX { maxSX = sx }
                if sy > maxHalfSY { maxHalfSY = sy }
            }
            if tooClose { continue }

            if maxSX + pad < -halfW || minSX - pad > halfW { continue }
            if maxHalfSY + pad < -halfH { continue }

            let centerPt = placePoint(arcS: s + 0.5 * (uMin + uMax), curvature: c)
            let assetIdx = positiveMod(virtualIdx, count: assetCount)
            cards.append(RingProjectedCard(
                virtualIndex: virtualIdx,
                assetIndex: assetIdx,
                arcS: s,
                cardWidth: baseCardW,
                centerX: centerPt.x,
                centerZ: centerPt.z,
                minScreenX: minSX,
                maxScreenX: maxSX,
                maxHalfScreenY: maxHalfSY,
                uMin: uMin / pScale,
                uMax: uMax / pScale,
                isFarSide: isFarSide,
                seamAlpha: seamAlpha
            ))
        }

        // Painter's order: farthest Z first so near sharp cards composite cleanly over far blurred cards
        cards.sort { lhs, rhs in
            if abs(lhs.centerZ - rhs.centerZ) > 0.01 {
                return lhs.centerZ < rhs.centerZ
            }
            return abs(lhs.arcS) > abs(rhs.arcS)
        }
        return cards
    }
}
