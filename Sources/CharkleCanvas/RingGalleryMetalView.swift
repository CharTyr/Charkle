import AppKit
import CharkleCore
import CoreGraphics
import Metal
import MetalKit
import SwiftUI

// MARK: - GPU Uniform Layout (Strictly 16-byte SIMD4 Aligned, Identical in Swift & MSL)

private struct RingCardGPUUniforms {
    var geom0: SIMD4<Float>     // x: arcS, y: curvatureC, z: perspectiveP, w: cardWidth
    var geom1: SIMD4<Float>     // x: cardHeight, y: cornerRadius, z: pressScale, w: radiusR
    var screen0: SIMD4<Float>   // x: minSX, y: maxSX, z: blurPad, w: depthBlurMax
    var screen1: SIMD4<Float>   // x: farFadeMax, y: halfViewportW, z: halfViewportH, w: retinaScale
    var media: SIMD4<Float>     // x: imageAspect, y: hasTexture, z: flipTexX, w: uMin
    var slice: SIMD4<Float>     // x: uMax, y: isFarSide, z: verticalOffsetPt, w: cardScale
    var bgColor: SIMD4<Float>   // rgba of page ground
    var tintColor: SIMD4<Float> // rgba fallback placeholder color while decoding
    var extra: SIMD4<Float>     // x: sharpHalfPt, y: seamAlpha, z: 0, w: 0
}

// MARK: - Runtime-Compiled Metal Shaders (96-Column Curved Strip + Superellipse-4 + Zero-Shimmer DoF)

private let ringGalleryMSLSource = """
#include <metal_stdlib>
using namespace metal;

struct RingCardUniforms {
    float4 geom0;     // x: arcS, y: curvatureC, z: perspectiveP, w: cardWidth
    float4 geom1;     // x: cardHeight, y: cornerRadius, z: pressScale, w: radiusR
    float4 screen0;   // x: minSX, y: maxSX, z: blurPad, w: depthBlurMax
    float4 screen1;   // x: farFadeMax, y: halfViewportW, z: halfViewportH, w: retinaScale
    float4 media;     // x: imageAspect, y: hasTexture, z: flipTexX, w: uMin
    float4 slice;     // x: uMax, y: isFarSide, z: verticalOffsetPt, w: cardScale
    float4 bgColor;   // page background RGB
    float4 tintColor; // placeholder RGB while texture decodes
    float4 extra;     // x: sharpHalfPt, y: seamAlpha, z: 0, w: 0
};

struct RingVertexOut {
    float4 position [[position]];
    float2 screenPos;
    float2 localPos;
    float cardHalfH;
    float worldZ;
};

vertex RingVertexOut ring_card_vertex(
    uint vid [[vertex_id]],
    constant RingCardUniforms &u [[buffer(0)]]
) {
    // 96 interior vertical columns + 1 margin column on each side = 99 column stations (198 vertices)
    const uint kInteriorSegments = 96;
    uint col = vid / 2;
    float isTop = (vid % 2 == 0) ? 1.0 : -1.0;

    float pressScale = u.geom1.z;
    float cardW = u.geom0.w;
    float cardH = u.geom1.x;
    float uMin = u.media.w * pressScale;
    float uMax = u.slice.x * pressScale;
    float pad = u.screen0.z;
    float cardScale = u.slice.w;

    float colT = clamp((float(col) - 1.0) / float(kInteriorSegments), 0.0, 1.0);
    float uArc = mix(uMin, uMax, colT);

    float sCol = u.geom0.x + uArc;
    float c = u.geom0.y;
    float a = sCol * c;
    float x = (abs(c) < 1e-6) ? sCol : (sin(a) / c);
    float z = (abs(c) < 1e-6) ? 0.0  : ((1.0 - cos(a)) / c);

    float P = u.geom0.z;
    float depth = max(140.0, P - z);
    float proj = (P / depth) * cardScale;

    float sx = x * proj;
    float halfScreenH = (cardH * 0.5 * pressScale) * proj;

    // Extrude outer margin columns in screen space so blurred edges always have full room
    float dir = (u.slice.y > 0.5) ? -1.0 : 1.0;
    float localX = uArc / max(1e-4, pressScale);
    float cosSlope = max(0.08, abs(cos(a)));

    if (col == 0) {
        sx -= dir * pad;
        localX -= pad / max(1e-4, cosSlope * proj * pressScale);
    } else if (col == kInteriorSegments + 2) {
        sx += dir * pad;
        localX += pad / max(1e-4, cosSlope * proj * pressScale);
    }

    float syRel = isTop * (halfScreenH + pad);
    float sy = syRel + u.slice.z;
    float localY = isTop * (cardH * 0.5 + pad / max(1e-4, proj * pressScale));

    RingVertexOut out;
    out.position = float4(sx / max(1.0, u.screen1.y), sy / max(1.0, u.screen1.z), 0.0, 1.0);
    out.screenPos = float2(sx, syRel);
    out.localPos = float2(localX, localY);
    out.cardHalfH = halfScreenH;
    out.worldZ = z;
    return out;
}

fragment float4 ring_card_fragment(
    RingVertexOut in [[stage_in]],
    constant RingCardUniforms &u [[buffer(0)]],
    texture2d<float> cardTex [[texture(0)]],
    sampler texSampler [[sampler(0)]]
) {
    // 1. Per-pixel depth-of-field blur radius (screen points), adapting sharp inner zone to front card width
    float halfW = max(120.0, u.screen1.y);
    float sharpHalf = max(48.0, min(halfW - 12.0, u.extra.x));
    float back = clamp(-in.worldZ / (2.0 * max(1.0, u.geom1.w)), 0.0, 1.0);
    float sideBlur = u.screen0.w * pow(smoothstep(sharpHalf, halfW, abs(in.screenPos.x)), 1.4);
    float depthBlur = u.screen0.w * pow(smoothstep(0.25, 0.8, back), 1.2);
    float b = max(sideBlur, depthBlur);
    float bEff = max(b, 0.75);

    // 2. Analytical screen-space box blur edge coverage (thin cards fade naturally, never shimmer)
    float dl = in.screenPos.x - u.screen0.x;
    float dr = u.screen0.y - in.screenPos.x;
    float dt = in.cardHalfH - in.screenPos.y;
    float db = in.screenPos.y + in.cardHalfH;

    float across = clamp((min(dl, bEff) + min(dr, bEff)) / (2.0 * bEff), 0.0, 1.0);
    float down   = clamp((min(dt, bEff) + min(db, bEff)) / (2.0 * bEff), 0.0, 1.0);
    float boxAlpha = smoothstep(0.0, 1.0, across) * smoothstep(0.0, 1.0, down);

    // 3. Superellipse exponent-4 continuous corner SDF softened by exact screen-space blur bEff
    float2 halfCard = float2(u.geom0.w * 0.5, u.geom1.x * 0.5);
    float r = min(u.geom1.y, min(halfCard.x, halfCard.y));
    float2 d = abs(in.localPos) - halfCard + r;
    float2 m = max(d, float2(0.0));
    float distLocal = pow(pow(m.x, 4.0) + pow(m.y, 4.0), 0.25) + min(max(d.x, d.y), 0.0) - r;

    float gradPerPoint = max(1e-4, length(float2(dfdx(distLocal), dfdy(distLocal))) * u.screen1.w);
    float distScreenPt = distLocal / gradPerPoint;
    float cornerAlpha = smoothstep(bEff, -bEff, distScreenPt);

    float alpha = min(boxAlpha, cornerAlpha) * u.extra.y;
    if (alpha < 0.002) {
        discard_fragment();
    }

    // 4. Aspect-fill (cover) UV + hardware mipmap blur proportional to b * texelsPerScreenPoint
    float2 uv = float2(
        clamp(in.localPos.x / u.geom0.w + 0.5, 0.0, 1.0),
        clamp(0.5 - in.localPos.y / u.geom1.x, 0.0, 1.0)
    );
    if (u.media.z > 0.5) {
        uv.x = 1.0 - uv.x;
    }

    float cardAspect = u.geom0.w / u.geom1.x;
    float imgAspect = max(0.05, u.media.x);
    float2 coverUV = uv;
    if (imgAspect > cardAspect) {
        float scaleX = cardAspect / imgAspect;
        coverUV.x = (uv.x - 0.5) * scaleX + 0.5;
    } else {
        float scaleY = imgAspect / cardAspect;
        coverUV.y = (uv.y - 0.5) * scaleY + 0.5;
    }

    float3 rgb;
    if (u.media.y > 0.5) {
        float2 texSize = float2(float(cardTex.get_width()), float(cardTex.get_height()));
        float2 dUVdx = dfdx(coverUV) * texSize * u.screen1.w;
        float2 dUVdy = dfdy(coverUV) * texSize * u.screen1.w;
        float texelsPerPoint = max(length(dUVdx), length(dUVdy));
        float baseLod = log2(max(1.0, texelsPerPoint / max(1.0, u.screen1.w)));
        float blurLod = log2(max(1.0, b * texelsPerPoint * 0.92));
        float lod = max(baseLod, blurLod);
        rgb = cardTex.sample(texSampler, coverUV, level(lod)).rgb;
    } else {
        rgb = u.tintColor.rgb;
    }

    // 5. Far-side fade cleanly toward the current Light/Dark page ground (zero shadow / zero dirty grey)
    float fadeAmt = u.screen1.x * smoothstep(0.3, 1.0, back);
    rgb = mix(rgb, u.bgColor.rgb, fadeAmt);

    return float4(rgb * alpha, alpha);
}
"""

