import Foundation
import ImageIO

/// Parsed identity of a GitHub repository URL (`https://github.com/<owner>/<repo>`).
public nonisolated struct GitHubRepoReference: Equatable, Hashable, Sendable {
    public let owner: String
    public let repo: String
    public let branch: String?

    public var fullName: String { "\(owner)/\(repo)" }

    public var canonicalURL: URL {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "github.com"
        comps.path = "/\(owner)/\(repo)"
        if let url = comps.url {
            return url
        }
        return URL(fileURLWithPath: "/").standardizedFileURL // unreachable for valid ASCII host
    }

    public init(owner: String, repo: String, branch: String? = nil) {
        self.owner = owner
        self.repo = repo
        self.branch = branch
    }
}

/// Detects GitHub repository root / branch URLs (skipping non-repo GitHub sections and deep issue/blob links).
public nonisolated enum GitHubRepoURLParser {
    private static let supportedHosts: Set<String> = [
        "github.com", "www.github.com"
    ]

    private static let reservedOwners: Set<String> = [
        "settings", "notifications", "explore", "marketplace", "topics",
        "trending", "collections", "events", "sponsors", "orgs", "organizations",
        "search", "login", "signup", "join", "features", "pricing", "enterprise",
        "team", "security", "about", "contact", "issues", "pulls", "codespaces",
        "copilot", "new", "stars", "gist", "apps", "site", "customer-stories"
    ]

    public static func parse(_ url: URL) -> GitHubRepoReference? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased(), supportedHosts.contains(host) else {
            return nil
        }

        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard segments.count >= 2 else { return nil }

        let owner = segments[0]
        var repo = segments[1]
        if repo.lowercased().hasSuffix(".git") {
            repo = String(repo.dropLast(4))
        }

        guard !owner.isEmpty, !repo.isEmpty,
              !reservedOwners.contains(owner.lowercased()),
              isValidSlug(owner), isValidSlug(repo) else {
            return nil
        }

        if segments.count == 2 {
            return GitHubRepoReference(owner: owner, repo: repo)
        }
        // Also accept `github.com/<owner>/<repo>/tree/<branch>` as a repository bookmark.
        if segments.count == 4 && segments[2].lowercased() == "tree" {
            return GitHubRepoReference(owner: owner, repo: repo, branch: segments[3])
        }
        return nil
    }

    public static func extractRepoURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = URL(string: trimmed), parse(direct) != nil {
            return direct
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        for match in detector.matches(in: trimmed, options: [], range: range) {
            if let url = match.url, parse(url) != nil {
                return url
            }
        }
        return nil
    }

    private static func isValidSlug(_ raw: String) -> Bool {
        raw.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == ".")
        }
    }
}

