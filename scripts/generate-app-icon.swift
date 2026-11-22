#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 3 else {
    fputs("Usage: generate-app-icon.swift <out-1024.png> <out.icns>\n", stderr)
    exit(1)
}

let pngOutPath = CommandLine.arguments[1]
let icnsOutPath = CommandLine.arguments[2]

func drawCharkleIcon(size: Int) -> CGImage? {
    let s = CGFloat(size)
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
              data: nil,
              width: size,
              height: size,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: cs,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    // macOS Big Sur / Tahoe continuous squircle proportions (~8.6% margin, 22.5% corner radius)
    let inset = s * 0.086
    let bodyRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squirclePath = NSBezierPath(roundedRect: bodyRect, xRadius: bodyRect.width * 0.225, yRadius: bodyRect.height * 0.225)
    let cgSquircle = squirclePath.cgPath

    // Soft outer contact shadow (only subtle, macOS adds system dock shadow)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.015), blur: s * 0.03, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.addPath(cgSquircle)
    ctx.setFillColor(CGColor(red: 0.10, green: 0.11, blue: 0.14, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Clip to squircle body
    ctx.saveGState()
    ctx.addPath(cgSquircle)
    ctx.clip()

    // Studio warm graphite base gradient (neutral, zero purple slop)
    let bgColors = [
        CGColor(red: 0.165, green: 0.180, blue: 0.212, alpha: 1),
        CGColor(red: 0.082, green: 0.090, blue: 0.108, alpha: 1)
    ] as CFArray
    if let bgGrad = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0, 1]) {
        ctx.drawLinearGradient(bgGrad, start: CGPoint(x: s * 0.5, y: bodyRect.maxY), end: CGPoint(x: s * 0.5, y: bodyRect.minY), options: [])
    }

    // Subtle warm top-left studio key light
    let keyLight = [
        CGColor(red: 1.0, green: 0.98, blue: 0.94, alpha: 0.12),
        CGColor(red: 1.0, green: 0.98, blue: 0.94, alpha: 0.0)
    ] as CFArray
    if let glow = CGGradient(colorsSpace: cs, colors: keyLight, locations: [0, 1]) {
        ctx.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: s * 0.30, y: s * 0.76),
            startRadius: 0,
            endCenter: CGPoint(x: s * 0.30, y: s * 0.76),
            endRadius: s * 0.58,
            options: []
        )
    }

    // Inner subtle moodboard frame backing (Kubai layered construction: back plate + cards)
    let frameInset = s * 0.195
    let frameRect = CGRect(x: frameInset, y: frameInset, width: s - frameInset * 2, height: s - frameInset * 2)
    let gap = s * 0.044
    let colW = (frameRect.width - gap) / 2.0
    let cr = s * 0.068

    func drawLayeredTile(_ rect: CGRect, topColor: CGColor, bottomColor: CGColor, rimColor: CGColor) {
        let p = NSBezierPath(roundedRect: rect, xRadius: cr, yRadius: cr).cgPath
        // Drop shadow
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.016), blur: s * 0.028, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.38))
        ctx.addPath(p)
        ctx.setFillColor(bottomColor)
        ctx.fillPath()
        ctx.restoreGState()

        // Vertical gradient fill
        ctx.saveGState()
        ctx.addPath(p)
        ctx.clip()
        if let g = CGGradient(colorsSpace: cs, colors: [topColor, bottomColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        }
        // Top inner specular highlight (Kubai layered inner glow)
        let hiRect = CGRect(x: rect.minX, y: rect.maxY - rect.height * 0.16, width: rect.width, height: rect.height * 0.16)
        if let hiGrad = CGGradient(
            colorsSpace: cs,
            colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.30), CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawLinearGradient(hiGrad, start: CGPoint(x: hiRect.midX, y: hiRect.maxY), end: CGPoint(x: hiRect.midX, y: hiRect.minY), options: [])
        }
        ctx.restoreGState()

        // Crisp rim
        ctx.addPath(p)
        ctx.setStrokeColor(rimColor)
        ctx.setLineWidth(max(1.0, s * 0.008))
        ctx.strokePath()
    }

    // Left column: tall Cobalt hero card (top) + compact Warm Terracotta card (bottom)
    let leftTallH = frameRect.height * 0.58 - gap * 0.5
    let leftShortH = frameRect.height - leftTallH - gap
    let leftTopRect = CGRect(x: frameRect.minX, y: frameRect.maxY - leftTallH, width: colW, height: leftTallH)
    let leftBotRect = CGRect(x: frameRect.minX, y: frameRect.minY, width: colW, height: leftShortH)

    // Right column: compact Warm Ivory card (top) + tall Sage Emerald card (bottom)
    let rightShortH = frameRect.height * 0.40 - gap * 0.5
    let rightTallH = frameRect.height - rightShortH - gap
    let rightTopRect = CGRect(x: frameRect.minX + colW + gap, y: frameRect.maxY - rightShortH, width: colW, height: rightShortH)
    let rightBotRect = CGRect(x: frameRect.minX + colW + gap, y: frameRect.minY, width: colW, height: rightTallH)

    // 1. Studio Cobalt hero card (with minimal horizon/sun motif like Kubai images icon)
    drawLayeredTile(
        leftTopRect,
        topColor: CGColor(red: 0.34, green: 0.59, blue: 0.96, alpha: 1),
        bottomColor: CGColor(red: 0.18, green: 0.43, blue: 0.87, alpha: 1),
        rimColor: CGColor(red: 0.72, green: 0.86, blue: 1.0, alpha: 0.42)
    )
    // Minimal white graphic accent inside cobalt hero card
    ctx.saveGState()
    ctx.addPath(NSBezierPath(roundedRect: leftTopRect, xRadius: cr, yRadius: cr).cgPath)
    ctx.clip()
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.90))
    let sunR = colW * 0.125
    ctx.fillEllipse(in: CGRect(
        x: leftTopRect.maxX - colW * 0.28 - sunR,
        y: leftTopRect.maxY - leftTallH * 0.28 - sunR,
        width: sunR * 2,
        height: sunR * 2
    ))
    let hillPath = CGMutablePath()
    hillPath.move(to: CGPoint(x: leftTopRect.minX - 4, y: leftTopRect.minY - 4))
    hillPath.addLine(to: CGPoint(x: leftTopRect.minX - 4, y: leftTopRect.minY + leftTallH * 0.30))
    hillPath.addQuadCurve(
        to: CGPoint(x: leftTopRect.maxX + 4, y: leftTopRect.minY + leftTallH * 0.22),
        control: CGPoint(x: leftTopRect.minX + colW * 0.42, y: leftTopRect.minY + leftTallH * 0.56)
    )
    hillPath.addLine(to: CGPoint(x: leftTopRect.maxX + 4, y: leftTopRect.minY - 4))
    hillPath.closeSubpath()
    ctx.addPath(hillPath)
    ctx.setFillColor(CGColor(red: 0.08, green: 0.24, blue: 0.58, alpha: 0.42))
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Warm Studio Terracotta card (bottom-left)
    drawLayeredTile(
        leftBotRect,
        topColor: CGColor(red: 0.92, green: 0.48, blue: 0.34, alpha: 1),
        bottomColor: CGColor(red: 0.81, green: 0.34, blue: 0.22, alpha: 1),
        rimColor: CGColor(red: 1.0, green: 0.78, blue: 0.70, alpha: 0.36)
    )

    // 3. Warm Paper Ivory swatch card (top-right, holds crisp 4-point Charkle spark!)
    drawLayeredTile(
        rightTopRect,
        topColor: CGColor(red: 0.98, green: 0.965, blue: 0.935, alpha: 1),
        bottomColor: CGColor(red: 0.91, green: 0.885, blue: 0.84, alpha: 1),
        rimColor: CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.65)
    )
    // Crisp 4-point spark emblem in rich charcoal-cobalt inside the ivory card
    let cx = rightTopRect.midX
    let cy = rightTopRect.midY
    let spR = min(rightTopRect.width, rightTopRect.height) * 0.33
    let spIn = spR * 0.28
    let sparkPath = CGMutablePath()
    sparkPath.move(to: CGPoint(x: cx, y: cy + spR))
    sparkPath.addQuadCurve(to: CGPoint(x: cx + spR, y: cy), control: CGPoint(x: cx + spIn, y: cy + spIn))
    sparkPath.addQuadCurve(to: CGPoint(x: cx, y: cy - spR), control: CGPoint(x: cx + spIn, y: cy - spIn))
    sparkPath.addQuadCurve(to: CGPoint(x: cx - spR, y: cy), control: CGPoint(x: cx - spIn, y: cy - spIn))
    sparkPath.addQuadCurve(to: CGPoint(x: cx, y: cy + spR), control: CGPoint(x: cx - spIn, y: cy + spIn))
    sparkPath.closeSubpath()
    ctx.addPath(sparkPath)
    ctx.setFillColor(CGColor(red: 0.16, green: 0.38, blue: 0.78, alpha: 1))
    ctx.fillPath()

    // 4. Calm Sage-Emerald card (bottom-right) with subtle swatch strip lines
    drawLayeredTile(
        rightBotRect,
        topColor: CGColor(red: 0.28, green: 0.72, blue: 0.56, alpha: 1),
        bottomColor: CGColor(red: 0.16, green: 0.56, blue: 0.42, alpha: 1),
        rimColor: CGColor(red: 0.70, green: 0.95, blue: 0.84, alpha: 0.36)
    )
    // Subtle minimalist typography/note lines inside bottom-right card
    let lineH = s * 0.022
    let lineInsetX = rightBotRect.width * 0.20
    let line1 = CGRect(x: rightBotRect.minX + lineInsetX, y: rightBotRect.midY + lineH * 0.9, width: rightBotRect.width * 0.60, height: lineH)
    let line2 = CGRect(x: rightBotRect.minX + lineInsetX, y: rightBotRect.midY - lineH * 1.1, width: rightBotRect.width * 0.40, height: lineH)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.82))
    ctx.addPath(NSBezierPath(roundedRect: line1, xRadius: lineH / 2, yRadius: lineH / 2).cgPath)
    ctx.fillPath()
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.50))
    ctx.addPath(NSBezierPath(roundedRect: line2, xRadius: lineH / 2, yRadius: lineH / 2).cgPath)
    ctx.fillPath()

    ctx.restoreGState()

    // Outer glass rim specular stroke on the squircle
    ctx.addPath(cgSquircle)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
    ctx.setLineWidth(max(1.0, s * 0.008))
    ctx.strokePath()

    return ctx.makeImage()
}

func savePNG(_ image: CGImage, to path: String) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AppIcon", code: 1)
    }
    try data.write(to: URL(fileURLWithPath: path))
}

let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CharkleIconset-\(UUID().uuidString)")
let iconsetDir = tempDir.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let specs: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for (px, filename) in specs {
    guard let img = drawCharkleIcon(size: px) else { continue }
    try savePNG(img, to: iconsetDir.appendingPathComponent(filename).path)
    if px == 1024 {
        try savePNG(img, to: pngOutPath)
    }
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsOutPath]
try proc.run()
proc.waitUntilExit()
try? FileManager.default.removeItem(at: tempDir)
guard proc.terminationStatus == 0 else { exit(proc.terminationStatus) }
print("Generated \(pngOutPath) and \(icnsOutPath)")