// MARK: - GPU Mipmapped Texture Pool (Bounded 48-Slot LRU, Purged on Dismantle)

private final class RingTextureEntry {
    let texture: MTLTexture
    let aspect: Float
    let isFullPreview: Bool
    var lastUsedTick: UInt64

    init(texture: MTLTexture, aspect: Float, isFullPreview: Bool, tick: UInt64) {
        self.texture = texture
        self.aspect = aspect
        self.isFullPreview = isFullPreview
        self.lastUsedTick = tick
    }
}

private nonisolated struct RingRasterizedBitmap: Sendable {
    let data: Data
    let width: Int
    let height: Int
    let aspect: Float
}

private final class RingTexturePool {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let loader: ThumbnailImageLoader
    private let maxEntries: Int = 48

    private var entries: [UUID: RingTextureEntry] = [:]
    private var loadingTasks: [UUID: Task<Void, Never>] = [:]
    private var settledPreviewIDs: Set<UUID> = []
    private var generation: UInt64 = 0
    private var tick: UInt64 = 0
    var isDarkMode: Bool = false
    var onTextureReady: (() -> Void)?

    init(device: MTLDevice, commandQueue: MTLCommandQueue, loader: ThumbnailImageLoader) {
        self.device = device
        self.commandQueue = commandQueue
        self.loader = loader
    }

    func texture(for asset: AssetRecord) -> (MTLTexture, Float)? {
        tick &+= 1
        if let hit = entries[asset.id] {
            hit.lastUsedTick = tick
            if !hit.isFullPreview && loadingTasks[asset.id] == nil && !settledPreviewIDs.contains(asset.id) {
                requestAsync(asset: asset, onlyUpgradePreview: true)
            }
            return (hit.texture, hit.aspect)
        }
        requestAsync(asset: asset, onlyUpgradePreview: false)
        return nil
    }

    func prefetch(assets: [AssetRecord]) {
        for asset in assets {
            if let existing = entries[asset.id] {
                if !existing.isFullPreview && loadingTasks[asset.id] == nil && !settledPreviewIDs.contains(asset.id) {
                    requestAsync(asset: asset, onlyUpgradePreview: true)
                }
                continue
            }
            if loadingTasks[asset.id] != nil { continue }
            requestAsync(asset: asset, onlyUpgradePreview: false)
        }
    }

    func purgeAll() {
        generation &+= 1
        for task in loadingTasks.values { task.cancel() }
        loadingTasks.removeAll()
        entries.removeAll()
        settledPreviewIDs.removeAll()
    }

