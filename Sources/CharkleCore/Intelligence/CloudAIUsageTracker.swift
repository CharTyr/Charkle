import Foundation

public nonisolated enum CloudAIUsageNotifications {
    public static let didUpdateUsage = Notification.Name("com.charkle.ai.didUpdateUsage")
}

/// Distinguishes ordinary Cloud AI models (Gemini / ChatGPT / OpenAI / Anthropic)
/// from the TypeSafe System One (Jev) visual judgment model.
public nonisolated enum CloudAIUsageCategory: String, Codable, Hashable, Sendable {
    case standard
    case jev
}

/// Independent per-category usage counters (today + cumulative requests & tokens).
public nonisolated struct CloudAIUsageBucket: Codable, Hashable, Sendable {
    public var dayKey: String
    public var todayRequests: Int
    public var todayInputTokens: Int
    public var todayOutputTokens: Int
    public var todayTotalTokens: Int
    public var totalRequests: Int
    public var totalInputTokens: Int
    public var totalOutputTokens: Int
    public var totalTokens: Int
    public var lastProviderLabel: String?
    public var lastModel: String?
    public var lastUsedAt: Date?
    public var lastCallTokens: Int

    public init(
        dayKey: String = CloudAIUsageSummary.localDayKey(for: Date()),
        todayRequests: Int = 0,
        todayInputTokens: Int = 0,
        todayOutputTokens: Int = 0,
        todayTotalTokens: Int = 0,
        totalRequests: Int = 0,
        totalInputTokens: Int = 0,
        totalOutputTokens: Int = 0,
        totalTokens: Int = 0,
        lastProviderLabel: String? = nil,
        lastModel: String? = nil,
        lastUsedAt: Date? = nil,
        lastCallTokens: Int = 0
    ) {
        self.dayKey = dayKey
        self.todayRequests = todayRequests
        self.todayInputTokens = todayInputTokens
        self.todayOutputTokens = todayOutputTokens
        self.todayTotalTokens = todayTotalTokens
        self.totalRequests = totalRequests
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalTokens = totalTokens
        self.lastProviderLabel = lastProviderLabel
        self.lastModel = lastModel
        self.lastUsedAt = lastUsedAt
        self.lastCallTokens = lastCallTokens
    }

    public mutating func rolloverIfNeeded(now: Date = Date(), calendar: Calendar = .current) {
        let currentKey = CloudAIUsageSummary.localDayKey(for: now, calendar: calendar)
        if dayKey != currentKey {
            dayKey = currentKey
            todayRequests = 0
            todayInputTokens = 0
            todayOutputTokens = 0
            todayTotalTokens = 0
        }
    }

    public mutating func record(
        providerLabel: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        totalTokens: Int,
        now: Date
    ) {
        rolloverIfNeeded(now: now)
        todayRequests += 1
        todayInputTokens += inputTokens
        todayOutputTokens += outputTokens
        todayTotalTokens += totalTokens
        totalRequests += 1
        totalInputTokens += inputTokens
        totalOutputTokens += outputTokens
        self.totalTokens += totalTokens
        lastProviderLabel = providerLabel
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            lastModel = trimmedModel
        }
        lastUsedAt = now
        lastCallTokens = totalTokens
    }
}

