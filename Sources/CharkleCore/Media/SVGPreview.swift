import CoreGraphics
import Foundation

// Lightweight fallback for basic SVG geometry when the system renderer cannot open a file.
nonisolated final class SVGPreview: NSObject, XMLParserDelegate {
    private var context: CGContext?
    private var size = CGSize.zero
    private var fillStack: [String] = ["#000000"]

    static func render(_ url: URL) -> CGImage? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 2_000_000, let parser = XMLParser(contentsOf: url) else { return nil }
        let preview = SVGPreview()
        parser.delegate = preview
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        return preview.context?.makeImage()
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String]) {
        let tag = element.split(separator: ":").last.map(String.init) ?? element
        let fill = a["fill"] ?? fillStack.last ?? "#000000"
        fillStack.append(fill)
        if tag == "svg", context == nil {
            let view = coordinates(a["viewBox"])
            let w = view.count == 4 ? view[2] : number(a["width"], default: 300)
            let h = view.count == 4 ? view[3] : number(a["height"], default: 150)
            let maxDim = max(w, h)
            guard w.isFinite, h.isFinite, w >= 1e-6, h >= 1e-6, maxDim >= 1e-6 else { return }
            let scale = 1_400 / maxDim
            guard scale.isFinite, (w * scale).isFinite, (h * scale).isFinite else { return }
            let width = max(1, min(4_096, Int((w * scale).rounded())))
            let height = max(1, min(4_096, Int((h * scale).rounded())))
            size = CGSize(width: width, height: height)
            context = MediaArtwork.context(width: width, height: height)
            context?.translateBy(x: 0, y: size.height)
            context?.scaleBy(x: scale, y: -scale)
            if view.count == 4 { context?.translateBy(x: -view[0], y: -view[1]) }
        }
        guard let ctx = context else { return }
        let path = CGMutablePath()
        switch tag {
        case "rect":
            let rect = CGRect(x: number(a["x"]), y: number(a["y"]), width: number(a["width"]), height: number(a["height"]))
            let radius = max(0, number(a["rx"]))
            if radius > 0 { path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius) }
            else { path.addRect(rect) }
        case "circle", "ellipse":
            let rx = number(a["rx"] ?? a["r"])
            let ry = number(a["ry"] ?? a["r"])
            path.addEllipse(in: CGRect(x: number(a["cx"]) - rx, y: number(a["cy"]) - ry, width: 2 * rx, height: 2 * ry))
        case "line":
            path.move(to: CGPoint(x: number(a["x1"]), y: number(a["y1"])))
            path.addLine(to: CGPoint(x: number(a["x2"]), y: number(a["y2"])))
        case "polygon", "polyline":
            let points = coordinates(a["points"])
            guard points.count > 3 else { return }
            path.move(to: CGPoint(x: points[0], y: points[1]))
            for i in stride(from: 2, to: points.count - 1, by: 2) { path.addLine(to: CGPoint(x: points[i], y: points[i + 1])) }
            if tag == "polygon" { path.closeSubpath() }
        default: return
        }
        if tag != "line", let color = parseColor(fill) { ctx.setFillColor(color); ctx.addPath(path); ctx.fillPath() }
        if let stroke = a["stroke"].flatMap(parseColor) {
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(max(0, number(a["stroke-width"], default: 1)))
            ctx.addPath(path)
            ctx.strokePath()
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if fillStack.count > 1 { fillStack.removeLast() }
    }

    private func coordinates(_ text: String?) -> [Double] {
        (text ?? "").split { $0.isWhitespace || $0 == "," }.compactMap { Double($0) }.filter(\.isFinite)
    }

    private func number(_ text: String?, default fallback: Double = 0) -> Double {
        guard let value = text.flatMap({ Double($0.replacingOccurrences(of: "px", with: "")) }),
              value.isFinite else { return fallback }
        return value
    }

    private func parseColor(_ value: String) -> CGColor? {
        if value == "none" { return nil }
        let named: [String: UInt32] = ["white": 0xFFFFFF, "black": 0, "red": 0xFF0000, "blue": 0x0000FF, "green": 0x008000]
        if let rgb = named[value] { return MediaArtwork.color(rgb) }
        var digits = value.hasPrefix("#") ? String(value.dropFirst()) : ""
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        return MediaArtwork.color(UInt32(digits, radix: 16) ?? 0)
    }
}