    private func requestAsync(asset: AssetRecord, onlyUpgradePreview: Bool) {
        let assetID = asset.id
        guard loadingTasks[assetID] == nil else { return }
        let loader = self.loader
        let targetGen = self.generation
        let darkMode = self.isDarkMode

        loadingTasks[assetID] = Task { @MainActor [weak self] in
            defer { self?.loadingTasks.removeValue(forKey: assetID) }

            // 1. Immediate cached preview1400 fast path (rasterized off-main-thread)
            if let cachedFull = loader.cachedCGImage(for: assetID, tier: .preview1400) {
                if let bmp = await Self.rasterizeOffMain(cgImage: cachedFull) {
                    guard !Task.isCancelled, let self, self.generation == targetGen else { return }
                    self.settledPreviewIDs.insert(assetID)
                    if self.upload(bitmap: bmp, assetID: assetID, isFullPreview: true) != nil {
                        self.onTextureReady?()
                    }
                    return
                }
            }

            // 2. Provisional cached grid520 pass so already-warm Masonry cards appear instantly
            //    while preview1400 upgrades seamlessly in the background.
            var hasProvisional = onlyUpgradePreview
            if !onlyUpgradePreview, let cachedGrid = loader.cachedCGImage(for: assetID, tier: .grid520) {
                if let bmp = await Self.rasterizeOffMain(cgImage: cachedGrid) {
                    guard !Task.isCancelled, let self, self.generation == targetGen else { return }
                    if self.upload(bitmap: bmp, assetID: assetID, isFullPreview: false) != nil {
                        hasProvisional = true
                        self.onTextureReady?()
                    }
                }
            }

            // 3. Async full preview1400 upgrade
            if let fullCG = await loader.loadCGImage(for: assetID, tier: .preview1400) {
                if let bmp = await Self.rasterizeOffMain(cgImage: fullCG) {
                    guard !Task.isCancelled, let self, self.generation == targetGen else { return }
                    self.settledPreviewIDs.insert(assetID)
                    if self.upload(bitmap: bmp, assetID: assetID, isFullPreview: true) != nil {
                        self.onTextureReady?()
                    }
                    return
                }
            }

            guard !Task.isCancelled, let self, self.generation == targetGen else { return }
            self.settledPreviewIDs.insert(assetID)

            // 4. Fallback to grid520 if preview1400 unavailable
            if !hasProvisional, let gridCG = await loader.loadCGImage(for: assetID, tier: .grid520) {
                if let bmp = await Self.rasterizeOffMain(cgImage: gridCG) {
                    guard !Task.isCancelled, self.generation == targetGen else { return }
                    if self.upload(bitmap: bmp, assetID: assetID, isFullPreview: true) != nil {
                        self.onTextureReady?()
                    }
                    return
                }
            }

            // 5. Procedural card texture for non-raster assets (audio, swatch, docs, bookmarks without thumb)
            if !hasProvisional, let procCG = Self.renderProceduralCard(for: asset, isDark: darkMode) {
                if let bmp = await Self.rasterizeOffMain(cgImage: procCG) {
                    guard !Task.isCancelled, self.generation == targetGen else { return }
                    if self.upload(bitmap: bmp, assetID: assetID, isFullPreview: true) != nil {
                        self.onTextureReady?()
                    }
                }
            }
        }
    }

    @concurrent
    private static func rasterizeOffMain(cgImage: CGImage) async -> RingRasterizedBitmap? {
        guard !Task.isCancelled else { return nil }
        let maxSide = 768
        let srcW = max(1, cgImage.width)
        let srcH = max(1, cgImage.height)
        let aspect = Float(srcW) / Float(srcH)

        let scale = min(1.0, Double(maxSide) / Double(max(srcW, srcH)))
        let dstW = max(2, Int((Double(srcW) * scale).rounded()))
        let dstH = max(2, Int((Double(srcH) * scale).rounded()))

        let bytesPerRow = dstW * 4
        var raw = Data(count: bytesPerRow * dstH)
        let rendered: Bool = raw.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return false }
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            guard let ctx = CGContext(
                data: base,
                width: dstW,
                height: dstH,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
            return true
        }
        guard rendered else { return nil }
        return RingRasterizedBitmap(data: raw, width: dstW, height: dstH, aspect: aspect)
    }

    private static func renderProceduralCard(for asset: AssetRecord, isDark: Bool) -> CGImage? {
        let aspect = RingGalleryMath.effectiveAspectRatio(for: asset)
        let height: CGFloat = 480
        let width: CGFloat = max(240, min(720, (height * CGFloat(aspect)).rounded()))
        let size = CGSize(width: width, height: height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.current = prev }

        let bounds = CGRect(origin: .zero, size: size)
        let primaryHex = asset.dominantColors.first?.hex ?? (isDark ? "#2B2F36" : "#DCDAD4")
        let isSwatch = asset.fileName.lowercased().hasSuffix(".swatch")
        let elevated = isDark ? NSColor.charkleHex("#1E2024") : NSColor.white
        let primaryText: NSColor = isDark ? NSColor.white.withAlphaComponent(0.92) : NSColor.black.withAlphaComponent(0.86)
        let secondaryText: NSColor = isDark ? NSColor.white.withAlphaComponent(0.56) : NSColor.black.withAlphaComponent(0.54)

        if isSwatch {
            NSColor.charkleHex(primaryHex).setFill()
            ctx.fill(bounds)
            let isLight = Color.charkleIsLightHex(primaryHex)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 24, weight: .semibold),
                .foregroundColor: isLight ? NSColor.black.withAlphaComponent(0.84) : NSColor.white.withAlphaComponent(0.92)
            ]
            (primaryHex.uppercased() as NSString).draw(at: CGPoint(x: 24, y: bounds.height - 58), withAttributes: attrs)
        } else {
            elevated.setFill()
            ctx.fill(bounds)
            let accent = NSColor.charkleHex(primaryHex)
            accent.withAlphaComponent(0.85).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 6))

            if asset.mediaKind == .audio {
                let peaks: [Float] = asset.waveformPeaks.isEmpty
                    ? (0..<32).map { i in Float(0.22 + 0.65 * sin(Double(i) / 31.0 * .pi)) }
                    : asset.waveformPeaks
                let barCount = min(peaks.count, 32)
                let barW: CGFloat = 6
                let gap = max(4, (bounds.width - 56 - CGFloat(barCount) * barW) / CGFloat(max(1, barCount - 1)))
                let midY = bounds.height * 0.48
                let maxH = bounds.height * 0.34
                for i in 0..<barCount {
                    let amp = max(0.16, min(1.0, CGFloat(peaks[i * peaks.count / max(1, barCount)])))
                    let h = max(10, maxH * amp)
                    let rect = CGRect(x: 28 + CGFloat(i) * (barW + gap), y: midY - h * 0.5, width: barW, height: h)
                    accent.withAlphaComponent(0.55 + amp * 0.45).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                }
            }

            let badge: String = switch asset.mediaKind {
            case .audio: "AUDIO"
            case .model3D: "3D · \(asset.richMetadata?.model3DFormat ?? "MODEL")"
            case .webBookmark:
                asset.isGitHubRepo ? "GITHUB" : (asset.richMetadata?.socialPost?.platform.displayName.uppercased() ?? asset.sourceDomain ?? "WEB")
            default:
                CanvasFormatters.fileExtensionBadge(for: asset.fileName)
            }
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .bold),
                .foregroundColor: secondaryText
            ]
            (badge as NSString).draw(at: CGPoint(x: 28, y: 28), withAttributes: badgeAttrs)

            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
                .foregroundColor: primaryText,
                .paragraphStyle: para
            ]
            (asset.title as NSString).draw(
                in: CGRect(x: 28, y: bounds.height - 96, width: bounds.width - 56, height: 72),
                withAttributes: titleAttrs
            )
        }
        return ctx.makeImage()
    }

    private func upload(bitmap: RingRasterizedBitmap, assetID: UUID, isFullPreview: Bool) -> RingTextureEntry? {
        let dstW = bitmap.width
        let dstH = bitmap.height
        let bytesPerRow = dstW * 4

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: dstW,
            height: dstH,
            mipmapped: true
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }

        bitmap.data.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                tex.replace(
                    region: MTLRegionMake2D(0, 0, dstW, dstH),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: bytesPerRow
                )
            }
        }

        if let cmd = commandQueue.makeCommandBuffer(),
           let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cmd.commit()
        }

        tick &+= 1
        let entry = RingTextureEntry(texture: tex, aspect: bitmap.aspect, isFullPreview: isFullPreview, tick: tick)
        entries[assetID] = entry
        evictIfNeeded()
        return entry
    }

    private func evictIfNeeded() {
        guard entries.count > maxEntries else { return }
        let sorted = entries.sorted { $0.value.lastUsedTick < $1.value.lastUsedTick }
        let removeCount = entries.count - maxEntries
        for (id, _) in sorted.prefix(removeCount) {
            entries.removeValue(forKey: id)
        }
    }
}