/// Lightweight local usage telemetry for Cloud AI Enhancement, with separate tracking
/// for ordinary Cloud AI models (`standard`) and TypeSafe System One (`jev`) visual judgment calls.
public nonisolated struct CloudAIUsageSummary: Codable, Hashable, Sendable {
    public var dayKey: String
    public var todayRequests: Int
    public var todayInputTokens: Int
    public var todayOutputTokens: Int
    public var todayTotalTokens: Int
    public var totalRequests: Int
    public var totalInputTokens: Int
    public var totalOutputTokens: Int
    public var totalTokens: Int
    public var lastProviderLabel: String?
    public var lastModel: String?
    public var lastUsedAt: Date?
    public var lastCallTokens: Int
    public var standard: CloudAIUsageBucket
    public var jev: CloudAIUsageBucket

    public init(
        dayKey: String = CloudAIUsageSummary.localDayKey(for: Date()),
        todayRequests: Int = 0,
        todayInputTokens: Int = 0,
        todayOutputTokens: Int = 0,
        todayTotalTokens: Int = 0,
        totalRequests: Int = 0,
        totalInputTokens: Int = 0,
        totalOutputTokens: Int = 0,
        totalTokens: Int = 0,
        lastProviderLabel: String? = nil,
        lastModel: String? = nil,
        lastUsedAt: Date? = nil,
        lastCallTokens: Int = 0,
        standard: CloudAIUsageBucket? = nil,
        jev: CloudAIUsageBucket? = nil
    ) {
        self.dayKey = dayKey
        if standard != nil || jev != nil {
            self.standard = standard ?? CloudAIUsageBucket(dayKey: dayKey)
            self.jev = jev ?? CloudAIUsageBucket(dayKey: dayKey)
            self.todayRequests = todayRequests
            self.todayInputTokens = todayInputTokens
            self.todayOutputTokens = todayOutputTokens
            self.todayTotalTokens = todayTotalTokens
            self.totalRequests = totalRequests
            self.totalInputTokens = totalInputTokens
            self.totalOutputTokens = totalOutputTokens
            self.totalTokens = totalTokens
            self.lastProviderLabel = lastProviderLabel
            self.lastModel = lastModel
            self.lastUsedAt = lastUsedAt
            self.lastCallTokens = lastCallTokens
            synchronizeAggregates()
        } else {
            let legacyBucket = CloudAIUsageBucket(
                dayKey: dayKey,
                todayRequests: todayRequests,
                todayInputTokens: todayInputTokens,
                todayOutputTokens: todayOutputTokens,
                todayTotalTokens: todayTotalTokens,
                totalRequests: totalRequests,
                totalInputTokens: totalInputTokens,
                totalOutputTokens: totalOutputTokens,
                totalTokens: totalTokens,
                lastProviderLabel: lastProviderLabel,
                lastModel: lastModel,
                lastUsedAt: lastUsedAt,
                lastCallTokens: lastCallTokens
            )
            if Self.looksLikeJev(providerLabel: lastProviderLabel, model: lastModel) {
                self.standard = CloudAIUsageBucket(dayKey: dayKey)
                self.jev = legacyBucket
            } else {
                self.standard = legacyBucket
                self.jev = CloudAIUsageBucket(dayKey: dayKey)
            }
            self.todayRequests = todayRequests
            self.todayInputTokens = todayInputTokens
            self.todayOutputTokens = todayOutputTokens
            self.todayTotalTokens = todayTotalTokens
            self.totalRequests = totalRequests
            self.totalInputTokens = totalInputTokens
            self.totalOutputTokens = totalOutputTokens
            self.totalTokens = totalTokens
            self.lastProviderLabel = lastProviderLabel
            self.lastModel = lastModel
            self.lastUsedAt = lastUsedAt
            self.lastCallTokens = lastCallTokens
        }
    }

    private enum CodingKeys: String, CodingKey {
        case dayKey, todayRequests, todayInputTokens, todayOutputTokens, todayTotalTokens
        case totalRequests, totalInputTokens, totalOutputTokens, totalTokens
        case lastProviderLabel, lastModel, lastUsedAt, lastCallTokens
        case standard, jev
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedDayKey = try c.decodeIfPresent(String.self, forKey: .dayKey) ?? Self.localDayKey(for: Date())
        let decodedStandard = try c.decodeIfPresent(CloudAIUsageBucket.self, forKey: .standard)
        let decodedJev = try c.decodeIfPresent(CloudAIUsageBucket.self, forKey: .jev)

        if decodedStandard != nil || decodedJev != nil {
            self.init(
                dayKey: decodedDayKey,
                standard: decodedStandard ?? CloudAIUsageBucket(dayKey: decodedDayKey),
                jev: decodedJev ?? CloudAIUsageBucket(dayKey: decodedDayKey)
            )
        } else {
            let tReq = try c.decodeIfPresent(Int.self, forKey: .todayRequests) ?? 0
            let tIn = try c.decodeIfPresent(Int.self, forKey: .todayInputTokens) ?? 0
            let tOut = try c.decodeIfPresent(Int.self, forKey: .todayOutputTokens) ?? 0
            let tTot = try c.decodeIfPresent(Int.self, forKey: .todayTotalTokens) ?? 0
            let allReq = try c.decodeIfPresent(Int.self, forKey: .totalRequests) ?? 0
            let allIn = try c.decodeIfPresent(Int.self, forKey: .totalInputTokens) ?? 0
            let allOut = try c.decodeIfPresent(Int.self, forKey: .totalOutputTokens) ?? 0
            let allTot = try c.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
            let provider = try c.decodeIfPresent(String.self, forKey: .lastProviderLabel)
            let model = try c.decodeIfPresent(String.self, forKey: .lastModel)
            let usedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
            let lastTokens = try c.decodeIfPresent(Int.self, forKey: .lastCallTokens) ?? 0
            self.init(
                dayKey: decodedDayKey,
                todayRequests: tReq,
                todayInputTokens: tIn,
                todayOutputTokens: tOut,
                todayTotalTokens: tTot,
                totalRequests: allReq,
                totalInputTokens: allIn,
                totalOutputTokens: allOut,
                totalTokens: allTot,
                lastProviderLabel: provider,
                lastModel: model,
                lastUsedAt: usedAt,
                lastCallTokens: lastTokens
            )
        }
    }

    private static func looksLikeJev(providerLabel: String?, model: String?) -> Bool {
        let p = (providerLabel ?? "").lowercased()
        let m = (model ?? "").lowercased()
        return p.contains("typesafe") || p.contains("jev") || m.hasPrefix("jev")
    }

    public mutating func synchronizeAggregates() {
        todayRequests = standard.todayRequests + jev.todayRequests
        todayInputTokens = standard.todayInputTokens + jev.todayInputTokens
        todayOutputTokens = standard.todayOutputTokens + jev.todayOutputTokens
        todayTotalTokens = standard.todayTotalTokens + jev.todayTotalTokens
        totalRequests = standard.totalRequests + jev.totalRequests
        totalInputTokens = standard.totalInputTokens + jev.totalInputTokens
        totalOutputTokens = standard.totalOutputTokens + jev.totalOutputTokens
        totalTokens = standard.totalTokens + jev.totalTokens

        switch (standard.lastUsedAt, jev.lastUsedAt) {
        case (let sDate?, let jDate?):
            let latest = jDate >= sDate ? jev : standard
            lastProviderLabel = latest.lastProviderLabel
            lastModel = latest.lastModel
            lastUsedAt = latest.lastUsedAt
            lastCallTokens = latest.lastCallTokens
        case (.some, .none):
            lastProviderLabel = standard.lastProviderLabel
            lastModel = standard.lastModel
            lastUsedAt = standard.lastUsedAt
            lastCallTokens = standard.lastCallTokens
        case (.none, .some):
            lastProviderLabel = jev.lastProviderLabel
            lastModel = jev.lastModel
            lastUsedAt = jev.lastUsedAt
            lastCallTokens = jev.lastCallTokens
        case (.none, .none):
            lastProviderLabel = nil
            lastModel = nil
            lastUsedAt = nil
            lastCallTokens = 0
        }
    }

    public static func localDayKey(for date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let y = comps.year ?? 2026
        let m = comps.month ?? 1
        let d = comps.day ?? 1
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    public mutating func rolloverIfNeeded(now: Date = Date(), calendar: Calendar = .current) {
        let currentKey = Self.localDayKey(for: now, calendar: calendar)
        dayKey = currentKey
        standard.rolloverIfNeeded(now: now, calendar: calendar)
        jev.rolloverIfNeeded(now: now, calendar: calendar)
        synchronizeAggregates()
    }

    public static func formatTokenCount(_ count: Int) -> String {
        let clamped = max(0, count)
        if clamped >= 1_000_000 {
            return String(format: "%.2fM", Double(clamped) / 1_000_000.0)
        }
        if clamped >= 10_000 {
            return String(format: "%.1fK", Double(clamped) / 1_000.0)
        }
        if clamped >= 1_000 {
            return String(format: "%.2fK", Double(clamped) / 1_000.0)
        }
        return "\(clamped)"
    }
}

/// Thread-safe local persistence for Cloud AI usage counts & tokens.
public nonisolated final class CloudAIUsageStore: @unchecked Sendable {
    public static let shared = CloudAIUsageStore()
    private static let defaultStorageKey = "com.charkle.cloudAI.usageSummary.v1"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let storageKey: String
    private let postsNotifications: Bool
    private var cached: CloudAIUsageSummary

    public init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "com.charkle.cloudAI.usageSummary.v1",
        postsNotifications: Bool = true
    ) {
        self.defaults = userDefaults
        self.storageKey = storageKey
        self.postsNotifications = postsNotifications
        if let data = userDefaults.data(forKey: storageKey),
           var decoded = try? JSONDecoder().decode(CloudAIUsageSummary.self, from: data) {
            decoded.rolloverIfNeeded()
            self.cached = decoded
        } else {
            self.cached = CloudAIUsageSummary()
        }
    }

    public func snapshot(now: Date = Date()) -> CloudAIUsageSummary {
        lock.lock()
        defer { lock.unlock() }
        var copy = cached
        copy.rolloverIfNeeded(now: now)
        if copy != cached {
            cached = copy
            persistLocked(copy)
        }
        return copy
    }

    public func record(
        category: CloudAIUsageCategory = .standard,
        providerLabel: String,
        model: String,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        totalTokens: Int? = nil,
        now: Date = Date()
    ) {
        let safeIn = max(0, inputTokens)
        let safeOut = max(0, outputTokens)
        let resolvedTotal = max(safeIn + safeOut, max(0, totalTokens ?? 0))

        lock.lock()
        var next = cached
        next.rolloverIfNeeded(now: now)
        switch category {
        case .standard:
            next.standard.record(
                providerLabel: providerLabel,
                model: model,
                inputTokens: safeIn,
                outputTokens: safeOut,
                totalTokens: resolvedTotal,
                now: now
            )
        case .jev:
            next.jev.record(
                providerLabel: providerLabel,
                model: model,
                inputTokens: safeIn,
                outputTokens: safeOut,
                totalTokens: resolvedTotal,
                now: now
            )
        }
        next.synchronizeAggregates()
        cached = next
        persistLocked(next)
        let shouldNotify = postsNotifications
        lock.unlock()

        if shouldNotify {
            NotificationCenter.default.post(name: CloudAIUsageNotifications.didUpdateUsage, object: nil)
        }
    }

    public func reset(category: CloudAIUsageCategory? = nil, now: Date = Date()) {
        lock.lock()
        let key = CloudAIUsageSummary.localDayKey(for: now)
        var next: CloudAIUsageSummary
        switch category {
        case nil:
            next = CloudAIUsageSummary(dayKey: key)
        case .standard:
            next = cached
            next.rolloverIfNeeded(now: now)
            next.standard = CloudAIUsageBucket(dayKey: key)
            next.synchronizeAggregates()
        case .jev:
            next = cached
            next.rolloverIfNeeded(now: now)
            next.jev = CloudAIUsageBucket(dayKey: key)
            next.synchronizeAggregates()
        }
        cached = next
        persistLocked(next)
        let shouldNotify = postsNotifications
        lock.unlock()

        if shouldNotify {
            NotificationCenter.default.post(name: CloudAIUsageNotifications.didUpdateUsage, object: nil)
        }
    }

    private func persistLocked(_ summary: CloudAIUsageSummary) {
        if let data = try? JSONEncoder().encode(summary) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
