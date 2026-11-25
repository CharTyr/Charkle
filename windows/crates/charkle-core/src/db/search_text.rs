//! Chinese / English tokenization, full pinyin & initials generation,
//! FTS5 query construction, and Quick Jump fuzzy scoring.
//!
//! Mirrors `Sources/CharkleCore/Database/SearchText.swift`.

use std::collections::HashSet;

use pinyin::ToPinyinMulti;

/// Returns true when `ch` is a CJK Unified Ideograph.
pub fn has_han(ch: char) -> bool {
    let v = ch as u32;
    (0x3400..=0x9FFF).contains(&v) || (0x20000..=0x323AF).contains(&v)
}

/// Returns true when `text` contains at least one CJK Unified Ideograph.
pub fn contains_han(text: &str) -> bool {
    if text.is_ascii() {
        return false;
    }
    text.chars().any(has_han)
}

const QUERY_STOP_WORDS: &[&str] = &[
    "的", "了", "和", "与", "或", "在", "是", "有", "之", "中", "上", "下", "把", "给", "被", "将",
    "让", "等", "the", "and", "for", "with", "from", "that", "this", "into", "of", "in", "on",
    "at", "to", "a", "an", "or",
];

/// Segments a natural-language query (including unspaced Chinese phrases such as
/// `"夏日海边蓝天女孩"`) into deduplicated semantic search terms with stopword filtering
/// and CJK bigram/trigram fallback so unspaced CJK phrases match tags & FTS cleanly.
pub fn query_terms(text: &str) -> Vec<String> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }

    let mut results = Vec::new();
    let mut seen = HashSet::new();
    let mut append_term = |raw: &str| {
        let cleaned = raw.trim();
        if cleaned.is_empty() {
            return;
        }
        let norm = normalize(cleaned);
        if norm.is_empty() || QUERY_STOP_WORDS.contains(&norm.as_str()) {
            return;
        }
        if norm.chars().count() == 1 && !contains_han(&norm) {
            return;
        }
        if seen.insert(norm) {
            results.push(cleaned.to_string());
        }
    };

    for chunk in trimmed.split(|c: char| !c.is_alphanumeric() && !has_han(c)) {
        if chunk.is_empty() {
            continue;
        }
        // Split mixed Latin/digit vs CJK runs cleanly
        let mut run = String::new();
        let mut run_is_han: Option<bool> = None;
        let mut sub_chunks: Vec<(String, bool)> = Vec::new();
        for ch in chunk.chars() {
            let is_h = has_han(ch);
            match run_is_han {
                Some(prev) if prev == is_h => run.push(ch),
                Some(prev) => {
                    if !run.is_empty() {
                        sub_chunks.push((std::mem::take(&mut run), prev));
                    }
                    run.push(ch);
                    run_is_han = Some(is_h);
                }
                None => {
                    run.push(ch);
                    run_is_han = Some(is_h);
                }
            }
        }
        if let Some(prev) = run_is_han {
            if !run.is_empty() {
                sub_chunks.push((run, prev));
            }
        }

        for (sub, is_han_run) in sub_chunks {
            if !is_han_run {
                append_term(&sub);
                continue;
            }
            let chars: Vec<char> = sub.chars().collect();
            if chars.len() <= 2 {
                append_term(&sub);
                continue;
            }
            // Keep full short phrase (<= 4 chars), then emit overlapping 2-char & 3-char windows
            // (bigram + trigram) so unspaced phrases like "夏日海边蓝天女孩" reliably recall
            // "夏日", "海边", "蓝天", "女孩", "极简风", "蓝色调", etc.
            if chars.len() <= 4 {
                append_term(&sub);
            }
            let mut idx = 0usize;
            while idx < chars.len() {
                if QUERY_STOP_WORDS.contains(&chars[idx].to_string().as_str()) {
                    idx += 1;
                    continue;
                }
                if idx + 2 <= chars.len() {
                    let bi: String = chars[idx..idx + 2].iter().collect();
                    if !bi
                        .chars()
                        .any(|c| QUERY_STOP_WORDS.contains(&c.to_string().as_str()))
                    {
                        append_term(&bi);
                    }
                }
                if idx + 3 <= chars.len() && chars.len() <= 10 {
                    let tri: String = chars[idx..idx + 3].iter().collect();
                    if !tri
                        .chars()
                        .any(|c| QUERY_STOP_WORDS.contains(&c.to_string().as_str()))
                    {
                        append_term(&tri);
                    }
                }
                idx += 1;
            }
        }
    }
    results
}

