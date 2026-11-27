package com.charkle.android.ui.capture

/**
 * Result of parsing raw pasted text or an Android system Share payload (`ACTION_SEND`).
 */
data class ExtractedShareLink(
    val url: String,
    val host: String,
    val platformLabel: String?,
    val isSocialPlatform: Boolean,
    val companionTitle: String?,
    val companionNotes: String?
)

/**
 * Extracts and cleans `http://`, `https://`, and `www.` URLs from mixed mobile share copy
 * (e.g. Xiaohongshu copy with CJK + emoji + boilerplate, X/Twitter copy, Chrome shares)
 * so downstream ingestion always receives a valid URL without failing on surrounding prose.
 */
object SharedContentParser {

    private val SOCIAL_HOSTS = setOf(
        "xhslink.com",
        "xiaohongshu.com",
        "x.com",
        "twitter.com",
        "t.co",
        "threads.net",
        "threads.com",
        "bsky.app",
        "instagram.com",
        "pixiv.net",
        "bilibili.com",
        "b23.tv",
        "youtube.com",
        "youtu.be"
    )

    private val PRIORITY_HOSTS = SOCIAL_HOSTS + setOf(
        "github.com",
        "behance.net",
        "dribbble.com",
        "figma.com",
        "pinterest.com",
        "pin.it"
    )

    private val PAIR_WRAPPERS = listOf(
        '<' to '>',
        '"' to '"',
        '\'' to '\'',
        '(' to ')',
        '[' to ']',
        '「' to '」',
        '《' to '》',
        '“' to '”',
        '（' to '）',
        '【' to '】'
    )

    private val LEADING_STOP = setOf('<', '"', '\'', '「', '《', '“', '‘', '（', '【')
    private val TRAILING_STOP = setOf(
        '.', ',', ';', '!', '?', ':',
        '。', '，', '；', '！', '？', '、',
        '”', '’', '）', '】', '」', '》', '>', '"', '\''
    )

    private val BOILERPLATE_PATTERNS = listOf(
        Regex("""复制本条信息[，,]?\s*打开【?小红书】?.*$"""),
        Regex("""复制后打开【?小红书】?.*$"""),
        Regex("""长按复制此条消息.*$""")
    )

    fun extractLink(rawText: String, subject: String? = null): ExtractedShareLink? {
        val trimmed = rawText.trim()
        if (trimmed.isEmpty()) return null

        val candidates = collectCandidateUrls(trimmed)
        if (candidates.isEmpty()) return null

        val chosen = candidates.firstOrNull { isPriorityHost(it.second) } ?: candidates.first()
        val (url, host) = chosen
        val platformLabel = detectPlatformLabel(host)
        val isSocial = isSocialHost(host)

        val cleanSubject = subject
            ?.trim()
            ?.takeIf { it.isNotEmpty() && !it.equals(url, ignoreCase = true) && !it.startsWith("http", ignoreCase = true) }

        val cleanedCopy = stripUrlAndBoilerplate(trimmed, url)

        // Preserve authoritative title/body extraction from Rust's SocialPostResolver for social platforms;
        // only forward companion title/notes for generic web pages.
        val companionTitle = if (isSocial) null else cleanSubject
        val companionNotes = if (isSocial) {
            null
        } else {
            cleanedCopy.takeIf { it.isNotBlank() && !it.equals(cleanSubject, ignoreCase = true) }
        }

        return ExtractedShareLink(
            url = url,
            host = host,
            platformLabel = platformLabel,
            isSocialPlatform = isSocial,
            companionTitle = companionTitle,
            companionNotes = companionNotes
        )
    }

    private fun collectCandidateUrls(text: String): List<Pair<String, String>> {
        val results = mutableListOf<Pair<String, String>>()
        val seen = LinkedHashSet<String>()

        // Fast path: the entire trimmed input is a single URL
        parseStandaloneUrl(text)?.let { pair ->
            if (seen.add(pair.first)) results.add(pair)
            return results
        }

        var idx = 0
        val len = text.length
        while (idx < len) {
            val rest = text.substring(idx)
            val prefixLen = when {
                rest.startsWith("https://", ignoreCase = true) -> 8
                rest.startsWith("http://", ignoreCase = true) -> 7
                rest.startsWith("www.", ignoreCase = true) -> 4
                else -> 0
            }
            if (prefixLen > 0) {
                val prevIsIdent = idx > 0 && text[idx - 1].let {
                    it.isLetterOrDigit() && it.code < 128 || it == '_' || it == '.'
                }
                if (!prevIsIdent) {
                    var end = rest.length
                    for (off in 0 until rest.length) {
                        val c = rest[off]
                        if (isUrlBoundaryChar(c)) {
                            end = off
                            break
                        }
                    }
                    val slice = rest.substring(0, end)
                    parseStandaloneUrl(slice)?.let { pair ->
                        if (seen.add(pair.first)) results.add(pair)
                    }
                    idx += end.coerceAtLeast(prefixLen)
                    continue
                }
            }
            idx++
        }
        return results
    }

    private fun isUrlBoundaryChar(c: Char): Boolean {
        if (c.isWhitespace() || c.isISOControl()) return true
        if (Character.isHighSurrogate(c) || Character.isLowSurrogate(c)) return true
        if (c.code >= 0x2E80) return true
        return c == '<' || c == '>' || c == '"' || c == '\'' || c == '`'
    }

