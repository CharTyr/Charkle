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
    // 1. Per-pixel depth-of-field blur radius (screen points)
    float halfW = max(120.0, u.screen1.y);
    float back = clamp(-in.worldZ / (2.0 * max(1.0, u.geom1.w)), 0.0, 1.0);
    float sideBlur = u.screen0.w * pow(smoothstep(110.0, halfW, abs(in.screenPos.x)), 1.4);
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

    float alpha = min(boxAlpha, cornerAlpha);
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
    var lastUsedTick: UInt64

    init(texture: MTLTexture, aspect: Float, tick: UInt64) {
        self.texture = texture
        self.aspect = aspect
        self.lastUsedTick = tick
    }
}

private final class RingTexturePool {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let loader: ThumbnailImageLoader
    private let maxEntries: Int = 48

    private var entries: [UUID: RingTextureEntry] = [:]
    private var loadingTasks: [UUID: Task<Void, Never>] = [:]
    private var tick: UInt64 = 0
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
            return (hit.texture, hit.aspect)
        }
        // Fast synchronous path if ThumbnailImageLoader already holds a decoded CGImage
        if let cg = loader.cachedCGImage(for: asset.id, tier: .preview1400)
            ?? loader.cachedCGImage(for: asset.id, tier: .grid520) {
            if let entry = upload(cgImage: cg, assetID: asset.id) {
                return (entry.texture, entry.aspect)
            }
        }
        requestAsync(assetID: asset.id)
        return nil
    }

    func prefetch(assets: [AssetRecord]) {
        for asset in assets {
            if entries[asset.id] != nil || loadingTasks[asset.id] != nil { continue }
            if let cg = loader.cachedCGImage(for: asset.id, tier: .preview1400)
                ?? loader.cachedCGImage(for: asset.id, tier: .grid520) {
                _ = upload(cgImage: cg, assetID: asset.id)
            } else {
                requestAsync(assetID: asset.id)
            }
        }
    }

    func purgeAll() {
        for task in loadingTasks.values { task.cancel() }
        loadingTasks.removeAll()
        entries.removeAll()
    }

    private func requestAsync(assetID: UUID) {
        guard loadingTasks[assetID] == nil else { return }
        let loader = self.loader
        loadingTasks[assetID] = Task { @MainActor [weak self] in
            defer { self?.loadingTasks.removeValue(forKey: assetID) }
            // Load preview1400 first, falling back cleanly to grid520
            var cg = await loader.loadCGImage(for: assetID, tier: .preview1400)
            if cg == nil {
                cg = await loader.loadCGImage(for: assetID, tier: .grid520)
            }
            guard !Task.isCancelled, let self, let cg else { return }
            if self.upload(cgImage: cg, assetID: assetID) != nil {
                self.onTextureReady?()
            }
        }
    }

    private func upload(cgImage: CGImage, assetID: UUID) -> RingTextureEntry? {
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

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: dstW,
            height: dstH,
            mipmapped: true
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }

        raw.withUnsafeBytes { ptr in
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
        let entry = RingTextureEntry(texture: tex, aspect: aspect, tick: tick)
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
    private var callbacks: RingGalleryInteractionCallbacks?

    // Continuous arc offset (px along the ring)
    private var offset: Double = 0
    private var lastReportedFrontAssetID: UUID?

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
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }

    public override var acceptsFirstResponder: Bool { true }

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
        callbacks: RingGalleryInteractionCallbacks
    ) {
        let oldAssetIDs = self.assets.map(\.id)
        let newAssetIDs = assets.map(\.id)
        let listChanged = oldAssetIDs != newAssetIDs

        let oldParams = self.params
        let appearanceChanged = (self.isDarkMode != isDarkMode)
            || (self.topSafeInset != topSafeInset)
            || (oldParams != params)

        self.assets = assets
        self.params = params
        self.isDarkMode = isDarkMode
        self.reduceMotion = reduceMotion
        self.isOverlayPresented = isOverlayPresented
        self.topSafeInset = topSafeInset
        self.callbacks = callbacks

        if listChanged {
            offsetAnim = nil
            if let selectedAssetID, let idx = assets.firstIndex(where: { $0.id == selectedAssetID }) {
                offset = Double(idx) * params.step
            } else {
                offset = 0
            }
            reportFrontAssetIfChanged(force: true)
            prefetchAroundCurrentOffset()
            requestFrame()
        } else if let selectedAssetID,
                  selectedAssetID != lastReportedFrontAssetID,
                  !isDragging,
                  offsetAnim == nil,
                  let idx = assets.firstIndex(where: { $0.id == selectedAssetID }) {
            // External selection change (e.g., clicked Similar item in Inspector) -> glide shortest path
            rotateToAssetIndex(idx, duration: reduceMotion ? 0.18 : 0.76)
        }

        if oldParams != params {
            // Moving any live tuning slider stops ongoing demo/glide motion and updates immediately (Section 8)
            offsetAnim = nil
            requestFrame()
        } else if appearanceChanged {
            requestFrame()
        }
    }

    public func step(by delta: Int) {
        guard !assets.isEmpty else { return }
        let baseIdx: Int
        if let anim = offsetAnim {
            baseIdx = RingGalleryMath.frontVirtualIndex(offset: anim.to, step: params.step)
        } else {
            baseIdx = RingGalleryMath.frontVirtualIndex(offset: offset, step: params.step)
        }
        var targetIdx = baseIdx + delta
        if assets.count <= 3 {
            targetIdx = max(0, min(assets.count - 1, targetIdx))
        }
        let targetOffset = Double(targetIdx) * params.step
        startOffsetAnimation(to: targetOffset, duration: reduceMotion ? 0.16 : 0.56)
    }

    private func rotateToAssetIndex(_ targetAssetIdx: Int, duration: Double) {
        guard !assets.isEmpty else { return }
        let currentVirtual = RingGalleryMath.frontVirtualIndex(offset: offset, step: params.step)
        let currentAsset = RingGalleryMath.positiveMod(currentVirtual, count: assets.count)
        var delta = targetAssetIdx - currentAsset
        if assets.count > 3 {
            let half = assets.count / 2
            if delta > half { delta -= assets.count }
            if delta < -half { delta += assets.count }
        }
        let targetVirtual = currentVirtual + delta
        startOffsetAnimation(to: Double(targetVirtual) * params.step, duration: duration)
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
        let verticalBias = -Double(topSafeInset) * 0.28
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

        // 1:1 pointer follow (dragging left increases offset so ring turns forward)
        offset = dragStartOffset - Double(x - dragStartWindowX)
        if assets.count <= 3 {
            let maxOff = Double(max(0, assets.count - 1)) * params.step
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
            if let hit = hitTestCard(at: event) {
                let frontVirtual = RingGalleryMath.frontVirtualIndex(offset: offset, step: params.step)
                if hit.virtualIndex == frontVirtual {
                    if event.clickCount >= 2, hit.assetIndex < assets.count {
                        callbacks?.onOpenQuickLook(assets[hit.assetIndex])
                    } else {
                        // Snap tightly to exact center
                        startOffsetAnimation(to: Double(frontVirtual) * params.step, duration: 0.32)
                    }
                } else {
                    // Bring clicked side card to front center in 760ms (Section 7)
                    startOffsetAnimation(to: Double(hit.virtualIndex) * params.step, duration: 0.760)
                }
            } else {
                let snapped = (offset / params.step).rounded() * params.step
                startOffsetAnimation(to: snapped, duration: 0.42)
            }
            return
        }

        // Compute release pointer velocity (px/s)
        let now = CACurrentMediaTime()
        var velocity: Double = 0
        if let first = velocitySamples.first(where: { now - $0.time <= 0.10 }),
           let last = velocitySamples.last,
           last.time - first.time > 0.005 {
            velocity = Double(last.x - first.x) / (last.time - first.time)
        }
        velocitySamples.removeAll()

        var (target, duration) = RingGalleryMath.releaseGlide(
            offset: offset,
            velocity: velocity,
            step: params.step,
            reducedMotion: reduceMotion
        )
        if assets.count <= 3 {
            let maxOff = Double(max(0, assets.count - 1)) * params.step
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
        let rawDelta: Double = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? Double(event.scrollingDeltaX)
            : Double(event.scrollingDeltaY)
        let scale: Double = event.hasPreciseScrollingDeltas ? 1.15 : 18.0
        offset -= rawDelta * scale

        if assets.count <= 3 {
            let maxOff = Double(max(0, assets.count - 1)) * params.step
            offset = RingGalleryMath.clamp(offset, -params.step * 0.25, maxOff + params.step * 0.25)
        }

        reportFrontAssetIfChanged()
        prefetchAroundCurrentOffset()
        requestFrame()

        // Snap cleanly to the nearest card once trackpad / wheel scroll settles
        let isEnded = event.momentumPhase == .ended || (event.phase == .ended && event.momentumPhase.isEmpty)
        let delay: TimeInterval = isEnded ? 0.04 : 0.16
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isDragging else { return }
            var snapped = (self.offset / self.params.step).rounded() * self.params.step
            if self.assets.count <= 3 {
                snapped = RingGalleryMath.clamp(snapped, 0, Double(max(0, self.assets.count - 1)) * self.params.step)
            }
            if abs(snapped - self.offset) > 0.4 {
                self.startOffsetAnimation(to: snapped, duration: self.reduceMotion ? 0.15 : 0.42)
            }
        }
        scrollSnapWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func reportFrontAssetIfChanged(force: Bool = false) {
        guard !assets.isEmpty else {
            if lastReportedFrontAssetID != nil || force {
                lastReportedFrontAssetID = nil
                callbacks?.onFrontAssetChanged(nil)
            }
            return
        }
        let frontIdx: Int
        if assets.count <= 3 {
            frontIdx = Int(RingGalleryMath.clamp(Double(RingGalleryMath.frontVirtualIndex(offset: offset, step: params.step)), 0, Double(assets.count - 1)).rounded())
        } else {
            let vIdx = RingGalleryMath.frontVirtualIndex(offset: offset, step: params.step)
            frontIdx = RingGalleryMath.positiveMod(vIdx, count: assets.count)
        }
        let asset = assets[frontIdx]
        if force || asset.id != lastReportedFrontAssetID {
            lastReportedFrontAssetID = asset.id
            callbacks?.onFrontAssetChanged(asset)
        }
    }

    private func prefetchAroundCurrentOffset() {
        guard !assets.isEmpty, let pool = texturePool else { return }
        let centerVirtual = RingGalleryMath.frontVirtualIndex(offset: offset, step: params.step)
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
        requestFrame()
    }

    public func draw(in view: MTKView) {
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
            reportFrontAssetIfChanged()
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
            return
        }

        let viewportPts = bounds.size
        let retinaScale = Float(max(1.0, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0))
        let usableH = max(240.0, Double(viewportPts.height) - Double(topSafeInset) - 56.0)
        // Exact 1:1 desktop scale whenever height >= 360pt; smoothly scales down only on ultra-short windows
        let cardScale = min(1.0, max(0.62, usableH / 380.0))
        let verticalBiasPt = Float(-Double(topSafeInset) * 0.28)

        let projected = RingGalleryMath.visibleOutsideCards(
            assetCount: assets.count,
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
        let blurPad = Float(params.depthBlur + 4.0)

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
                geom0: SIMD4<Float>(Float(card.arcS), Float(params.curvature), Float(params.perspective), Float(params.cardWidth)),
                geom1: SIMD4<Float>(Float(params.cardHeight), Float(params.cornerRadius), pScale, Float(params.radius)),
                screen0: SIMD4<Float>(Float(card.minScreenX), Float(card.maxScreenX), blurPad, Float(params.depthBlur)),
                screen1: SIMD4<Float>(Float(params.farFade), halfW, halfH, retinaScale),
                media: SIMD4<Float>(imgAspect, hasTexture, card.isFarSide ? 1.0 : 0.0, Float(card.uMin)),
                slice: SIMD4<Float>(Float(card.uMax), card.isFarSide ? 1.0 : 0.0, verticalBiasPt, Float(cardScale)),
                bgColor: bgRGB,
                tintColor: placeholderRGB
            )

            encoder.setVertexBytes(&uniforms, length: MemoryLayout<RingCardGPUUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RingCardGPUUniforms>.stride, index: 0)
            encoder.setFragmentTexture(activeTex, index: 0)
            // 96 interior columns + 2 margin columns = 99 column stations * 2 vertices = 198 vertices
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 198)
        }

        encoder.endEncoding()
        cmd.present(drawable)
        cmd.commit()

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
