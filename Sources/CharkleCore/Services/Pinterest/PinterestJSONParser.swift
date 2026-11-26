import Foundation

/// Pure, defensive parser for Pinterest web resource JSON payloads (`UserHomefeedResource`,
/// `BaseSearchResource`, `PinResource`, `RelatedModulesResource`, `RelatedPinFeedResource`,
/// `UserResource`, `BoardsResource`, `BoardFeedResource`).
public nonisolated enum PinterestJSONParser {
    /// Extracts a numeric Pinterest Pin ID from a Pinterest Pin URL (`pinterest.com/pin/<id>/`).
    public static func extractPinID(from rawURL: String) -> String? {
        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host()?.lowercased(),
              host.contains("pinterest.") else {
            return nil
        }
        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard let idx = segments.firstIndex(where: { $0.lowercased() == "pin" }),
              idx + 1 < segments.count else {
            return nil
        }
        let candidate = segments[idx + 1]
        guard !candidate.isEmpty, candidate.count <= 30, candidate.allSatisfy(\.isNumber) else {
            return nil
        }
        return candidate
    }

    /// Parses authenticated user info from `UserResource/get/` or embedded page state.
    public static func parseAccount(from data: Data) -> PinterestAccount? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let payload = (root["resource_response"] as? [String: Any])?["data"] as? [String: Any] ?? root
        let username = nonEmptyString(payload["username"])
        guard let username else { return nil }
        let isAuthenticated = (payload["is_authenticated"] as? Bool) ?? true
        guard isAuthenticated else { return nil }

        let fullName = nonEmptyString(payload["full_name"])
            ?? nonEmptyString(payload["first_name"])
            ?? username
        let avatarStr = nonEmptyString(payload["image_medium_url"])
            ?? nonEmptyString(payload["image_large_url"])
            ?? nonEmptyString(payload["image_small_url"])
            ?? nonEmptyString(payload["profile_image"])
        let avatarURL = avatarStr.flatMap(URL.init(string:))
        let profileURL = URL(string: "https://www.pinterest.com/\(username)/")
        return PinterestAccount(
            username: username,
            fullName: fullName,
            avatarURL: avatarURL,
            profileURL: profileURL
        )
    }

    /// Parses a paginated pin feed (`UserHomefeedResource`, `BaseSearchResource`, `BoardFeedResource`,
    /// `RelatedModulesResource`, `RelatedPinFeedResource`).
    public static func parseFeedPage(from data: Data) -> PinterestFeedPage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return PinterestFeedPage(pins: [], bookmark: nil, hasMore: false)
        }

        let response = root["resource_response"] as? [String: Any]
        let bookmark = extractBookmark(root: root, response: response)
        let rawData = response?["data"] ?? root["data"]

        var rawItems: [[String: Any]] = []
        if let list = rawData as? [[String: Any]] {
            rawItems = list
        } else if let dict = rawData as? [String: Any] {
            if let results = dict["results"] as? [[String: Any]] {
                rawItems = results
            } else if let pins = dict["pins"] as? [[String: Any]] {
                rawItems = pins
            } else if let items = dict["items"] as? [[String: Any]] {
                rawItems = items
            }
        }

        var pins: [PinterestPin] = []
        var seen = Set<String>()
        pins.reserveCapacity(rawItems.count)

        for raw in rawItems {
            if let pin = parsePinDictionary(raw), seen.insert(pin.id).inserted {
                pins.append(pin)
            } else if let nested = raw["objects"] as? [[String: Any]] {
                for sub in nested {
                    if let pin = parsePinDictionary(sub), seen.insert(pin.id).inserted {
                        pins.append(pin)
                    }
                }
            }
        }

        let hasMore = bookmark != nil && bookmark != "-end-"
        return PinterestFeedPage(pins: pins, bookmark: hasMore ? bookmark : nil, hasMore: hasMore)
    }

    /// Parses a single detailed Pin from `PinResource/get/`.
    public static func parseSinglePin(from data: Data) -> PinterestPin? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let response = root["resource_response"] as? [String: Any]
        guard let dict = (response?["data"] as? [String: Any]) ?? (root["data"] as? [String: Any]) else {
            return nil
        }
        return parsePinDictionary(dict, allowPromoted: true)
    }

    /// Parses user boards from `BoardsResource/get/` (first page convenience wrapper).
    public static func parseBoards(from data: Data) -> [PinterestBoard] {
        parseBoardsPage(from: data).boards
    }

    /// Parses a paginated page of user boards from `BoardsResource/get/`.
    public static func parseBoardsPage(from data: Data) -> (boards: [PinterestBoard], bookmark: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], nil)
        }
        let response = root["resource_response"] as? [String: Any]
        let bookmark = extractBookmark(root: root, response: response)
        let rawList = (response?["data"] as? [[String: Any]]) ?? []
        var boards: [PinterestBoard] = []
        var seen = Set<String>()
        for item in rawList {
            guard let id = stringifyID(item["id"]), seen.insert(id).inserted,
                  let name = nonEmptyString(item["name"]),
                  let urlPath = nonEmptyString(item["url"]) else {
                continue
            }
            let count = (item["pin_count"] as? Int) ?? (item["pin_count"] as? NSNumber)?.intValue ?? 0
            let coverStr = nonEmptyString(item["image_cover_hd_url"])
                ?? nonEmptyString(item["image_cover_url"])
                ?? nonEmptyString(item["image_thumbnail_url"])
                ?? (item["pin_thumbnail_urls"] as? [String])?.first
            boards.append(PinterestBoard(
                id: id,
                name: name,
                urlPath: urlPath,
                pinCount: count,
                coverURL: coverStr.flatMap(URL.init(string:))
            ))
        }
        let nextBookmark = (bookmark != nil && bookmark != "-end-") ? bookmark : nil
        return (boards, nextBookmark)
    }

    /// Extracts pins embedded directly inside a Pinterest HTML page (fallback when resource endpoints return empty).
    public static func parsePinsFromHTML(_ html: String) -> [PinterestPin] {
        var found: [PinterestPin] = []
        var seen = Set<String>()

        let patterns = [
            #"<script[^>]*id="__PWS_INITIAL_PROPS__"[^>]*>([\s\S]*?)</script>"#,
            #"<script[^>]*data-relay-response="true"[^>]*>([\s\S]*?)</script>"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = html as NSString
            let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
            for match in matches where match.numberOfRanges > 1 {
                let jsonStr = ns.substring(with: match.range(at: 1))
                guard let jsonData = jsonStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: jsonData) else {
                    continue
                }
                collectPinsRecursively(from: obj, depth: 0, into: &found, seen: &seen)
            }
        }
        return found
    }

    // MARK: - Internal Helpers

    private static func collectPinsRecursively(
        from value: Any,
        depth: Int,
        into results: inout [PinterestPin],
        seen: inout Set<String>
    ) {
        guard depth < 10, results.count < 120 else { return }
        if let dict = value as? [String: Any] {
            if let pin = parsePinDictionary(dict), seen.insert(pin.id).inserted {
                results.append(pin)
                return
            }
            for (_, v) in dict {
                collectPinsRecursively(from: v, depth: depth + 1, into: &results, seen: &seen)
            }
        } else if let array = value as? [Any] {
            for item in array {
                collectPinsRecursively(from: item, depth: depth + 1, into: &results, seen: &seen)
            }
        }
    }

    public static func parsePinDictionary(_ dict: [String: Any], allowPromoted: Bool = false) -> PinterestPin? {
        if !allowPromoted {
            if (dict["is_promoted"] as? Bool) == true { return nil }
            if (dict["promoted_is_removable"] as? Bool) == true { return nil }
            if let type = dict["type"] as? String, type != "pin" { return nil }
        }

        guard let id = stringifyID(dict["id"]),
              !id.isEmpty,
              id.allSatisfy(\.isNumber) else {
            return nil
        }

        guard let images = dict["images"] as? [String: Any] else { return nil }

        let tierOrig = parseImageTier(images["orig"])
        let tier736 = parseImageTier(images["736x"])
        let tier564 = parseImageTier(images["564x"])
        let tier474 = parseImageTier(images["474x"])
        let tier236 = parseImageTier(images["236x"])

        guard let bestOriginal = tierOrig ?? tier736 ?? tier564 ?? tier474 ?? tier236 else {
            return nil
        }
        let bestPreview = tier736 ?? tier564 ?? tier474 ?? bestOriginal
        let bestThumb = tier474 ?? tier236 ?? bestPreview

        let width = bestOriginal.width > 1 ? bestOriginal.width : (bestPreview.width > 1 ? bestPreview.width : 736)
        let height = bestOriginal.height > 1 ? bestOriginal.height : (bestPreview.height > 1 ? bestPreview.height : 980)

        let title = nonEmptyString(dict["grid_title"])
            ?? nonEmptyString(dict["title"])
            ?? nonEmptyString((dict["rich_metadata"] as? [String: Any])?["title"])
            ?? ""
        let description = nonEmptyString(dict["closeup_unified_description"])
            ?? nonEmptyString(dict["description"])
            ?? nonEmptyString(dict["auto_alt_text"])
            ?? nonEmptyString((dict["rich_metadata"] as? [String: Any])?["description"])
            ?? ""

        let dominantColor = nonEmptyString(dict["dominant_color"])
        let externalLink = nonEmptyString(dict["link"]).flatMap(URL.init(string:))
        let domain = nonEmptyString(dict["domain"]) ?? externalLink?.host()

        let pinner = (dict["pinner"] as? [String: Any]) ?? (dict["native_creator"] as? [String: Any])
        let pinnerName = nonEmptyString(pinner?["full_name"]) ?? nonEmptyString(pinner?["username"])
        let pinnerUsername = nonEmptyString(pinner?["username"])
        let pinnerAvatar = (nonEmptyString(pinner?["image_medium_url"]) ?? nonEmptyString(pinner?["image_small_url"]))
            .flatMap(URL.init(string:))

        let board = dict["board"] as? [String: Any]
        let boardName = nonEmptyString(board?["name"])
        let boardID = stringifyID(board?["id"])

        let videoURL = extractVideoURL(from: dict)
        let agg = dict["aggregated_pin_data"] as? [String: Any]
        let stats = agg?["aggregated_stats"] as? [String: Any]
        let saveCount = (stats?["saves"] as? Int)
            ?? (stats?["saves"] as? NSNumber)?.intValue
            ?? (dict["repin_count"] as? Int)

        let pinPageURL = URL(string: "https://www.pinterest.com/pin/\(id)/")!

        return PinterestPin(
            id: id,
            title: title,
            descriptionText: description,
            dominantColorHex: dominantColor,
            width: width,
            height: height,
            thumbnailURL: bestThumb.url,
            previewURL: bestPreview.url,
            originalURL: bestOriginal.url,
            videoURL: videoURL,
            pinPageURL: pinPageURL,
            externalLinkURL: externalLink,
            domain: domain,
            pinnerName: pinnerName,
            pinnerUsername: pinnerUsername,
            pinnerAvatarURL: pinnerAvatar,
            boardName: boardName,
            boardID: boardID,
            saveCount: saveCount
        )
    }

    private struct ImageTier {
        let url: URL
        let width: Int
        let height: Int
    }

    private static func parseImageTier(_ raw: Any?) -> ImageTier? {
        guard let dict = raw as? [String: Any],
              let urlStr = nonEmptyString(dict["url"]),
              let url = URL(string: urlStr),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }
        let w = (dict["width"] as? Int) ?? (dict["width"] as? NSNumber)?.intValue ?? 0
        let h = (dict["height"] as? Int) ?? (dict["height"] as? NSNumber)?.intValue ?? 0
        return ImageTier(url: url, width: w, height: h)
    }

    private static func extractVideoURL(from dict: [String: Any]) -> URL? {
        let videoList = ((dict["videos"] as? [String: Any])?["video_list"] as? [String: Any])
            ?? (((dict["story_pin_data"] as? [String: Any])?["pages"] as? [[String: Any]])?.first?["blocks"] as? [[String: Any]])?
                .compactMap { ($0["video"] as? [String: Any])?["video_list"] as? [String: Any] }
                .first
        guard let videoList else { return nil }
        for key in ["V_720P", "V_EXP7", "V_EXP6", "V_EXP5", "V_EXP4", "V_480P", "V_HLSV4"] {
            if let entry = videoList[key] as? [String: Any],
               let urlStr = nonEmptyString(entry["url"]),
               urlStr.lowercased().contains(".mp4"),
               let url = URL(string: urlStr) {
                return url
            }
        }
        for (_, rawEntry) in videoList {
            if let entry = rawEntry as? [String: Any],
               let urlStr = nonEmptyString(entry["url"]),
               urlStr.lowercased().contains(".mp4"),
               let url = URL(string: urlStr) {
                return url
            }
        }
        return nil
    }

    private static func extractBookmark(root: [String: Any], response: [String: Any]?) -> String? {
        if let bm = nonEmptyString(response?["bookmark"]), bm != "-end-" {
            return bm
        }
        if let dataDict = response?["data"] as? [String: Any],
           let bm = nonEmptyString(dataDict["bookmark"]), bm != "-end-" {
            return bm
        }
        if let resource = root["resource"] as? [String: Any],
           let options = resource["options"] as? [String: Any],
           let bookmarks = options["bookmarks"] as? [String],
           let first = bookmarks.first, !first.isEmpty, first != "-end-" {
            return first
        }
        return nil
    }

    private static func stringifyID(_ raw: Any?) -> String? {
        if let s = raw as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let n = raw as? NSNumber {
            return n.stringValue
        }
        return nil
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
