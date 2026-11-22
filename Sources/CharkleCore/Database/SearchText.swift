import CoreFoundation
import Foundation

nonisolated enum SearchText {
    static func hasHan(_ char: Character) -> Bool {
        guard let value = char.unicodeScalars.first?.value else { return false }
        return (0x3400...0x9FFF).contains(value) || (0x20000...0x323AF).contains(value)
    }

    static func tokenize(_ text: String) -> [String] {
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
        return (full.joined(separator: " "), initials.joined(separator: " "))
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
        guard let tokenizer = CFStringTokenizerCreate(nil, phrase as CFString, range, flags, Locale(identifier: "zh_CN") as CFLocale),
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
        let needle = normalize(query)
        guard !needle.isEmpty else { return 0.4 }
        let text = normalize(candidate)
        if text == needle { return 1 }
        if text.hasPrefix(needle) { return 0.9 }
        if text.contains(needle) { return 0.8 }
        let phonetics = pinyin(candidate)
        let full = normalize(phonetics.full)
        if full.contains(needle) { return 0.75 }
        if phonetics.initials.contains(needle) { return 0.65 }
        return nil
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