/// Tokenizes text by separating each Han character individually while preserving
/// contiguous alphanumeric Latin/digit words and folding full-width ASCII (`FF01..=FF5E`).
pub fn tokenize(text: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut word = String::new();
    for raw_ch in text.chars() {
        let ch = match raw_ch as u32 {
            0x3000 => ' ',
            0xFF01..=0xFF5E => char::from_u32(raw_ch as u32 - 0xFEE0).unwrap_or(raw_ch),
            _ => raw_ch,
        };
        if has_han(ch) || !ch.is_alphanumeric() {
            if !word.is_empty() {
                tokens.push(std::mem::take(&mut word));
            }
            if has_han(ch) {
                tokens.push(ch.to_string());
            }
        } else {
            word.push(ch);
        }
    }
    if !word.is_empty() {
        tokens.push(word);
    }
    tokens
}

/// Extracts `(full_pinyin, initials)` across all Han phrases in `text`, including
/// both space-separated and joined forms plus polyphone variants.
pub fn pinyin(text: &str) -> (String, String) {
    let mut full_parts: Vec<String> = Vec::new();
    let mut initial_parts: Vec<String> = Vec::new();
    let mut seen_full: HashSet<String> = HashSet::new();
    let mut seen_initials: HashSet<String> = HashSet::new();

    let mut phrase = String::new();
    let flush_phrase = |phrase: &str,
                        full_parts: &mut Vec<String>,
                        initial_parts: &mut Vec<String>,
                        seen_full: &mut HashSet<String>,
                        seen_initials: &mut HashSet<String>| {
        if phrase.is_empty() {
            return;
        }
        let mut primary_syllables: Vec<String> = Vec::new();
        let mut alt_syllables: Vec<String> = Vec::new();
        let mut has_alt = false;

        for ch in phrase.chars() {
            if let Some(multi) = ch.to_pinyin_multi() {
                let mut iter = multi.into_iter().map(|p| p.plain().to_ascii_lowercase());
                if let Some(first) = iter.next() {
                    if !first.is_empty() {
                        primary_syllables.push(first.clone());
                        if let Some(second) = iter.find(|s| !s.is_empty() && s != &first) {
                            has_alt = true;
                            alt_syllables.push(second);
                        } else {
                            alt_syllables.push(first);
                        }
                    }
                }
            }
        }

        let mut push_variant = |syllables: &[String]| {
            if syllables.is_empty() {
                return;
            }
            let spaced = syllables.join(" ");
            if seen_full.insert(spaced.clone()) {
                full_parts.push(spaced);
            }

            // Emit syllable-aligned suffixes so FTS5 prefix queries (`"haibao"*`, `"hb"*`)
            // match any mid-phrase Chinese word in O(1), matching macOS CFStringTokenizer recall.
            let max_suffix_starts = syllables.len().min(24);
            for start in 0..max_suffix_starts {
                let end = (start + 12).min(syllables.len());
                let slice = &syllables[start..end];
                let joined = slice.concat();
                if seen_full.insert(joined.clone()) {
                    full_parts.push(joined);
                }
                let initials: String = slice.iter().filter_map(|s| s.chars().next()).collect();
                if !initials.is_empty() && seen_initials.insert(initials.clone()) {
                    initial_parts.push(initials);
                }
            }
            if syllables.len() > 12 {
                let full_joined = syllables.concat();
                if seen_full.insert(full_joined.clone()) {
                    full_parts.push(full_joined);
                }
                let full_initials: String =
                    syllables.iter().filter_map(|s| s.chars().next()).collect();
                if !full_initials.is_empty() && seen_initials.insert(full_initials.clone()) {
                    initial_parts.push(full_initials);
                }
            }
        };

        push_variant(&primary_syllables);
        if has_alt {
            push_variant(&alt_syllables);
        }
    };

    for ch in text.chars() {
        if has_han(ch) {
            phrase.push(ch);
        } else if !phrase.is_empty() {
            flush_phrase(
                &phrase,
                &mut full_parts,
                &mut initial_parts,
                &mut seen_full,
                &mut seen_initials,
            );
            phrase.clear();
        }
    }
    if !phrase.is_empty() {
        flush_phrase(
            &phrase,
            &mut full_parts,
            &mut initial_parts,
            &mut seen_full,
            &mut seen_initials,
        );
    }

    (full_parts.join(" "), initial_parts.join(" "))
}