// MARK: - Interactive Metal MTKView Subclass (Zero Idle CPU, Drag/Scroll/Click/Press Physics)

public struct RingGalleryInteractionCallbacks {
    public var onFrontAssetChanged: (AssetRecord?) -> Void
    public var onOpenQuickLook: (AssetRecord) -> Void
    public var onContextMenuRequest: (AssetRecord, NSView, NSPoint) -> Void

    public init(
        onFrontAssetChanged: @escaping (AssetRecord?) -> Void,
        onOpenQuickLook: @escaping (AssetRecord) -> Void,
        onContextMenuRequest: @escaping (AssetRecord, NSView, NSPoint) -> Void = { _, _, _ in }
    ) {
        self.onFrontAssetChanged = onFrontAssetChanged
        self.onOpenQuickLook = onOpenQuickLook
        self.onContextMenuRequest = onContextMenuRequest
    }
}

public final class RingGalleryMTKView: MTKView, MTKViewDelegate {
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    private var fallbackWhiteTex: MTLTexture?
    private var texturePool: RingTexturePool?

    private var assets: [AssetRecord] = []
    private var params: RingGalleryParameters = .default
    private var isDarkMode: Bool = false
    private var reduceMotion: Bool = false
    private var isOverlayPresented: Bool = false
    private var topSafeInset: CGFloat = 64
    private var loaderInvalidationVersion: Int = -1
    private var callbacks: RingGalleryInteractionCallbacks?

    // Continuous arc offset (px along the ring)
    private var offset: Double = 0
    private var cardTrack: RingCardTrack = RingCardTrack(cardWidths: [], cardHeight: 300, cardGap: 18)
    private var lastReportedFrontAssetID: UUID?
    private var frontReportGeneration: UInt64 = 0
    private var lastRenderedDrawableSize: CGSize = .zero

    // Cubic-bezier offset animation
    private struct OffsetAnim {
        let from: Double
        let to: Double
        let startTime: CFTimeInterval
        let duration: Double
        let curve: RingCubicBezier
    }
    private var offsetAnim: OffsetAnim?

    // Per-card press animation (0.95 in 140ms, back to 1.0 in 320ms)
    private struct PressAnim {
        var virtualIndex: Int
        var fromScale: Double
        var toScale: Double
        var startTime: CFTimeInterval
        var duration: Double
        var curve: RingCubicBezier
    }
    private var pressAnim: PressAnim?
    private var pressedVirtualIndex: Int?

    // Pointer drag & velocity tracking
    private var isDragging: Bool = false
    private var dragStartWindowX: CGFloat = 0
    private var dragLastWindowX: CGFloat = 0
    private var dragStartOffset: Double = 0
    private var dragMovedTotal: CGFloat = 0
    private var velocitySamples: [(time: CFTimeInterval, x: CGFloat)] = []

    // Trackpad scroll settle timer
    private var scrollSnapWorkItem: DispatchWorkItem?
    private var lastProjectedCards: [RingProjectedCard] = []

    private var keyMonitor: Any?

    public init(loader: ThumbnailImageLoader) {
        let dev = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: dev)

