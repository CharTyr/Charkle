import Foundation

// MARK: - TypeSafe System One Wire Models

public nonisolated struct TypeSafeBoxCoordinates: Codable, Hashable, Sendable {
    public let top: Double
    public let bottom: Double
    public let left: Double
    public let right: Double

    public init(top: Double, bottom: Double, left: Double, right: Double) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }

    public var normalizedCropRect: NormalizedCropRect {
        NormalizedCropRect(boxTop: top, bottom: bottom, left: left, right: right)
    }
}

public nonisolated struct TypeSafeImageAttachment: Sendable, Hashable {
    public let referenceKey: String
    public let partName: String
    public let format: String
    public let data: Data

    public init(
        referenceKey: String = "img-\(UUID().uuidString.lowercased())",
        partName: String = "image-\(UUID().uuidString.prefix(8).lowercased())",
        format: String = "jpg",
        data: Data
    ) {
        self.referenceKey = referenceKey
        self.partName = partName
        self.format = format.lowercased() == "png" ? "png" : "jpg"
        self.data = data
    }

    public var mimeType: String {
        format == "png" ? "image/png" : "image/jpeg"
    }
}

public nonisolated enum TypeSafeQuestion: Sendable, Hashable {
    case noul(instructions: String, trueCriteria: String? = nil, falseCriteria: String? = nil)
    case box(instructions: String)
    case choice(instructions: String, criteria: [String: String])
    case score(instructions: String, criteria: [String])

    var usesDangerZoneImages: Bool {
        if case .box = self { return true }
        return false
    }

    func jsonObject() -> [String: Any] {
        switch self {
        case .noul(let instructions, let trueCriteria, let falseCriteria):
            var dict: [String: Any] = [
                "type": "noul",
                "instructions": instructions
            ]
            if trueCriteria != nil || falseCriteria != nil {
                var crit: [String: String] = [:]
                if let trueCriteria { crit["true"] = trueCriteria }
                if let falseCriteria { crit["false"] = falseCriteria }
                dict["criteria"] = crit
            }
            return dict

        case .box(let instructions):
            return [
                "type": "box",
                "instructions": instructions
            ]

        case .choice(let instructions, let criteria):
            return [
                "type": "choice",
                "instructions": instructions,
                "criteria": criteria
            ]

        case .score(let instructions, let criteria):
            return [
                "type": "score",
                "instructions": instructions,
                "criteria": criteria
            ]
        }
    }
}

public nonisolated enum TypeSafeAnswer: Hashable, Sendable, Decodable {
    case noul(probability: Double)
    case box(box: TypeSafeBoxCoordinates, confidence: Double?)
    case choice(choice: String, confidence: Double?, probabilities: [String: Double])
    case score(score: Double, confidence: Double?, probabilities: [String: Double], legend: [String: String])

    private enum CodingKeys: String, CodingKey {
        case type, noul, box, choice, score, confidence, probabilities, legend
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .type)
        switch kind {
        case "noul":
            let prob = try c.decode(Double.self, forKey: .noul)
            self = .noul(probability: prob)
        case "box":
            let coords = try c.decode(TypeSafeBoxCoordinates.self, forKey: .box)
            let conf = try c.decodeIfPresent(Double.self, forKey: .confidence)
            self = .box(box: coords, confidence: conf)
        case "choice":
            let selected = try c.decode(String.self, forKey: .choice)
            let conf = try c.decodeIfPresent(Double.self, forKey: .confidence)
            let probs = try c.decodeIfPresent([String: Double].self, forKey: .probabilities) ?? [:]
            self = .choice(choice: selected, confidence: conf, probabilities: probs)
        case "score":
            let val = try c.decode(Double.self, forKey: .score)
            let conf = try c.decodeIfPresent(Double.self, forKey: .confidence)
            let probs = try c.decodeIfPresent([String: Double].self, forKey: .probabilities) ?? [:]
            let legend = try c.decodeIfPresent([String: String].self, forKey: .legend) ?? [:]
            self = .score(score: val, confidence: conf, probabilities: probs, legend: legend)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "Unsupported TypeSafe answer type: \(kind)"
            )
        }
    }

    public var noulProbability: Double? {
        if case .noul(let p) = self { return p }
        return nil
    }

    public var boxValue: (coords: TypeSafeBoxCoordinates, confidence: Double?)? {
        if case .box(let coords, let conf) = self { return (coords, conf) }
        return nil
    }

    public var choiceValue: (choice: String, confidence: Double?, probabilities: [String: Double])? {
        if case .choice(let choice, let conf, let probs) = self { return (choice, conf, probs) }
        return nil
    }

    public var scoreValue: (score: Double, confidence: Double?, probabilities: [String: Double])? {
        if case .score(let score, let conf, let probs, _) = self { return (score, conf, probs) }
        return nil
    }
}

public nonisolated struct TypeSafeUsage: Codable, Hashable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

public nonisolated struct TypeSafeSystemOneResponse: Decodable, Hashable, Sendable {
    public let model: String
    public let answers: [String: TypeSafeAnswer]
    public let usage: TypeSafeUsage?

    public init(model: String, answers: [String: TypeSafeAnswer], usage: TypeSafeUsage? = nil) {
        self.model = model
        self.answers = answers
        self.usage = usage
    }
}

// MARK: - TypeSafe System One Client