/// Produces the space-delimited FTS5 index representation of `text`.
pub fn index(text: &str) -> String {
    tokenize(text).join(" ")
}

/// Builds a safe FTS5 `MATCH` query expression matching Swift `SearchText.ftsQuery`.
pub fn fts_query(text: &str) -> String {
    let mut clauses: Vec<String> = Vec::new();
    for chunk in text.split(|c: char| !c.is_alphanumeric() && !has_han(c)) {
        if chunk.is_empty() {
            continue;
        }
        let mut han: Vec<String> = Vec::new();
        for token in tokenize(chunk) {
            let mut chars = token.chars();
            let is_single_han =
                matches!((chars.next(), chars.next()), (Some(c), None) if has_han(c));
            if is_single_han {
                han.push(token);
            } else {
                if !han.is_empty() {
                    clauses.push(format!("\"{}\"", han.join(" ")));
                    han.clear();
                }
                let escaped = token.replace('"', "\"\"");
                clauses.push(format!("\"{escaped}\"*"));
            }
        }
        if !han.is_empty() {
            clauses.push(format!("\"{}\"", han.join(" ")));
        }
    }
    clauses.join(" AND ")
}

/// Case-insensitive, full-width-insensitive, whitespace-trimmed normalization matching Swift.
pub fn normalize(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.trim().chars() {
        // Fold full-width ASCII (`FF01..=FF5E`) and ideographic space (`3000`)
        let mapped = match ch as u32 {
            0x3000 => ' ',
            0xFF01..=0xFF5E => char::from_u32(ch as u32 - 0xFEE0).unwrap_or(ch),
            _ => ch,
        };
        for lc in mapped.to_lowercase() {
            out.push(strip_common_diacritic(lc));
        }
    }
    out.trim().to_string()
}

fn strip_common_diacritic(ch: char) -> char {
    match ch {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' => 'a',
        'ç' => 'c',
        'è' | 'é' | 'ê' | 'ë' | 'ē' => 'e',
        'ì' | 'í' | 'î' | 'ï' | 'ī' => 'i',
        'ñ' => 'n',
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ō' => 'o',
        'ù' | 'ú' | 'û' | 'ü' | 'ū' => 'u',
        'ý' | 'ÿ' => 'y',
        other => other,
    }
}

/// Quick Jump fuzzy ranking score matching Swift `SearchText.fuzzyScore`.
pub fn fuzzy_score(query: &str, candidate: &str) -> Option<f64> {
    let needle = normalize(query);
    if needle.is_empty() {
        return Some(0.4);
    }
    let text = normalize(candidate);
    if text == needle {
        return Some(1.0);
    }
    if text.starts_with(&needle) {
        return Some(0.9);
    }
    if text.contains(&needle) {
        return Some(0.8);
    }
    let (full, initials) = pinyin(candidate);
    let full_norm = normalize(&full);
    if full_norm.contains(&needle) {
        return Some(0.75);
    }
    if initials.contains(&needle) {
        return Some(0.65);
    }
    None
}