        self.delegate = self
        self.colorPixelFormat = .bgra8Unorm
        self.framebufferOnly = true
        self.enableSetNeedsDisplay = true
        self.isPaused = true
        self.preferredFramesPerSecond = 120
        self.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        self.layer?.isOpaque = true
        self.layer?.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "frame": NSNull(),
            "contents": NSNull()
        ]
        (self.layer as? CAMetalLayer)?.presentsWithTransaction = true

        if let dev, let queue = dev.makeCommandQueue() {
            self.commandQueue = queue
            setupPipeline(device: dev)
            let pool = RingTexturePool(device: dev, commandQueue: queue, loader: loader)
            pool.onTextureReady = { [weak self] in
                self?.requestFrame()
            }
            self.texturePool = pool
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        teardown()
    }

    public func teardown() {
        scrollSnapWorkItem?.cancel()
        scrollSnapWorkItem = nil
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        isPaused = true
        texturePool?.purgeAll()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installKeyMonitorIfNeeded()
            requestFrame()
        } else {
            scrollSnapWorkItem?.cancel()
            scrollSnapWorkItem = nil
            isDragging = false
            isPaused = true
            enableSetNeedsDisplay = true
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func layout() {
        super.layout()
        // `super.layout()` updates `drawableSize` and invokes `mtkView(_:drawableSizeWillChange:)`,
        // which already draws atomically for the new size. Only schedule a redraw if drawableSize
        // did not just render (avoids 2x synchronous waitUntilScheduled() stalls per resize frame).
        if bounds.width > 4, bounds.height > 4, drawableSize != lastRenderedDrawableSize {
            requestFrame()
        }
    }

    private func currentLayoutMetrics() -> (cardScale: Double, verticalBiasPt: Double) {
        let cardScale = RingGalleryMath.adaptiveCardScale(
            viewportSize: bounds.size,
            topSafeInset: Double(topSafeInset),
            bottomSafeInset: 72.0,
            params: params
        )
        let verticalBias = RingGalleryMath.verticalCenterBias(
            topSafeInset: Double(topSafeInset),
            bottomSafeInset: 72.0
        )
        return (cardScale, verticalBias)
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.isOverlayPresented, let hostWindow = self.window, event.window === hostWindow else { return event }
            guard hostWindow.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
            if let resp = hostWindow.firstResponder,
               resp is NSTextView || resp is NSTextField || resp is NSText {
                return event
            }
            let primaryModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard primaryModifiers.isEmpty else { return event }
            switch event.keyCode {
            case 123: // Left arrow
                self.step(by: -1)
                return nil
            case 124: // Right arrow
                self.step(by: 1)
                return nil
            default:
                return event
            }
        }
    }

    private func setupPipeline(device: MTLDevice) {
        do {
            let library = try device.makeLibrary(source: ringGalleryMSLSource, options: nil)
            guard let vfn = library.makeFunction(name: "ring_card_vertex"),
                  let ffn = library.makeFunction(name: "ring_card_fragment") else { return }

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].rgbBlendOperation = .add
            desc.colorAttachments[0].alphaBlendOperation = .add
            desc.colorAttachments[0].sourceRGBBlendFactor = .one
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            self.pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            // Non-fatal fallback; MTKView simply stays clear ground
        }

        let sDesc = MTLSamplerDescriptor()
        sDesc.minFilter = .linear
        sDesc.magFilter = .linear
        sDesc.mipFilter = .linear
        sDesc.sAddressMode = .clampToEdge
        sDesc.tAddressMode = .clampToEdge
        self.samplerState = device.makeSamplerState(descriptor: sDesc)

        // 1x1 fallback white texture so fragment texture binding is always valid
        let tDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        if let tex = device.makeTexture(descriptor: tDesc) {
            var px: [UInt8] = [235, 235, 232, 255]
            tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
            self.fallbackWhiteTex = tex
        }
    }

    // MARK: - External State Sync

    public func configure(
        assets: [AssetRecord],
        selectedAssetID: UUID?,
        params: RingGalleryParameters,
        isDarkMode: Bool,
        reduceMotion: Bool,
        isOverlayPresented: Bool,
        topSafeInset: CGFloat,
        loaderInvalidationVersion: Int = 0,
        callbacks: RingGalleryInteractionCallbacks
    ) {
        let oldAssetIDs = self.assets.map(\.id)
        let newAssetIDs = assets.map(\.id)
        let listChanged = oldAssetIDs != newAssetIDs

        let oldParams = self.params
        let newTrack = RingCardTrack.build(from: assets, params: params)
        let trackGeometryChanged = newTrack != self.cardTrack
        let darkModeChanged = (self.isDarkMode != isDarkMode)
        let invalidationChanged = (self.loaderInvalidationVersion != -1 && self.loaderInvalidationVersion != loaderInvalidationVersion)
        let appearanceChanged = darkModeChanged
            || (self.topSafeInset != topSafeInset)
            || (oldParams != params)
            || trackGeometryChanged
            || invalidationChanged

        let previousFrontVirtual = cardTrack.isEmpty ? 0 : cardTrack.nearestVirtualIndex(to: offset)

        self.assets = assets
        self.params = params
        self.cardTrack = newTrack
        self.isDarkMode = isDarkMode
        self.reduceMotion = reduceMotion
        self.isOverlayPresented = isOverlayPresented
        self.topSafeInset = topSafeInset
        self.loaderInvalidationVersion = loaderInvalidationVersion
        self.callbacks = callbacks
        texturePool?.isDarkMode = isDarkMode

        if invalidationChanged || darkModeChanged {
            texturePool?.purgeAll()
        }

        if listChanged {
            offsetAnim = nil
            pressAnim = nil
            if let selectedAssetID, let idx = assets.firstIndex(where: { $0.id == selectedAssetID }) {
                offset = cardTrack.centerArc(forVirtualIndex: idx)
            } else {
                offset = 0
            }
            reportFrontAssetIfChanged(force: true, deferCallback: true)
            prefetchAroundCurrentOffset()
            requestFrame()
        } else {
            if trackGeometryChanged && !isDragging && offsetAnim == nil && !cardTrack.isEmpty {
                // Keep the exact same card centered if an asset's natural aspect dimensions refreshed.
                offset = cardTrack.centerArc(forVirtualIndex: previousFrontVirtual)
            }
            if let selectedAssetID,
               selectedAssetID != lastReportedFrontAssetID,
               !isDragging,
               offsetAnim == nil,
               let idx = assets.firstIndex(where: { $0.id == selectedAssetID }) {
                // External selection change (e.g., clicked Similar item in Inspector) -> glide shortest path
                rotateToAssetIndex(idx, duration: reduceMotion ? 0.18 : 0.76)
            }
        }

        if oldParams != params {
            // Moving any live tuning slider stops ongoing demo/glide motion and updates immediately
            offsetAnim = nil
            requestFrame()
        } else if appearanceChanged {
            if invalidationChanged || darkModeChanged {
                prefetchAroundCurrentOffset()
            }
            requestFrame()
        }
    }

    public func step(by delta: Int) {
        guard !assets.isEmpty, !cardTrack.isEmpty else { return }
        let baseIdx: Int
        if let anim = offsetAnim {
            baseIdx = cardTrack.nearestVirtualIndex(to: anim.to)
        } else {
            baseIdx = cardTrack.nearestVirtualIndex(to: offset)
        }
        var targetIdx = baseIdx + delta
        if assets.count <= 3 {
            targetIdx = max(0, min(assets.count - 1, targetIdx))
        }
        let targetOffset = cardTrack.centerArc(forVirtualIndex: targetIdx)
        startOffsetAnimation(to: targetOffset, duration: reduceMotion ? 0.16 : 0.56)
    }

    private func rotateToAssetIndex(_ targetAssetIdx: Int, duration: Double) {
        guard !assets.isEmpty, !cardTrack.isEmpty else { return }
        let currentVirtual = cardTrack.nearestVirtualIndex(to: offset)
        let currentAsset = RingGalleryMath.positiveMod(currentVirtual, count: assets.count)
        var delta = targetAssetIdx - currentAsset
        if assets.count > 3 {
            let half = assets.count / 2
            if delta > half { delta -= assets.count }
            if delta < -half { delta += assets.count }
        }
        let targetVirtual = currentVirtual + delta
        startOffsetAnimation(to: cardTrack.centerArc(forVirtualIndex: targetVirtual), duration: duration)
    }

    private func startOffsetAnimation(to target: Double, duration: Double) {
        let clampedDuration = reduceMotion ? min(0.20, duration) : duration
        offsetAnim = OffsetAnim(
            from: offset,
            to: target,
            startTime: CACurrentMediaTime(),
            duration: max(0.05, clampedDuration),
            curve: .dragGlide
        )
        startAnimating()
    }

    private func startPressAnimation(virtualIndex: Int, toScale: Double, duration: Double, curve: RingCubicBezier) {
        let current = currentPressScale(for: virtualIndex, now: CACurrentMediaTime())
        pressAnim = PressAnim(
            virtualIndex: virtualIndex,
            fromScale: current,
            toScale: toScale,
            startTime: CACurrentMediaTime(),
            duration: reduceMotion ? 0.05 : duration,
            curve: curve
        )
        startAnimating()
    }

    private func currentPressScale(for virtualIndex: Int, now: CFTimeInterval) -> Double {
        guard let anim = pressAnim, anim.virtualIndex == virtualIndex else { return 1.0 }
        let t = RingGalleryMath.clamp((now - anim.startTime) / max(0.001, anim.duration), 0.0, 1.0)
        let eased = anim.curve.evaluate(t)
        return anim.fromScale + (anim.toScale - anim.fromScale) * eased
    }

    private func startAnimating() {
        (self.layer as? CAMetalLayer)?.presentsWithTransaction = false
        enableSetNeedsDisplay = false
        isPaused = false
    }

    private func stopAnimatingIfSettled(now: CFTimeInterval) {
        let hasOffsetAnim = offsetAnim != nil
        let hasPressAnim: Bool = {
            guard let p = pressAnim else { return false }
            return (now - p.startTime) < p.duration
        }()
        if !hasOffsetAnim && !hasPressAnim && !isDragging {
            isPaused = true
            enableSetNeedsDisplay = true
            (self.layer as? CAMetalLayer)?.presentsWithTransaction = true
        }
    }

    public func requestFrame() {
        if isPaused {
            enableSetNeedsDisplay = true
            setNeedsDisplay(bounds)
        }
    }

    // MARK: - Pointer Drag, Click-to-Center, Double-Click Quick Look, Context Menu & Scroll

    private func screenCoordinates(from event: NSEvent) -> (sx: Double, sy: Double) {
        let local = convert(event.locationInWindow, from: nil)
        let sx = Double(local.x - bounds.midX)
        let (_, verticalBias) = currentLayoutMetrics()
        let sy = Double(local.y - bounds.midY) - verticalBias
        return (sx, sy)
    }

    private func hitTestCard(at event: NSEvent) -> RingProjectedCard? {
        let (sx, sy) = screenCoordinates(from: event)
        // Test front-to-back (reverse of painter's order)
        for card in lastProjectedCards.reversed() {
            if card.contains(screenX: sx, screenY: sy) {
                return card
            }
        }
        return nil
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        offsetAnim = nil
        scrollSnapWorkItem?.cancel()

        isDragging = true
        dragStartWindowX = event.locationInWindow.x
        dragLastWindowX = dragStartWindowX
        dragStartOffset = offset
        dragMovedTotal = 0
        velocitySamples = [(CACurrentMediaTime(), dragStartWindowX)]

        if let hit = hitTestCard(at: event) {
            pressedVirtualIndex = hit.virtualIndex
            startPressAnimation(virtualIndex: hit.virtualIndex, toScale: 0.95, duration: 0.140, curve: .pressIn)
        } else {
            pressedVirtualIndex = nil
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let x = event.locationInWindow.x
        let dx = x - dragLastWindowX
        dragLastWindowX = x
        dragMovedTotal += abs(dx)

        if dragMovedTotal > 4, let pv = pressedVirtualIndex {
            pressedVirtualIndex = nil
            startPressAnimation(virtualIndex: pv, toScale: 1.0, duration: 0.320, curve: .pressOut)
        }

        // 1:1 pointer follow in screen points (compensated by live adaptive cardScale)
        let (cardScale, _) = currentLayoutMetrics()
        let arcDelta = Double(x - dragStartWindowX) / max(0.25, cardScale)
        offset = dragStartOffset - arcDelta
        if assets.count <= 3, !cardTrack.isEmpty {
            let maxOff = cardTrack.centerArc(forVirtualIndex: max(0, assets.count - 1))
            offset = RingGalleryMath.clamp(offset, -params.step * 0.35, maxOff + params.step * 0.35)
        }

        let now = CACurrentMediaTime()
        velocitySamples.append((now, x))
        velocitySamples.removeAll { now - $0.time > 0.11 }

        reportFrontAssetIfChanged()
        prefetchAroundCurrentOffset()
        requestFrame()
    }

    public override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false

        let releasedPressed = pressedVirtualIndex
        pressedVirtualIndex = nil
        if let pv = releasedPressed {
            startPressAnimation(virtualIndex: pv, toScale: 1.0, duration: 0.320, curve: .pressOut)
        }

        if dragMovedTotal < 5 {
            // Tap / Click on a card
            if let hit = hitTestCard(at: event), !cardTrack.isEmpty {
                let frontVirtual = cardTrack.nearestVirtualIndex(to: offset)
                if hit.virtualIndex == frontVirtual {
                    if event.clickCount >= 2, hit.assetIndex < assets.count {
                        callbacks?.onOpenQuickLook(assets[hit.assetIndex])
                    } else {
                        // Snap tightly to exact center
                        startOffsetAnimation(to: cardTrack.centerArc(forVirtualIndex: frontVirtual), duration: 0.32)
                    }
                } else {
                    // Bring clicked side card to front center in 760ms
                    startOffsetAnimation(to: cardTrack.centerArc(forVirtualIndex: hit.virtualIndex), duration: 0.760)
                }
            } else if !cardTrack.isEmpty {
                let snappedIdx = cardTrack.nearestVirtualIndex(to: offset)
                startOffsetAnimation(to: cardTrack.centerArc(forVirtualIndex: snappedIdx), duration: 0.42)
            }
            return
        }

        // Compute release pointer velocity (arc units/s compensated by live cardScale)
        let now = CACurrentMediaTime()
        let (cardScale, _) = currentLayoutMetrics()
        var velocityScreen: Double = 0
        if let first = velocitySamples.first(where: { now - $0.time <= 0.10 }),
           let last = velocitySamples.last,
           last.time - first.time > 0.005 {
            velocityScreen = Double(last.x - first.x) / (last.time - first.time)
        }
        velocitySamples.removeAll()
        let velocityArc = velocityScreen / max(0.25, cardScale)

        var (target, duration) = RingGalleryMath.releaseGlide(
            offset: offset,
            velocityArcPerSec: velocityArc,
            track: cardTrack,
            reducedMotion: reduceMotion
        )
        if assets.count <= 3, !cardTrack.isEmpty {
            let maxOff = cardTrack.centerArc(forVirtualIndex: max(0, assets.count - 1))
            target = RingGalleryMath.clamp(target, 0, maxOff)
        }
        startOffsetAnimation(to: target, duration: duration)
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard let hit = hitTestCard(at: event), hit.assetIndex < assets.count else {
            super.rightMouseDown(with: event)
            return
        }
        let asset = assets[hit.assetIndex]
        let local = convert(event.locationInWindow, from: nil)
        callbacks?.onContextMenuRequest(asset, self, local)
    }

    public override func scrollWheel(with event: NSEvent) {
        guard !assets.isEmpty else { return }
        offsetAnim = nil
        scrollSnapWorkItem?.cancel()

        // Support both horizontal trackpad swipes AND vertical mouse wheel scrolling
        let (cardScale, _) = currentLayoutMetrics()
        let rawDelta: Double = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? Double(event.scrollingDeltaX)
            : Double(event.scrollingDeltaY)
        let scale: Double = event.hasPreciseScrollingDeltas ? 1.15 : 18.0
        offset -= (rawDelta * scale) / max(0.35, cardScale)

        if assets.count <= 3, !cardTrack.isEmpty {
            let maxOff = cardTrack.centerArc(forVirtualIndex: max(0, assets.count - 1))
            offset = RingGalleryMath.clamp(offset, -params.step * 0.25, maxOff + params.step * 0.25)
        }

        reportFrontAssetIfChanged()
        prefetchAroundCurrentOffset()
        requestFrame()

        // Snap cleanly to the nearest card once trackpad / wheel scroll settles
        let isEnded = event.momentumPhase == .ended || (event.phase == .ended && event.momentumPhase.isEmpty)
        let delay: TimeInterval = isEnded ? 0.04 : 0.16
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isDragging, !self.cardTrack.isEmpty else { return }
            let snapIdx = self.cardTrack.nearestVirtualIndex(to: self.offset)
            let snapped = self.cardTrack.centerArc(forVirtualIndex: snapIdx)
            if abs(snapped - self.offset) > 0.4 {
                self.startOffsetAnimation(to: snapped, duration: self.reduceMotion ? 0.15 : 0.42)
            }
        }
        scrollSnapWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func reportFrontAssetIfChanged(force: Bool = false, deferCallback: Bool = false) {
        let nextAsset: AssetRecord?
        if assets.isEmpty || cardTrack.isEmpty {
            nextAsset = nil
        } else {
            let vIdx = cardTrack.nearestVirtualIndex(to: offset)
            let frontIdx: Int = assets.count <= 3
                ? max(0, min(assets.count - 1, vIdx))
                : RingGalleryMath.positiveMod(vIdx, count: assets.count)
            nextAsset = assets[frontIdx]
        }
        guard force || nextAsset?.id != lastReportedFrontAssetID else { return }
        lastReportedFrontAssetID = nextAsset?.id
        frontReportGeneration &+= 1
        let gen = frontReportGeneration
        if deferCallback {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.frontReportGeneration == gen else { return }
                self.callbacks?.onFrontAssetChanged(nextAsset)
            }
        } else {
            callbacks?.onFrontAssetChanged(nextAsset)
        }
    }

    private func prefetchAroundCurrentOffset() {
        guard !assets.isEmpty, !cardTrack.isEmpty, let pool = texturePool else { return }
        let centerVirtual = cardTrack.nearestVirtualIndex(to: offset)
        let radiusSlots = min(assets.count, params.slotCount / 2 + 4)
        var batch: [AssetRecord] = []
        batch.reserveCapacity(radiusSlots * 2 + 1)
        var seen = Set<UUID>()
        for d in -radiusSlots...radiusSlots {
            let idx = RingGalleryMath.positiveMod(centerVirtual + d, count: assets.count)
            let asset = assets[idx]
            if seen.insert(asset.id).inserted {
                batch.append(asset)
            }
        }
        pool.prefetch(assets: batch)
    }

    // MARK: - MTKViewDelegate Render Pass

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.width > 4, size.height > 4 else { return }
        let metalLayer = self.layer as? CAMetalLayer
        let prevPresentWithTx = metalLayer?.presentsWithTransaction ?? false
        metalLayer?.presentsWithTransaction = true
        draw()
        // If a continuous CVDisplayLink animation is still running, restore async presentation for subsequent ticks.
        if !isPaused {
            metalLayer?.presentsWithTransaction = prevPresentWithTx
        }
    }

    public func draw(in view: MTKView) {
        guard bounds.width > 4, bounds.height > 4 else { return }
        let now = CACurrentMediaTime()

        // Step active offset glide
        if let anim = offsetAnim {
            let t = RingGalleryMath.clamp((now - anim.startTime) / anim.duration, 0.0, 1.0)
            let eased = anim.curve.evaluate(t)
            offset = anim.from + (anim.to - anim.from) * eased
            if t >= 1.0 {
                offset = anim.to
                offsetAnim = nil
                prefetchAroundCurrentOffset()
            }
            reportFrontAssetIfChanged(deferCallback: true)
        }

        // Clean up finished press animation
        if let pAnim = pressAnim, (now - pAnim.startTime) >= pAnim.duration {
            if abs(pAnim.toScale - 1.0) < 1e-4 {
                pressAnim = nil
            }
        }

        guard let pipelineState,
              let samplerState,
              let commandQueue,
              let fallbackWhiteTex,
              let passDesc = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            stopAnimatingIfSettled(now: now)
            return
        }

        // Exact CharkleTheme.galleryGround clear color (Light #F6F6F5 / Dark #141517)
        let bgRGB: SIMD4<Float> = isDarkMode
            ? SIMD4<Float>(0x14 / 255.0, 0x15 / 255.0, 0x17 / 255.0, 1.0)
            : SIMD4<Float>(0xF6 / 255.0, 0xF6 / 255.0, 0xF5 / 255.0, 1.0)

        passDesc.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(bgRGB.x),
            green: Double(bgRGB.y),
            blue: Double(bgRGB.z),
            alpha: 1.0
        )
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store

        guard let cmd = commandQueue.makeCommandBuffer(),
              let encoder = cmd.makeRenderCommandEncoder(descriptor: passDesc) else {
            stopAnimatingIfSettled(now: now)
            return
        }
        lastRenderedDrawableSize = drawableSize

        let viewportPts = bounds.size
        let retinaScale = Float(max(1.0, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0))
        let (cardScale, verticalBias) = currentLayoutMetrics()
        let verticalBiasPt = Float(verticalBias)

        let projected = RingGalleryMath.visibleOutsideCards(
            track: cardTrack,
            offset: offset,
            params: params,
            viewportSize: viewportPts,
            cardScale: cardScale,
            pressScaleForVirtualIndex: { [weak self] vIdx in
                self?.currentPressScale(for: vIdx, now: now) ?? 1.0
            }
        )
        lastProjectedCards = projected

        encoder.setRenderPipelineState(pipelineState)
        encoder.setCullMode(.none)
        encoder.setFragmentSamplerState(samplerState, index: 0)

        let halfW = Float(max(1.0, viewportPts.width * 0.5))
        let halfH = Float(max(1.0, viewportPts.height * 0.5))
        let effectiveBlur = Float(params.depthBlur * RingGalleryMath.clamp(cardScale, 0.72, 1.38))
        let blurPad = effectiveBlur + 4.0
        let frontCardW = cardTrack.interpolatedFrontCardWidth(at: offset)
        let sharpHalfPt = Float(min(Double(halfW) * 0.78, max(110.0, frontCardW * 0.54) * cardScale))

        for card in projected {
            guard card.assetIndex < assets.count else { continue }
            let asset = assets[card.assetIndex]
            let pScale = Float(currentPressScale(for: card.virtualIndex, now: now))

            let texResult = texturePool?.texture(for: asset)
            let activeTex = texResult?.0 ?? fallbackWhiteTex
            let imgAspect = texResult?.1 ?? Float(max(0.2, asset.aspectRatio))
            let hasTexture: Float = texResult != nil ? 1.0 : 0.0

            let placeholderRGB = Self.placeholderTint(for: asset, isDark: isDarkMode)

            var uniforms = RingCardGPUUniforms(
                geom0: SIMD4<Float>(Float(card.arcS), Float(params.curvature), Float(params.perspective), Float(card.cardWidth)),
                geom1: SIMD4<Float>(Float(params.cardHeight), Float(params.cornerRadius), pScale, Float(params.radius)),
                screen0: SIMD4<Float>(Float(card.minScreenX), Float(card.maxScreenX), blurPad, effectiveBlur),
                screen1: SIMD4<Float>(Float(params.farFade), halfW, halfH, retinaScale),
                media: SIMD4<Float>(imgAspect, hasTexture, card.isFarSide ? 1.0 : 0.0, Float(card.uMin)),
                slice: SIMD4<Float>(Float(card.uMax), card.isFarSide ? 1.0 : 0.0, verticalBiasPt, Float(cardScale)),
                bgColor: bgRGB,
                tintColor: placeholderRGB,
                extra: SIMD4<Float>(sharpHalfPt, Float(card.seamAlpha), 0.0, 0.0)
            )

            encoder.setVertexBytes(&uniforms, length: MemoryLayout<RingCardGPUUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RingCardGPUUniforms>.stride, index: 0)
            encoder.setFragmentTexture(activeTex, index: 0)
            // 96 interior columns + 2 margin columns = 99 column stations * 2 vertices = 198 vertices
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 198)
        }

        encoder.endEncoding()
        if (self.layer as? CAMetalLayer)?.presentsWithTransaction == true {
            cmd.commit()
            cmd.waitUntilScheduled()
            drawable.present()
        } else {
            cmd.present(drawable)
            cmd.commit()
        }

        stopAnimatingIfSettled(now: now)
    }

    private static func placeholderTint(for asset: AssetRecord, isDark: Bool) -> SIMD4<Float> {
        if let hex = asset.dominantColors.first?.hex {
            let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            if cleaned.count == 6, let val = UInt32(cleaned, radix: 16) {
                let r = Float((val >> 16) & 0xFF) / 255.0
                let g = Float((val >> 8) & 0xFF) / 255.0
                let b = Float(val & 0xFF) / 255.0
                // Gently soften placeholder toward neutral ground
                let base: Float = isDark ? 0.16 : 0.88
                return SIMD4<Float>(base * 0.72 + r * 0.28, base * 0.72 + g * 0.28, base * 0.72 + b * 0.28, 1.0)
            }
        }
        return isDark ? SIMD4<Float>(0.16, 0.17, 0.20, 1.0) : SIMD4<Float>(0.90, 0.90, 0.88, 1.0)
    }
}

