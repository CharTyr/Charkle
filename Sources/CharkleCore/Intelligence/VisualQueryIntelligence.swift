import Foundation

/// Perceptual visual tone derived directly from an asset's stored CIELAB `dominantColors`
/// (`L*` lightness, `C*` chroma, `a*/b*` warmth/coolness, and inter-swatch contrast).
/// Runs 100% locally in sub-millisecond time with zero cloud cost.
public nonisolated enum VisualTone: String, Codable, CaseIterable, Hashable, Sendable {
    case dark
    case light
    case warm
    case cool
    case vivid
    case muted
    case highContrast = "high_contrast"

    public static func parse(_ raw: String?) -> VisualTone? {
        guard let cleaned = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !cleaned.isEmpty else { return nil }
        switch cleaned {
        case "dark", "暗调", "深色", "暗": return .dark
        case "light", "bright", "浅色", "明亮", "白底", "浅": return .light
        case "warm", "暖色", "暖调", "暖": return .warm
        case "cool", "cold", "冷色", "冷调", "冷": return .cool
        case "vivid", "vibrant", "saturated", "高饱和", "鲜艳": return .vivid
        case "muted", "pastel", "soft", "低饱和", "莫兰迪", "柔和": return .muted
        case "high_contrast", "highcontrast", "contrast", "高对比", "强对比", "撞色": return .highContrast
        default: return VisualTone(rawValue: cleaned)
        }
    }

    public func matches(_ asset: AssetRecord) -> Bool {
        score(asset) >= 0.52
    }

    /// Returns a smooth `0.0...1.0` perceptual fit score for `asset`'s CIELAB palette.
    public func score(_ asset: AssetRecord) -> Double {
        let valid = asset.dominantColors.filter { $0.l.isFinite && $0.a.isFinite && $0.b.isFinite }
        guard !valid.isEmpty else { return 0 }

        var totalW = 0.0
        var sumL = 0.0
        var sumA = 0.0
        var sumB = 0.0
        var sumC = 0.0
        var maxC = 0.0
        var minL = 100.0
        var maxL = 0.0
        var warmWeight = 0.0
        var coolWeight = 0.0
        var darkWeight = 0.0
        var lightWeight = 0.0

        let topSwatches = Array(valid.prefix(5))
        for swatch in topSwatches {
            let w = swatch.proportion > 0.001 ? swatch.proportion : (1.0 / Double(topSwatches.count))
            let c = hypot(swatch.a, swatch.b)
            totalW += w
            sumL += swatch.l * w
            sumA += swatch.a * w
            sumB += swatch.b * w
            sumC += c * w
            if w >= 0.08 || topSwatches.count <= 2 {
                maxC = max(maxC, c)
                minL = min(minL, swatch.l)
                maxL = max(maxL, swatch.l)
            }
            if swatch.l <= 34 { darkWeight += w }
            if swatch.l >= 74 { lightWeight += w }
            if c >= 10 {
                if swatch.b > 6 || swatch.a > 8 { warmWeight += w }
                if swatch.b < -5 || (swatch.a < -5 && swatch.b <= 6) { coolWeight += w }
            }
        }
        guard totalW > 0 else { return 0 }
        let avgL = sumL / totalW
        let avgA = sumA / totalW
        let avgB = sumB / totalW
        let avgC = sumC / totalW
        let darkFrac = darkWeight / totalW
        let lightFrac = lightWeight / totalW
        let warmFrac = warmWeight / totalW
        let coolFrac = coolWeight / totalW

        switch self {
        case .dark:
            let lScore = clamp01((52.0 - avgL) / 34.0)
            let fScore = clamp01(darkFrac / 0.55)
            return max(lScore, lScore * 0.65 + fScore * 0.35)

        case .light:
            let lScore = clamp01((avgL - 54.0) / 32.0)
            let fScore = clamp01(lightFrac / 0.55)
            return max(lScore, lScore * 0.65 + fScore * 0.35)

        case .warm:
            let axis = clamp01((avgB * 0.7 + avgA * 0.55 - 2.0) / 24.0)
            let frac = clamp01(warmFrac / 0.48)
            let chromaGate = clamp01((maxC - 8.0) / 14.0)
            return chromaGate * max(axis * 0.85, axis * 0.55 + frac * 0.45)

        case .cool:
            let axis = clamp01(((-avgB) * 0.75 + (-avgA) * 0.45 - 1.5) / 22.0)
            let frac = clamp01(coolFrac / 0.45)
            let chromaGate = clamp01((maxC - 7.0) / 14.0)
            return chromaGate * max(axis * 0.85, axis * 0.55 + frac * 0.45)

        case .vivid:
            let avgScore = clamp01((avgC - 20.0) / 28.0)
            let peakScore = clamp01((maxC - 32.0) / 34.0)
            return max(avgScore, avgScore * 0.6 + peakScore * 0.4)

        case .muted:
            let lowChroma = clamp01((28.0 - avgC) / 18.0)
            let midLight = (avgL >= 24 && avgL <= 86) ? 1.0 : 0.45
            let notExtremePeak = maxC <= 38 ? 1.0 : clamp01((54.0 - maxC) / 16.0)
            return lowChroma * midLight * notExtremePeak

        case .highContrast:
            let lSpread = max(0, maxL - minL)
            let lScore = clamp01((lSpread - 30.0) / 42.0)
            var maxDeltaE = 0.0
            let prominent = topSwatches.filter { $0.proportion >= 0.08 || topSwatches.count <= 2 }
            for i in 0..<prominent.count {
                for j in (i + 1)..<prominent.count {
                    let d = prominent[i].deltaE2000(to: prominent[j])
                    if d.isFinite { maxDeltaE = max(maxDeltaE, d) }
                }
            }
            let deScore = clamp01((maxDeltaE - 34.0) / 36.0)
            return max(lScore * 0.85, deScore * 0.85, lScore * 0.5 + deScore * 0.5)
        }
    }

    private func clamp01(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}

/// Cross-lingual EN ↔ ZH visual vocabulary & natural-language intent extractor
/// powering zero-cloud-cost local semantic recall on mixed-language asset libraries.
public nonisolated enum VisualQueryIntelligence {
    public struct ParsedHints: Sendable {
        public let tones: [VisualTone]
        public let aspectShapes: [AspectShape]
        public let targetColors: [LabColor]
        public let expandedTerms: [String]
    }

    /// Compact, curated design & illustration EN ↔ ZH synonym table.
    /// Keys are normalized lowercase tokens; values are high-signal secondary recall terms.
    private static let bilingualSynonyms: [String: [String]] = [
        // Mediums & Art Styles
        "woodblock": ["木版画", "浮世绘", "日本风景"],
        "ukiyo": ["浮世绘", "木版画", "日本风景"],
        "ukiyoe": ["浮世绘", "木版画", "日本风景"],
        "japanese": ["日本风景", "木版画", "浮世绘", "和风"],
        "anime": ["动漫插画", "人物插画", "二次元"],
        "manga": ["动漫插画", "漫画", "手绘风"],
        "illustration": ["插画", "人物插画", "动漫插画", "手绘插画"],
        "illustrator": ["插画", "手绘风"],
        "drawing": ["手绘风", "手绘插画", "素描"],
        "sketch": ["手绘风", "线稿", "草图"],
        "lineart": ["线稿", "清线", "手绘风"],
        "watercolor": ["水彩", "手绘风"],
        "vintage": ["复古", "复古质感", "怀旧"],
        "retro": ["复古", "复古质感", "怀旧"],
        "film": ["胶片", "复古质感", "摄影"],
        "minimal": ["极简", "纯色背景", "白色背景"],
        "minimalist": ["极简", "纯色背景", "白色背景"],
        "clean": ["极简", "白色背景", "纯色背景"],
        "editorial": ["海报", "排版", "平面设计"],
        "poster": ["海报", "平面设计"],
        "photography": ["摄影", "写真"],
        "photo": ["摄影", "写真"],
        "cyberpunk": ["赛博朋克", "霓虹", "夜景"],
        "neon": ["霓虹", "夜景", "赛博朋克"],
        "pixel": ["像素", "复古"],

        // Subjects, Characters & Clothing
        "girl": ["女孩", "少女", "人物插画"],
        "girls": ["女孩", "少女"],
        "woman": ["女孩", "女性", "人物插画"],
        "boy": ["男孩", "少年"],
        "character": ["人物插画", "动漫插画", "全身像"],
        "fullbody": ["全身像", "立绘"],
        "standing": ["全身像", "立绘"],
        "portrait": ["人物插画", "女孩", "写真", "半身像"],
        "fashion": ["服装设计", "穿搭", "休闲穿搭", "服饰"],
        "outfit": ["穿搭", "服装设计", "休闲穿搭", "服饰"],
        "clothing": ["服装设计", "服饰", "穿搭"],
        "clothes": ["服装设计", "服饰", "穿搭"],
        "casual": ["休闲穿搭", "宽松穿搭"],
        "streetwear": ["休闲穿搭", "宽松穿搭", "街头"],
        "uniform": ["制服", "校服", "服饰"],
        "dress": ["服装设计", "连衣裙", "穿搭"],
        "pose": ["动态构图", "人体", "素体"],
        "anatomy": ["人体", "人体写真", "素体"],
        "body": ["人体", "人体写真", "全身像"],
        "blonde": ["金发"],
        "hair": ["金发", "黑发", "长发"],

        // Environments, Nature & Seasons
        "summer": ["夏日", "夏天", "晴空", "海滩"],
        "winter": ["冬日", "雪景", "冬天"],
        "snow": ["雪景", "冬日"],
        "autumn": ["秋日", "秋天", "落叶"],
        "spring": ["春日", "樱花", "花"],
        "beach": ["海滩", "海洋", "海边", "夏日"],
        "ocean": ["海洋", "海滩", "海边"],
        "sea": ["海洋", "海滩", "海边"],
        "coast": ["海滩", "海洋"],
        "water": ["海洋", "水面", "湖"],
        "boat": ["船只", "帆船"],
        "sail": ["帆船", "船只"],
        "sky": ["晴空", "蓝天", "天空"],
        "cloud": ["晴空", "云", "天空"],
        "clouds": ["晴空", "云", "天空"],
        "mountain": ["山景", "风景"],
        "mountains": ["山景", "风景"],
        "landscape": ["风景", "日本风景", "山景"],
        "scenery": ["风景", "日本风景"],
        "nature": ["风景", "自然", "山景"],
        "city": ["城市", "街景", "建筑"],
        "street": ["街景", "城市"],
        "urban": ["城市", "街景", "建筑"],
        "architecture": ["建筑", "室内场景"],
        "interior": ["室内场景", "室内"],
        "room": ["室内场景", "室内"],
        "cafe": ["咖啡馆", "室内场景"],
        "night": ["夜景", "夜晚", "暗调"],
        "evening": ["夜景", "黄昏"],
        "sunset": ["日落", "夕阳", "黄昏", "暖色调"],
        "sunrise": ["日出", "暖色调"],
        "dusk": ["黄昏", "夕阳"],
        "dynamic": ["动态构图", "透视构图"],
        "perspective": ["透视构图", "动态构图"],

        // Background & Colors
        "white": ["白色背景", "纯色背景"],
        "background": ["白色背景", "纯色背景", "室内场景"],
        "blue": ["蓝色调", "海洋", "晴空"],
        "cyan": ["蓝色调", "晴空"],
        "red": ["红色调", "暖色调"],
        "warm": ["暖色调", "日落", "复古质感"],
        "cool": ["蓝色调", "冷色调", "晴空"],
        "green": ["绿色调", "自然", "山景"],
        "yellow": ["暖色调", "金发"],
        "golden": ["暖色调", "日落", "金发"],
        "pink": ["粉色", "柔和"],
        "dark": ["夜景", "暗调"],
        "light": ["白色背景", "晴空", "明亮"],

        // Chinese -> English / related Chinese concept bridges
        "木版画": ["woodblock", "浮世绘", "日本风景"],
        "浮世绘": ["ukiyo", "木版画", "日本风景"],
        "海边": ["海滩", "海洋", "beach", "ocean"],
        "海滩": ["海边", "海洋", "beach"],
        "蓝天": ["晴空", "天空", "sky"],
        "晴空": ["蓝天", "天空", "sky"],
        "白底": ["白色背景", "纯色背景", "极简"],
        "留白": ["白色背景", "纯色背景", "极简"],
        "立绘": ["全身像", "人物插画", "动漫插画"],
        "服装": ["服装设计", "服饰", "穿搭"],
        "服饰": ["服装设计", "穿搭", "制服"],
        "日落": ["夕阳", "黄昏", "暖色调", "sunset"],
        "夕阳": ["日落", "黄昏", "暖色调"],
        "夜景": ["夜晚", "night", "暗调"],
        "冷色调": ["蓝色调", "蓝", "cool"],
        "冷调": ["蓝色调", "冷色调", "cool"],
        "暖色调": ["暖调", "日落", "warm"],
        "暖调": ["暖色调", "日落", "warm"],
        "清线": ["clearline", "手绘风", "动漫插画"],
        "撞色": ["高饱和", "对比"]
    ]

    public static func parseVisualHints(from query: String, baseTerms: [String]) -> ParsedHints {
        let lower = SearchText.normalize(query)
        let normTerms = baseTerms.map(SearchText.normalize).filter { !$0.isEmpty }
        let baseSet = Set(normTerms)

        // 1. Visual tones
        var tones: [VisualTone] = []
        func addTone(_ tone: VisualTone) {
            if !tones.contains(tone) { tones.append(tone) }
        }
        let darkKeys = ["暗调", "深色", "夜景", "夜晚", "黑夜", "dark", "moody", "night", "noir", "shadow"]
        let lightKeys = ["浅色", "白底", "白色背景", "明亮", "留白", "light", "bright", "airy", "white"]
        let warmKeys = ["暖色", "暖调", "温暖", "日落", "夕阳", "黄昏", "琥珀", "warm", "sunset", "golden", "amber", "terracotta"]
        let coolKeys = ["冷色", "冷调", "蓝调", "蓝色调", "清冷", "冰蓝", "cool", "cold", "icy", "blue", "cyan", "teal"]
        let vividKeys = ["高饱和", "鲜艳", "浓烈", "撞色", "艳丽", "vivid", "vibrant", "saturated", "colorful", "neon"]
        let mutedKeys = ["低饱和", "莫兰迪", "柔和", "灰调", "淡雅", "素雅", "muted", "pastel", "desaturated", "soft", "subtle"]
        let contrastKeys = ["高对比", "强对比", "撞色", "明暗对比", "contrast", "dramatic", "chiaroscuro"]

        func matchesAny(_ keys: [String]) -> Bool {
            keys.contains { key in
                if SearchText.containsHan(key) {
                    return lower.contains(key)
                }
                return baseSet.contains(key)
            }
        }
        if matchesAny(darkKeys) { addTone(.dark) }
        if matchesAny(lightKeys) { addTone(.light) }
        if matchesAny(warmKeys) { addTone(.warm) }
        if matchesAny(coolKeys) { addTone(.cool) }
        if matchesAny(vividKeys) { addTone(.vivid) }
        if matchesAny(mutedKeys) { addTone(.muted) }
        if matchesAny(contrastKeys) { addTone(.highContrast) }

        // 2. Aspect shape intents
        var shapes: [AspectShape] = []
        func addShape(_ shape: AspectShape) {
            if !shapes.contains(shape) { shapes.append(shape) }
        }
        if matchesAny(["竖屏", "竖图", "竖版", "纵向", "vertical"]) || baseSet.contains("portrait") {
            addShape(.portrait)
        }
        if matchesAny(["横屏", "横图", "横版", "横向", "horizontal"]) || baseSet.contains("landscape") {
            addShape(.landscape)
        }
        if matchesAny(["方图", "正方形", "方形", "square"]) {
            addShape(.square)
        }
        if matchesAny(["宽屏", "超宽", "电影画幅", "全景", "ultrawide", "panoramic", "widescreen"]) {
            addShape(.ultrawide)
        }

        // 3. Soft CIELAB color anchors extracted from color words
        var colors: [LabColor] = []
        let colorHints: [([String], String)] = [
            (["蓝", "蓝色", "蓝色调", "青蓝", "海蓝", "blue", "indigo", "cobalt", "navy"], "#2A6F97"),
            (["红", "红色", "朱红", "陶土", "red", "crimson", "terracotta"], "#C84B31"),
            (["绿", "绿色", "翠绿", "森系", "green", "emerald", "sage"], "#2D6A4F"),
            (["黄", "黄色", "金色", "暖黄", "yellow", "gold", "golden", "amber"], "#E9B44C"),
            (["橙", "橘", "日落", "夕阳", "orange", "sunset"], "#E07A3F"),
            (["粉", "粉色", "樱花", "pink", "rose"], "#E5989B"),
            (["紫", "紫色", "purple", "violet", "lavender"], "#6D597A")
        ]
        for (keys, hex) in colorHints where matchesAny(keys) {
            colors.append(LabColor.fromHex(hex))
        }

        // 4. Cross-lingual & domain synonym expansion
        var expanded: [String] = []
        var seen = baseSet
        func addExpanded(_ raw: String) {
            let n = SearchText.normalize(raw)
            guard !n.isEmpty, seen.insert(n).inserted else { return }
            expanded.append(raw)
        }
        for term in normTerms {
            if let mapped = bilingualSynonyms[term] {
                for m in mapped { addExpanded(m) }
            }
        }
        // Also match 2+ char Chinese synonym keys embedded directly in the query string
        for (key, mapped) in bilingualSynonyms where SearchText.containsHan(key) && key.count >= 2 && lower.contains(key) {
            addExpanded(key)
            for m in mapped { addExpanded(m) }
        }

        return ParsedHints(
            tones: tones,
            aspectShapes: shapes,
            targetColors: colors,
            expandedTerms: Array(expanded.prefix(12))
        )
    }

    /// Evaluates how well `asset` aligns with parsed visual hints (tones, aspect shapes, soft color anchors).
    /// Returns `(score, reason)` or `nil` when no hints were present or matched.
    public static func visualHintScore(for asset: AssetRecord, hints: ParsedHints) -> (score: Double, reason: String)? {
        var components: [(Double, String)] = []

        if !hints.tones.isEmpty {
            let scores = hints.tones.map { ($0, $0.score(asset)) }
            let avg = scores.map(\.1).reduce(0, +) / Double(scores.count)
            if avg >= 0.42 {
                let matchedLabels = scores.filter { $0.1 >= 0.48 }.map { $0.0.rawValue }.joined(separator: "/")
                components.append((avg, matchedLabels.isEmpty ? "氛围吻合" : "氛围:\(matchedLabels)"))
            }
        }

        if !hints.aspectShapes.isEmpty {
            if hints.aspectShapes.contains(asset.aspectShape) {
                components.append((0.85, "画幅:\(asset.aspectShape.rawValue)"))
            }
        }

        if !hints.targetColors.isEmpty, !asset.dominantColors.isEmpty {
            let valid = asset.dominantColors.prefix(4).filter { $0.l.isFinite && $0.a.isFinite && $0.b.isFinite }
            let minDE = valid.flatMap { c in hints.targetColors.map { c.deltaE2000(to: $0) } }.filter(\.isFinite).min()
            if let de = minDE, de < 28.0 {
                let sim = max(0, 1.0 - de / 28.0)
                if sim >= 0.35 {
                    components.append((sim, "色相吻合"))
                }
            }
        }

        guard !components.isEmpty else { return nil }
        let avgScore = components.map(\.0).reduce(0, +) / Double(components.count)
        let reason = components.map(\.1).joined(separator: "·")
        return (min(1.0, avgScore), reason)
    }
}