    private fun parseStandaloneUrl(raw: String): Pair<String, String>? {
        val cleaned = stripWrappersAndTrailingPunctuation(raw.trim())
        if (cleaned.isEmpty() || cleaned.any { it.isWhitespace() || it.isISOControl() }) return null

        val normalized = when {
            cleaned.startsWith("https://", ignoreCase = true) -> "https://" + cleaned.substring(8)
            cleaned.startsWith("http://", ignoreCase = true) -> "http://" + cleaned.substring(7)
            cleaned.startsWith("www.", ignoreCase = true) -> {
                val remainder = cleaned.substring(4)
                if (!remainder.contains('.') || remainder.startsWith('.')) return null
                "https://$cleaned"
            }
            else -> return null
        }

        val host = extractValidatedHost(normalized) ?: return null
        return normalized to host
    }

    private fun stripWrappersAndTrailingPunctuation(input: String): String {
        var s = input
        var changed = true
        while (changed && s.isNotEmpty()) {
            changed = false
            for ((open, close) in PAIR_WRAPPERS) {
                if (s.length >= 2 && s.first() == open && s.last() == close) {
                    s = s.substring(1, s.length - 1).trim()
                    changed = true
                }
            }
            while (s.isNotEmpty() && s.first() in LEADING_STOP) {
                s = s.substring(1)
                changed = true
            }
            while (s.isNotEmpty()) {
                val last = s.last()
                val shouldTrim = when (last) {
                    in TRAILING_STOP -> true
                    ')' -> s.count { it == ')' } > s.count { it == '(' }
                    ']' -> s.count { it == ']' } > s.count { it == '[' }
                    else -> false
                }
                if (shouldTrim) {
                    s = s.dropLast(1)
                    changed = true
                } else {
                    break
                }
            }
        }
        return s
    }

    private fun extractValidatedHost(url: String): String? {
        val afterScheme = when {
            url.startsWith("https://") -> url.substring(8)
            url.startsWith("http://") -> url.substring(7)
            else -> return null
        }
        if (afterScheme.isEmpty()) return null
        val authorityEnd = afterScheme.indexOfAny(charArrayOf('/', '?', '#')).let {
            if (it == -1) afterScheme.length else it
        }
        var authority = afterScheme.substring(0, authorityEnd)
        val atIdx = authority.lastIndexOf('@')
        if (atIdx >= 0) authority = authority.substring(atIdx + 1)
        if (authority.isEmpty()) return null

        val host = if (authority.startsWith("[")) {
            val close = authority.indexOf(']')
            if (close <= 1) return null
            authority.substring(0, close + 1).lowercase()
        } else {
            val colon = authority.indexOf(':')
            if (colon >= 0) {
                val portPart = authority.substring(colon + 1)
                if (portPart.isEmpty() || portPart.any { !it.isDigit() }) return null
                authority.substring(0, colon).lowercase()
            } else {
                authority.lowercase()
            }
        }

        if (host.isEmpty()) return null
        if (host == "localhost" || host.startsWith("[")) return host
        val labels = host.split('.')
        if (labels.size < 2) return null
        if (labels.any { it.isEmpty() || it.startsWith('-') || it.endsWith('-') }) return null
        val validChars = labels.all { label ->
            label.all { c -> (c in 'a'..'z') || (c in '0'..'9') || c == '-' || c.code > 127 }
        }
        if (!validChars) return null
        val tld = labels.last()
        if (tld.length < 2) return null
        return host.removePrefix("www.").ifBlank { host }
    }

    private fun matchesDomain(host: String, domain: String): Boolean {
        return host == domain || host.endsWith(".$domain")
    }

    private fun isSocialHost(host: String): Boolean =
        SOCIAL_HOSTS.any { matchesDomain(host, it) }

    private fun isPriorityHost(host: String): Boolean =
        PRIORITY_HOSTS.any { matchesDomain(host, it) }

    private fun detectPlatformLabel(host: String): String? = when {
        matchesDomain(host, "xhslink.com") || matchesDomain(host, "xiaohongshu.com") -> "小红书"
        matchesDomain(host, "x.com") || matchesDomain(host, "twitter.com") || matchesDomain(host, "t.co") -> "X"
        matchesDomain(host, "threads.net") || matchesDomain(host, "threads.com") -> "Threads"
        matchesDomain(host, "bsky.app") -> "Bluesky"
        matchesDomain(host, "github.com") -> "GitHub"
        matchesDomain(host, "bilibili.com") || matchesDomain(host, "b23.tv") -> "Bilibili"
        matchesDomain(host, "youtube.com") || matchesDomain(host, "youtu.be") -> "YouTube"
        matchesDomain(host, "instagram.com") -> "Instagram"
        matchesDomain(host, "pixiv.net") -> "Pixiv"
        matchesDomain(host, "behance.net") -> "Behance"
        matchesDomain(host, "dribbble.com") -> "Dribbble"
        matchesDomain(host, "figma.com") -> "Figma"
        else -> null
    }

    private fun stripUrlAndBoilerplate(rawText: String, extractedUrl: String): String {
        var result = rawText.replace(extractedUrl, " ", ignoreCase = true)
        val withoutScheme = extractedUrl.removePrefix("https://").removePrefix("http://")
        result = result.replace(withoutScheme, " ", ignoreCase = true)
        for (pattern in BOILERPLATE_PATTERNS) {
            result = pattern.replace(result, "")
        }
        return result
            .lines()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .joinToString("\n")
            .trim()
    }
}