// MARK: - SwiftUI Representable Bridge

public struct RingGalleryMetalSurface: NSViewRepresentable {
    public let assets: [AssetRecord]
    public let selectedAssetID: UUID?
    public let loader: ThumbnailImageLoader
    public let loaderInvalidationVersion: Int
    public let params: RingGalleryParameters
    public let isDarkMode: Bool
    public let reduceMotion: Bool
    public let isOverlayPresented: Bool
    public let topSafeInset: CGFloat
    public let stepTrigger: Int
    public let stepDirection: Int
    public let callbacks: RingGalleryInteractionCallbacks

    public init(
        assets: [AssetRecord],
        selectedAssetID: UUID?,
        loader: ThumbnailImageLoader,
        loaderInvalidationVersion: Int = 0,
        params: RingGalleryParameters,
        isDarkMode: Bool,
        reduceMotion: Bool,
        isOverlayPresented: Bool = false,
        topSafeInset: CGFloat,
        stepTrigger: Int = 0,
        stepDirection: Int = 0,
        callbacks: RingGalleryInteractionCallbacks
    ) {
        self.assets = assets
        self.selectedAssetID = selectedAssetID
        self.loader = loader
        self.loaderInvalidationVersion = loaderInvalidationVersion
        self.params = params
        self.isDarkMode = isDarkMode
        self.reduceMotion = reduceMotion
        self.isOverlayPresented = isOverlayPresented
        self.topSafeInset = topSafeInset
        self.stepTrigger = stepTrigger
        self.stepDirection = stepDirection
        self.callbacks = callbacks
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        var lastStepTrigger: Int = 0
    }