public nonisolated struct TypeSafeSystemOneClient: Sendable {
    public static let imagesDangerZoneHeader = "TypeSafe-Danger-Zone-Images"

    public let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    public init(baseURL: String = "https://api.typesafe.ai", apiKey: String, session: URLSession = .shared) throws {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedBase.isEmpty ? "https://api.typesafe.ai" : trimmedBase),
              let host = url.host()?.lowercased(), !host.isEmpty,
              url.user() == nil, url.password() == nil, url.query() == nil, url.fragment() == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw LibraryDatabaseError("无效的 TypeSafe 服务地址，远程接口请使用 HTTPS。")
        }
        let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty else {
            throw LibraryDatabaseError("请先在「设置 → 智能与搜索」中填写 TypeSafe API 密钥。")
        }
        self.baseURL = url.path.isEmpty || url.path == "/" ? url.appending(path: "v1") : url
        self.apiKey = cleanedKey
        self.session = session
    }

    public func listModels(timeout: TimeInterval = 20) async throws -> [TypeSafeModelInfo] {
        struct ModelsEnvelope: Decodable {
            let models: [TypeSafeModelInfo]
        }
        var request = URLRequest(url: baseURL.appending(path: "models"), timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        try Self.validateHTTP(response, data: data)
        return try JSONDecoder().decode(ModelsEnvelope.self, from: data).models
    }

    /// Execute a System One request with one or more typed questions (`box`, `noul`, `choice`, `score`).
    /// Automatically uses `multipart/form-data` whenever image attachments are supplied and sends
    /// the required `TypeSafe-Danger-Zone-Images: true` header.
    public func systemOne(
        model: String,
        state: [String: Any],
        questions: [String: TypeSafeQuestion],
        images: [TypeSafeImageAttachment] = [],
        timeout: TimeInterval = 45
    ) async throws -> TypeSafeSystemOneResponse {
        guard !questions.isEmpty else {
            throw LibraryDatabaseError("TypeSafe System One 请求至少需要一个问题。")
        }
        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "jev-latest"
            : model.trimmingCharacters(in: .whitespacesAndNewlines)

        var requestPayload: [String: Any] = [
            "model": resolvedModel,
            "state": state,
            "questions": questions.mapValues { $0.jsonObject() }
        ]

        let needsImagesHeader = !images.isEmpty || questions.values.contains(where: \.usesDangerZoneImages)

        var request = URLRequest(url: baseURL.appending(path: "systemone"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if needsImagesHeader {
            request.setValue("true", forHTTPHeaderField: Self.imagesDangerZoneHeader)
        }

        if images.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: requestPayload)
        } else {
            var assetsMap: [String: Any] = [:]
            for image in images {
                assetsMap[image.referenceKey] = [
                    "type": "image",
                    "part": image.partName
                ]
            }
            requestPayload["assets"] = assetsMap

            let jsonBytes = try JSONSerialization.data(withJSONObject: requestPayload)
            let boundary = "CharkleTypeSafe-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.buildMultipartBody(
                boundary: boundary,
                requestJSON: jsonBytes,
                images: images
            )
        }

        let (data, response) = try await session.data(for: request)
        try Self.validateHTTP(response, data: data)
        let decoded = try JSONDecoder().decode(TypeSafeSystemOneResponse.self, from: data)
        CloudAIUsageStore.shared.record(
            category: .jev,
            providerLabel: "TypeSafe (Jev)",
            model: decoded.model.isEmpty ? resolvedModel : decoded.model,
            inputTokens: decoded.usage?.inputTokens ?? 0,
            outputTokens: decoded.usage?.outputTokens ?? 0
        )
        return decoded
    }

    static func buildMultipartBody(
        boundary: String,
        requestJSON: Data,
        images: [TypeSafeImageAttachment]
    ) -> Data {
        var body = Data()
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        // Rule: first part MUST be named "request" with Content-Type: application/json
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"request\"\r\n")
        append("Content-Type: application/json\r\n\r\n")
        body.append(requestJSON)
        append("\r\n")

        for image in images {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(image.partName)\"; filename=\"\(image.partName).\(image.format)\"\r\n")
            append("Content-Type: \(image.mimeType)\r\n\r\n")
            body.append(image.data)
            append("\r\n")
        }

        append("--\(boundary)--\r\n")
        return body
    }

    private static func validateHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            let serverDetail = extractErrorDetail(from: data)
            switch http.statusCode {
            case 401, 403:
                throw LibraryDatabaseError("TypeSafe API 密钥无效或无权限（HTTP \(http.statusCode)）。" + (serverDetail.map { " \($0)" } ?? ""))
            case 429:
                throw LibraryDatabaseError("TypeSafe 请求频率超限（HTTP 429），请稍后重试。")
            default:
                let suffix = serverDetail.map { "：\($0)" } ?? ""
                throw LibraryDatabaseError("TypeSafe 返回错误 HTTP \(http.statusCode)\(suffix)")
            }
        }
    }

    private static func extractErrorDetail(from data: Data) -> String? {
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data.prefix(240), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw?.isEmpty == false ? raw : nil
        }
        if let detail = json["detail"] as? String, !detail.isEmpty { return detail }
        if let details = json["detail"] as? [[String: Any]], !details.isEmpty {
            let messages = details.compactMap { item -> String? in
                let msg = item["msg"] as? String
                let loc = (item["loc"] as? [Any])?.map { "\($0)" }.joined(separator: ".")
                if let loc, let msg { return "\(loc): \(msg)" }
                return msg
            }
            if !messages.isEmpty { return messages.joined(separator: "; ") }
        }
        if let message = json["message"] as? String, !message.isEmpty { return message }
        if let error = json["error"] as? [String: Any], let msg = error["message"] as? String, !msg.isEmpty { return msg }
        if let error = json["error"] as? String, !error.isEmpty { return error }
        return nil
    }
}
