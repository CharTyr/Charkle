import CoreFoundation
import Foundation

nonisolated enum SearchText {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    private static let zhCNLocale = Locale(identifier: "zh_CN")

    private final class PinyinCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (full: String, initials: String)] = [:]

        func get(_ key: String) -> (full: String, initials: String)? {
            lock.lock()
            let value = entries[key]
            lock.unlock()
            return value
        }

        func set(_ key: String, value: (full: String, initials: String)) {
            lock.lock()
            if entries.count >= 2_048 {
                entries.removeAll(keepingCapacity: true)
            }
            entries[key] = value
            lock.unlock()
        }
    }

    private static let pinyinCache = PinyinCache()

    @inline(__always)
    static func hasHanScalar(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return (0x3400...0x9FFF).contains(value) || (0x20000...0x323AF).contains(value)
    }

    static func hasHan(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first else { return false }
        return hasHanScalar(scalar)
    }

    static func containsHan(_ text: String) -> Bool {
        if let ascii = text.utf8.withContiguousStorageIfAvailable({ buf -> Bool in
            for i in 0..<buf.count {
                if buf[i] >= 0x80 { return false }
            }
            return true
        }), ascii {
            return false
        }
        return text.unicodeScalars.contains(where: hasHanScalar)
    }

    static func tokenize(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var tokens: [String] = []
        var word = ""
        for character in text {
            if hasHan(character) || !(character.isLetter || character.isNumber) {
                if !word.isEmpty { tokens.append(word); word = "" }
                if hasHan(character) { tokens.append(String(character)) }
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty { tokens.append(word) }
        return tokens
    }

    static func pinyin(_ text: String) -> (full: String, initials: String) {
        guard containsHan(text) else { return ("", "") }
        if text.count <= 128, let cached = pinyinCache.get(text) {
            return cached
        }
        var full: [String] = []
        var initials: [String] = []
        for phrase in text.split(whereSeparator: { !hasHan($0) }).map(String.init) {
            let standard = mandarinSyllables(phrase)
            guard !standard.isEmpty else { continue }
            let contextual = contextualSyllables(phrase, standard: standard)
            for words in [standard, contextual.flatMap { $0 }] {
                full += [words.joined(separator: " "), words.joined()]
                initials.append(String(words.compactMap(\.first)))
            }
            for word in contextual where word.count > 1 {
                full.append(word.joined())
                initials.append(String(word.compactMap(\.first)))
            }
        }
        let result = (full.joined(separator: " "), initials.joined(separator: " "))
        if text.count <= 128 {
            pinyinCache.set(text, value: result)
        }
        return result
    }

    private static func mandarinSyllables(_ text: String) -> [String] {
        guard let buffer = CFStringCreateMutableCopy(nil, 0, text as CFString) else { return [] }
        CFStringTransform(buffer, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(buffer, nil, kCFStringTransformStripDiacritics, false)
        return tokenize((buffer as String).lowercased())
    }

    private static func contextualSyllables(_ phrase: String, standard: [String]) -> [[String]] {
        let text = phrase as NSString
        let range = CFRange(location: 0, length: text.length)
        let flags = kCFStringTokenizerUnitWordBoundary | kCFStringTokenizerAttributeLatinTranscription
        guard let tokenizer = CFStringTokenizerCreate(nil, phrase as CFString, range, flags, zhCNLocale as CFLocale),
              standard.count == phrase.count else { return [standard] }
        var offset = 0
        var words: [[String]] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
            let token = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let count = text.substring(with: NSRange(location: token.location, length: token.length)).count
            guard count > 0, offset + count <= standard.count else { return [standard] }
            let baseline = Array(standard[offset..<(offset + count)])
            if let reading = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                let roman = tokenize(normalize(reading)).joined()
                words.append(splitReading(roman, near: baseline))
            } else {
                words.append(baseline)
            }
            offset += count
        }
        return offset == standard.count ? words : [standard]
    }

    // Word-level readings preserve polyphones but omit syllable boundaries. Prefer the split
    // closest to the syllables supplied by the character-level Mandarin transform.
    private static func splitReading(_ reading: String, near baseline: [String]) -> [String] {
        guard !reading.isEmpty, reading != baseline.joined() else { return baseline }
        if baseline.count == 1 { return [reading] }
        let letters = Array(reading)
        var paths: [Int: (cost: Int, values: [String])] = [0: (0, [])]
        for (index, syllable) in baseline.enumerated() {
            var next: [Int: (cost: Int, values: [String])] = [:]
            for start in paths.keys.sorted() {
                guard let prior = paths[start] else { continue }
                let end = min(start + 6, letters.count - (baseline.count - index - 1))
                guard end > start else { continue }
                for boundary in (start + 1)...end {
                    let part = String(letters[start..<boundary])
                    let cost = prior.cost + editDistance(part, syllable)
                    if cost < (next[boundary]?.cost ?? Int.max) {
                        next[boundary] = (cost, prior.values + [part])
                    }
                }
            }
            paths = next
        }
        return paths[letters.count]?.values ?? baseline
    }

    private static func editDistance(_ left: String, _ right: String) -> Int {
        let lhs = Array(left)
        let rhs = Array(right)
        var previous = Array(0...rhs.count)
        for (i, a) in lhs.enumerated() {
            var row = [i + 1]
            for (j, b) in rhs.enumerated() {
                row.append(min(row[j] + 1, previous[j + 1] + 1, previous[j] + (a == b ? 0 : 1)))
            }
            previous = row
        }
        return previous[rhs.count]
    }

    static func index(_ text: String) -> String {
        tokenize(text).joined(separator: " ")
    }

    private static let queryStopWords: Set<String> = [
        "的", "了", "和", "与", "或", "在", "是", "有", "之", "中", "上", "下", "把", "给", "被", "将", "让", "等",
        "the", "and", "for", "with", "from", "that", "this", "into", "of", "in", "on", "at", "to", "a", "an", "or"
    ]

    /// Segments a natural-language query (including unspaced Chinese phrases like "夏日海边蓝天女孩")
    /// into deduplicated semantic search terms using macOS `CFStringTokenizer` word boundaries.
    static func queryTerms(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results: [String] = []
        var seen = Set<String>()
        func appendTerm(_ raw: String) {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            let norm = normalize(cleaned)
            guard !norm.isEmpty, !queryStopWords.contains(norm) else { return }
            if norm.count == 1 && !containsHan(norm) { return }
            if seen.insert(norm).inserted {
                results.append(cleaned)
            }
        }

        // First split on explicit whitespace / punctuation so user-separated chunks stay intact.
        let chunks = trimmed.split { !$0.isLetter && !$0.isNumber && !hasHan($0) }.map(String.init)
        for chunk in chunks {
            guard !chunk.isEmpty else { continue }
            if !containsHan(chunk) {
                appendTerm(chunk)
                continue
            }
            // Segment CJK (or mixed CJK+ASCII) chunk via CFStringTokenizer word boundaries.
            let ns = chunk as NSString
            let range = CFRange(location: 0, length: ns.length)
            if let tokenizer = CFStringTokenizerCreate(
                nil,
                chunk as CFString,
                range,
                kCFStringTokenizerUnitWordBoundary,
                zhCNLocale as CFLocale
            ) {
                var extractedAny = false
                while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
                    let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                    guard tokenRange.length > 0 else { continue }
                    let piece = ns.substring(with: NSRange(location: tokenRange.location, length: tokenRange.length))
                    if piece.contains(where: { $0.isLetter || $0.isNumber || hasHan($0) }) {
                        appendTerm(piece)
                        extractedAny = true
                    }
                }
                if !extractedAny {
                    appendTerm(chunk)
                }
            } else {
                appendTerm(chunk)
            }
        }
        return results
    }

    static func ftsQuery(_ text: String) -> String {
        var clauses: [String] = []
        let chunks = text.split { !$0.isLetter && !$0.isNumber && !hasHan($0) }
        for chunk in chunks {
            var han: [String] = []
            for token in tokenize(String(chunk)) {
                if token.count == 1, let character = token.first, hasHan(character) {
                    han.append(token)
                } else {
                    if !han.isEmpty {
                        clauses.append("\"\(han.joined(separator: " "))\"")
                        han.removeAll()
                    }
                    clauses.append("\"\(token)\"*")
                }
            }
            if !han.isEmpty { clauses.append("\"\(han.joined(separator: " "))\"") }
        }
        return clauses.joined(separator: " AND ")
    }

    static func fuzzyScore(query: String, candidate: String) -> Double? {
        fuzzyScore(normalizedQuery: normalize(query), candidate: candidate)
    }

    static func fuzzyScore(normalizedQuery needle: String, candidate: String) -> Double? {
        guard !needle.isEmpty else { return 0.4 }
        let (text, candidateIsASCII) = normalizeWithASCIIFlag(candidate)
        if text == needle { return 1 }
        if text.hasPrefix(needle) { return 0.9 }
        if text.contains(needle) { return 0.8 }
        // Pinyin output is strictly lowercase ASCII Latin letters and spaces; skip when candidate
        // is pure ASCII, contains no Han characters, or query contains non-ASCII characters.
        guard !candidateIsASCII, isPureASCII(needle), containsHan(candidate) else { return nil }
        let phonetics = pinyin(candidate)
        let full = normalize(phonetics.full)
        if full.contains(needle) { return 0.75 }
        if phonetics.initials.contains(needle) { return 0.65 }
        return nil
    }

    static func normalize(_ text: String) -> String {
        normalizeWithASCIIFlag(text).normalized
    }

    private static func isPureASCII(_ text: String) -> Bool {
        if let result = text.utf8.withContiguousStorageIfAvailable({ buf -> Bool in
            for i in 0..<buf.count {
                if buf[i] >= 0x80 { return false }
            }
            return true
        }) {
            return result
        }
        for byte in text.utf8 where byte >= 0x80 {
            return false
        }
        return true
    }

    private static func normalizeWithASCIIFlag(_ text: String) -> (normalized: String, isASCII: Bool) {
        if let fast = text.utf8.withContiguousStorageIfAvailable({ buf -> String? in
            let count = buf.count
            var hasUpper = false
            for i in 0..<count {
                let b = buf[i]
                if b >= 0x80 { return nil }
                if b >= 0x41 && b <= 0x5A { hasUpper = true }
            }
            var start = 0
            var end = count
            while start < end && isASCIIWhitespace(buf[start]) { start &+= 1 }
            while end > start && isASCIIWhitespace(buf[end &- 1]) { end &-= 1 }
            let trimmedCount = end &- start
            guard trimmedCount > 0 else { return "" }
            if !hasUpper {
                if start == 0 && end == count { return text }
                return String(decoding: UnsafeBufferPointer(rebasing: buf[start..<end]), as: UTF8.self)
            }
            return String(unsafeUninitializedCapacity: trimmedCount) { out in
                for i in 0..<trimmedCount {
                    let b = buf[start &+ i]
                    out[i] = (b >= 0x41 && b <= 0x5A) ? (b &+ 32) : b
                }
                return trimmedCount
            }
        }), let asciiResult = fast {
            return (asciiResult, true)
        }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: posixLocale)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (folded, false)
    }

    @inline(__always)
    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }
}