    public func makeNSView(context: Context) -> RingGalleryMTKView {
        let view = RingGalleryMTKView(loader: loader)
        view.configure(
            assets: assets,
            selectedAssetID: selectedAssetID,
            params: params,
            isDarkMode: isDarkMode,
            reduceMotion: reduceMotion,
            isOverlayPresented: isOverlayPresented,
            topSafeInset: topSafeInset,
            loaderInvalidationVersion: loaderInvalidationVersion,
            callbacks: callbacks
        )
        return view
    }

    public func updateNSView(_ nsView: RingGalleryMTKView, context: Context) {
        nsView.configure(
            assets: assets,
            selectedAssetID: selectedAssetID,
            params: params,
            isDarkMode: isDarkMode,
            reduceMotion: reduceMotion,
            isOverlayPresented: isOverlayPresented,
            topSafeInset: topSafeInset,
            loaderInvalidationVersion: loaderInvalidationVersion,
            callbacks: callbacks
        )
        if context.coordinator.lastStepTrigger != stepTrigger {
            context.coordinator.lastStepTrigger = stepTrigger
            if stepDirection != 0 {
                nsView.step(by: stepDirection)
            }
        }
    }

    public static func dismantleNSView(_ nsView: RingGalleryMTKView, coordinator: Coordinator) {
        nsView.teardown()
    }
}