/// Fetches GitHub repository metadata (stars, forks, language, license, topics) and README.md.
public nonisolated enum GitHubRepoResolver {
    public static func resolve(_ ref: GitHubRepoReference) async -> GitHubRepoMetadata {
        async let repoInfoTask = fetchRepoInfo(ref)
        async let readmeTask = fetchReadmeViaAPI(ref)

        let info = await repoInfoTask
        let defaultBranch = ref.branch ?? info?.default_branch ?? "main"
        var readme = await readmeTask
        if readme == nil || readme?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            readme = await fetchRawReadme(ref, branch: defaultBranch)
        }

        let resolvedOwner = info?.owner?.login ?? ref.owner
        let resolvedRepo = info?.name ?? ref.repo
        return GitHubRepoMetadata(
            owner: resolvedOwner,
            repo: resolvedRepo,
            fullName: info?.full_name ?? ref.fullName,
            ownerAvatarURL: info?.owner?.avatar_url,
            description: info?.description?.trimmingCharacters(in: .whitespacesAndNewlines),
            stars: info?.stargazers_count ?? 0,
            forks: info?.forks_count ?? 0,
            watchers: info?.subscribers_count ?? info?.watchers_count,
            language: info?.language,
            licenseName: info?.license?.spdx_id ?? info?.license?.name,
            topics: Array((info?.topics ?? []).prefix(16)),
            defaultBranch: defaultBranch,
            homepageURL: info?.homepage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            openGraphImageURL: "https://opengraph.githubassets.com/1/\(resolvedOwner)/\(resolvedRepo)",
            readmeMarkdown: readme,
            fetchedAt: Date()
        )
    }

    public static func decodeBase64Markdown(_ encoded: String) -> String? {
        let compact = encoded.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: compact),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    /// Downloads the official GitHub OpenGraph preview card (`opengraph.githubassets.com/1/<owner>/<repo>`)
    /// so GitHub repository bookmarks display GitHub's native visual preview card directly in the gallery.
    public static func fetchOpenGraphCardImage(for repo: GitHubRepoMetadata) async -> CGImage? {
        var candidates: [String] = []
        if let custom = repo.openGraphImageURL?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            candidates.append(custom)
        }
        let standard = "https://opengraph.githubassets.com/1/\(repo.owner)/\(repo.repo)"
        if !candidates.contains(standard) {
            candidates.append(standard)
        }

        for rawURL in candidates {
            guard let url = URL(string: rawURL),
                  WebBookmark.isSafeRemoteFetchURL(url),
                  let data = await fetchData(url: url, accept: "image/png,image/webp,image/jpeg,image/*", maxBytes: 8 * 1024 * 1024),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = MediaPipeline.raster(source)?.poster,
                  image.width >= 200, image.height >= 100 else {
                continue
            }
            return image
        }
        return nil
    }

    private struct RepoAPIResponse: Decodable {
        struct Owner: Decodable { let login: String?; let avatar_url: String? }
        struct License: Decodable { let spdx_id: String?; let name: String? }
        let name: String?
        let full_name: String?
        let description: String?
        let stargazers_count: Int?
        let forks_count: Int?
        let watchers_count: Int?
        let subscribers_count: Int?
        let language: String?
        let license: License?
        let topics: [String]?
        let default_branch: String?
        let homepage: String?
        let owner: Owner?
    }

    private struct ReadmeAPIResponse: Decodable {
        let content: String?
        let encoding: String?
    }

    private static func fetchRepoInfo(_ ref: GitHubRepoReference) async -> RepoAPIResponse? {
        guard let url = URL(string: "https://api.github.com/repos/\(ref.owner)/\(ref.repo)"),
              let data = await fetchData(url: url, accept: "application/vnd.github+json") else {
            return nil
        }
        return try? JSONDecoder().decode(RepoAPIResponse.self, from: data)
    }

    private static func fetchReadmeViaAPI(_ ref: GitHubRepoReference) async -> String? {
        var components = URLComponents(string: "https://api.github.com/repos/\(ref.owner)/\(ref.repo)/readme")
        if let branch = ref.branch {
            components?.queryItems = [URLQueryItem(name: "ref", value: branch)]
        }
        guard let url = components?.url,
              let data = await fetchData(url: url, accept: "application/vnd.github+json"),
              let payload = try? JSONDecoder().decode(ReadmeAPIResponse.self, from: data),
              let content = payload.content else {
            return nil
        }
        if payload.encoding?.lowercased() == "base64" {
            return decodeBase64Markdown(content).map { String($0.prefix(120_000)) }
        }
        return String(content.prefix(120_000))
    }

    private static func fetchRawReadme(_ ref: GitHubRepoReference, branch: String) async -> String? {
        let candidates = [
            "https://raw.githubusercontent.com/\(ref.owner)/\(ref.repo)/\(branch)/README.md",
            "https://raw.githubusercontent.com/\(ref.owner)/\(ref.repo)/\(branch)/readme.md",
            "https://raw.githubusercontent.com/\(ref.owner)/\(ref.repo)/master/README.md"
        ]
        for raw in candidates {
            guard let url = URL(string: raw),
                  let data = await fetchData(url: url, accept: "text/plain", maxBytes: 2 * 1024 * 1024),
                  let text = String(data: data, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            return String(text.prefix(120_000))
        }
        return nil
    }

    private static func fetchData(url: URL, accept: String, maxBytes: Int = 4 * 1024 * 1024) async -> Data? {
        guard WebBookmark.isSafeRemoteFetchURL(url) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Charkle/1.0 (+https://charkle.app)", forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count <= maxBytes else {
            return nil
        }
        return data
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
