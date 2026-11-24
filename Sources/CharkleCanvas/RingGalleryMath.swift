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
    public var depthBlur: Double = 14
    public var farFade: Double = 0.50
    public var cornerRadius: Double = 32
    public var nearPlane: Double = 140

    public init(
        slotCount: Int = 22,
        cardWidth: Double = 180,
        cardHeight: Double = 300,
        cardGap: Double = 18,
        perspective: Double = 1500,
        depthBlur: Double = 14,
        farFade: Double = 0.50,
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
        // Bisection fallback for extreme slope regions
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

/// Projected visibility & screen-space hit-test geometry for one slot on the Outside Ring.
public struct RingProjectedCard: Equatable, Sendable {
    public let virtualIndex: Int
    public let assetIndex: Int
    public let arcS: Double
    public let centerX: Double
    public let centerZ: Double
    public let minScreenX: Double
    public let maxScreenX: Double
    public let maxHalfScreenY: Double
    public let uMin: Double
    public let uMax: Double
    public let isFarSide: Bool

    public func contains(screenX: Double, screenY: Double) -> Bool {
        screenX >= minScreenX && screenX <= maxScreenX && abs(screenY) <= maxHalfScreenY
    }
}

/// Pure geometric, projection, depth-of-field, and gesture-glide math for the 3D Outside Ring Gallery.
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

    /// Continuous front-center virtual index (`round(offset / step)`).
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
    /// `max(blur * smoothstep(110, halfW, |screenX|)^1.4, blur * smoothstep(0.25, 0.8, back)^1.2)`.
    public static func depthOfFieldBlur(
        screenX: Double,
        halfViewportWidth: Double,
        z: Double,
        radius: Double,
        maxBlur: Double
    ) -> Double {
        guard maxBlur > 0 else { return 0 }
        let halfW = max(120.0, halfViewportWidth)
        let back = clamp(-z / (2.0 * max(1.0, radius)), 0.0, 1.0)
        let sideBlur = maxBlur * pow(smoothstep(110.0, halfW, abs(screenX)), 1.4)
        let depthBlur = maxBlur * pow(smoothstep(0.25, 0.8, back), 1.2)
        return max(sideBlur, depthBlur)
    }

    /// Far-side fade fraction toward the page background: `fade * smoothstep(0.3, 1.0, back)`.
    public static func farFadeAmount(z: Double, radius: Double, fade: Double) -> Double {
        let back = clamp(-z / (2.0 * max(1.0, radius)), 0.0, 1.0)
        return clamp(fade, 0.0, 1.0) * smoothstep(0.3, 1.0, back)
    }

    /// Computes post-drag momentum target (snapped to nearest card) and cubic-bezier glide duration.
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

    /// Computes the silhouette horizon angle `thetaSil = acos(R / (P + R))` on the Outside ring
    /// where projected `sx(theta)` transitions between front-facing and far-facing slopes.
    public static func outsideSilhouetteAngle(radius: Double, perspective: Double) -> Double {
        let ratio = clamp(radius / max(1.0, perspective + radius), -1.0, 1.0)
        return acos(ratio)
    }

    /// Projects all visible ring cards for the current `offset`, sorted farthest-first (painter's order).
    /// Supports arbitrary library sizes (`assetCount` from 1 up to tens of thousands) via continuous
    /// virtual indexing around the `slotCount` ring.
    public static func visibleOutsideCards(
        assetCount: Int,
        offset: Double,
        params: RingGalleryParameters,
        viewportSize: CGSize,
        cardScale: Double = 1.0,
        pressScaleForVirtualIndex: (Int) -> Double = { _ in 1.0 }
    ) -> [RingProjectedCard] {
        guard assetCount > 0, viewportSize.width > 10, viewportSize.height > 10 else { return [] }

        let step = params.step
        let radius = params.radius
        let c = params.curvature
        let P = params.perspective
        let halfW = Double(viewportSize.width) * 0.5
        let halfH = Double(viewportSize.height) * 0.5
        let pad = params.depthBlur + 4.0
        let thetaSil = outsideSilhouetteAngle(radius: radius, perspective: P)

        let centerVirtual = frontVirtualIndex(offset: offset, step: step)
        // For tiny folders (1–3 items), show only the actual items cleanly centered;
        // for 4+ items, form the complete 22-slot continuous ring.
        let slotOffsets: [Int]
        if assetCount <= 3 {
            let clampedCenter = clamp(Double(centerVirtual), 0, Double(assetCount - 1))
            let base = Int(clampedCenter.rounded())
            slotOffsets = (0..<assetCount).map { $0 - base }
        } else {
            let halfSlots = params.slotCount / 2
            slotOffsets = Array((-halfSlots)..<(params.slotCount - halfSlots))
        }

        var cards: [RingProjectedCard] = []
        cards.reserveCapacity(slotOffsets.count)

        for rel in slotOffsets {
            let virtualIdx = assetCount <= 3 ? (Int(clamp(Double(centerVirtual), 0, Double(assetCount - 1)).rounded()) + rel) : (centerVirtual + rel)
            let s = Double(virtualIdx) * step - offset
            // Reject slots outside half-circumference wrap window
            if abs(s) > params.circumference * 0.5 + step * 0.5 { continue }

            let pScale = pressScaleForVirtualIndex(virtualIdx)
            let halfCardW = params.cardWidth * 0.5 * pScale
            let halfCardH = params.cardHeight * 0.5 * pScale

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
                // Compare screen spans of front portion vs far portion; draw whichever forms the visible horizon
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

            // Sample 9 points across [uMin, uMax] for exact screen bounding box & near-plane cull
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

            // Off-frame cull (accounting for blur margin)
            if maxSX + pad < -halfW || minSX - pad > halfW { continue }
            if maxHalfSY + pad < -halfH { continue }

            let centerPt = placePoint(arcS: s + 0.5 * (uMin + uMax), curvature: c)
            let assetIdx = positiveMod(virtualIdx, count: assetCount)
            cards.append(RingProjectedCard(
                virtualIndex: virtualIdx,
                assetIndex: assetIdx,
                arcS: s,
                centerX: centerPt.x,
                centerZ: centerPt.z,
                minScreenX: minSX,
                maxScreenX: maxSX,
                maxHalfScreenY: maxHalfSY,
                uMin: uMin / pScale,
                uMax: uMax / pScale,
                isFarSide: isFarSide
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
