import CoreGraphics
import Foundation

/// Authenticated Pinterest web account metadata discovered from the persistent WebKit session.
public nonisolated struct PinterestAccount: Codable, Hashable, Sendable {
    public let username: String
    public let fullName: String
    public let avatarURL: URL?
    public let profileURL: URL?

    public init(
        username: String,
        fullName: String,
        avatarURL: URL? = nil,
        profileURL: URL? = nil
    ) {
        self.username = username
        self.fullName = fullName
        self.avatarURL = avatarURL
        self.profileURL = profileURL
    }

    public var displayName: String {
        let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "@\(username)" : trimmed
    }
}

/// A Pinterest Board owned or followed by the signed-in user.
public nonisolated struct PinterestBoard: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let urlPath: String
    public let pinCount: Int
    public let coverURL: URL?

    public init(
        id: String,
        name: String,
        urlPath: String,
        pinCount: Int = 0,
        coverURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.urlPath = urlPath
        self.pinCount = pinCount
        self.coverURL = coverURL
    }
}

/// Canonical model for a Pinterest Pin displayed in the infinite space, floating detail, and collection tray.
public nonisolated struct PinterestPin: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let descriptionText: String
    public let dominantColorHex: String?
    public let width: Int
    public let height: Int
    public let thumbnailURL: URL
    public let previewURL: URL
    public let originalURL: URL
    public let videoURL: URL?
    public let pinPageURL: URL
    public let externalLinkURL: URL?
    public let domain: String?
    public let pinnerName: String?
    public let pinnerUsername: String?
    public let pinnerAvatarURL: URL?
    public let boardName: String?
    public let boardID: String?
    public let saveCount: Int?

    public init(
        id: String,
        title: String,
        descriptionText: String = "",
        dominantColorHex: String? = nil,
        width: Int,
        height: Int,
        thumbnailURL: URL,
        previewURL: URL,
        originalURL: URL,
        videoURL: URL? = nil,
        pinPageURL: URL,
        externalLinkURL: URL? = nil,
        domain: String? = nil,
        pinnerName: String? = nil,
        pinnerUsername: String? = nil,
        pinnerAvatarURL: URL? = nil,
        boardName: String? = nil,
        boardID: String? = nil,
        saveCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.descriptionText = descriptionText
        self.dominantColorHex = dominantColorHex
        self.width = max(1, width)
        self.height = max(1, height)
        self.thumbnailURL = thumbnailURL
        self.previewURL = previewURL
        self.originalURL = originalURL
        self.videoURL = videoURL
        self.pinPageURL = pinPageURL
        self.externalLinkURL = externalLinkURL
        self.domain = domain
        self.pinnerName = pinnerName
        self.pinnerUsername = pinnerUsername
        self.pinnerAvatarURL = pinnerAvatarURL
        self.boardName = boardName
        self.boardID = boardID
        self.saveCount = saveCount
    }

    /// Clamped visual aspect ratio (width / height) matching editorial masonry card rhythm.
    public var aspectRatio: Double {
        guard width > 0, height > 0 else { return 0.78 }
        return max(0.45, min(2.1, Double(width) / Double(height)))
    }

    public var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let d = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { return String(d.prefix(64)) }
        if let board = boardName?.trimmingCharacters(in: .whitespacesAndNewlines), !board.isEmpty {
            return board
        }
        return "Pinterest Pin #\(id)"
    }

    public var isVideo: Bool {
        videoURL != nil
    }

    /// Chooses the sharpest appropriate image tier for the current rendered screen width.
    public func imageURL(forRenderedWidth screenWidth: CGFloat) -> URL {
        if screenWidth <= 150 {
            return thumbnailURL
        }
        if screenWidth <= 420 {
            return previewURL
        }
        return originalURL
    }

    /// Merges richer metadata from a detail fetch while preserving valid fallback URLs.
    public func merged(with detailed: PinterestPin) -> PinterestPin {
        guard detailed.id == id else { return detailed }
        return PinterestPin(
            id: id,
            title: detailed.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? title : detailed.title,
            descriptionText: detailed.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? descriptionText : detailed.descriptionText,
            dominantColorHex: detailed.dominantColorHex ?? dominantColorHex,
            width: detailed.width > 1 ? detailed.width : width,
            height: detailed.height > 1 ? detailed.height : height,
            thumbnailURL: detailed.thumbnailURL,
            previewURL: detailed.previewURL,
            originalURL: detailed.originalURL,
            videoURL: detailed.videoURL ?? videoURL,
            pinPageURL: detailed.pinPageURL,
            externalLinkURL: detailed.externalLinkURL ?? externalLinkURL,
            domain: detailed.domain ?? domain,
            pinnerName: detailed.pinnerName ?? pinnerName,
            pinnerUsername: detailed.pinnerUsername ?? pinnerUsername,
            pinnerAvatarURL: detailed.pinnerAvatarURL ?? pinnerAvatarURL,
            boardName: detailed.boardName ?? boardName,
            boardID: detailed.boardID ?? boardID,
            saveCount: detailed.saveCount ?? saveCount
        )
    }
}

/// Active content feed driving the infinite 2D Pinterest space.
public nonisolated enum PinterestFeedSource: Hashable, Sendable {
    case homeFeed
    case search(String)
    case board(PinterestBoard)
    case similar(anchorPin: PinterestPin)

    public var displayTitle: String {
        switch self {
        case .homeFeed:
            return "推荐灵感"
        case .search(let query):
            return "搜索 · \(query)"
        case .board(let board):
            return board.name
        case .similar(let pin):
            return "相似 · \(pin.displayTitle)"
        }
    }
}

public nonisolated struct PinterestFeedPage: Sendable {
    public let pins: [PinterestPin]
    public let bookmark: String?
    public let hasMore: Bool

    public init(pins: [PinterestPin], bookmark: String? = nil, hasMore: Bool = false) {
        self.pins = pins
        self.bookmark = bookmark
        self.hasMore = hasMore
    }
}

public nonisolated struct PinterestPinDetailResult: Sendable {
    public let pin: PinterestPin
    public let similarPins: [PinterestPin]
    public let similarBookmark: String?

    public init(pin: PinterestPin, similarPins: [PinterestPin], similarBookmark: String? = nil) {
        self.pin = pin
        self.similarPins = similarPins
        self.similarBookmark = similarBookmark
    }
}

/// A placed card in infinite 2D world space with an immutable frame once positioned.
public nonisolated struct PinterestSpatialCard: Identifiable, Hashable, Sendable {
    public let pin: PinterestPin
    public let frame: CGRect
    public let ringIndex: Int

    public var id: String { pin.id }

    public init(pin: PinterestPin, frame: CGRect, ringIndex: Int) {
        self.pin = pin
        self.frame = frame
        self.ringIndex = ringIndex
    }
}

/// Deterministic, non-overlapping 2D infinite omnidirectional spatial layout engine.
///
/// Arranges pins organically outward in concentric rings around `(0, 0)` across bidirectional
/// columns (growing both north into negative Y and south into positive Y, and east/west into
/// negative/positive columns). Appending new pages ONLY adds cards outside already-placed cards,
/// guaranteeing 0pt layout shift during infinite panning and continuous anchor-locked zooming.
public nonisolated struct PinterestSpatialLayout: Sendable {
    public let cardWidth: CGFloat
    public let gap: CGFloat
    public private(set) var cards: [PinterestSpatialCard] = []
    public private(set) var worldBounds: CGRect = .zero

    private var seenIDs: Set<String> = []
    private var colTopY: [Int: CGFloat] = [:]
    private var colBottomY: [Int: CGFloat] = [:]
    private var activeRadius: Int = 2

    public init(cardWidth: CGFloat = 224, gap: CGFloat = 16) {
        self.cardWidth = max(120, cardWidth)
        self.gap = max(6, gap)
    }

    public mutating func reset() {
        cards.removeAll(keepingCapacity: true)
        seenIDs.removeAll(keepingCapacity: true)
        colTopY.removeAll(keepingCapacity: true)
        colBottomY.removeAll(keepingCapacity: true)
        worldBounds = .zero
        activeRadius = 2
    }

    /// Appends pins into the lowest-distance open slot around the current rings without ever
    /// moving previously placed cards.
    @discardableResult
    public mutating func append(_ newPins: [PinterestPin]) -> [PinterestSpatialCard] {
        var added: [PinterestSpatialCard] = []
        added.reserveCapacity(newPins.count)

        let strideX = cardWidth + gap

        for pin in newPins {
            guard seenIDs.insert(pin.id).inserted else { continue }
            let cardHeight = max(110, min(460, (cardWidth / CGFloat(pin.aspectRatio)).rounded()))

            // Dynamically expand column radius as total card count grows so the layout stays
            // roughly square/circular in 2D space (enabling smooth omnidirectional panning).
            let desiredRadius = max(2, Int(sqrt(Double(cards.count + 1)) * 0.62) + 1)
            if desiredRadius > activeRadius {
                activeRadius = desiredRadius
            }

            var bestCol = 0
            var bestPlaceNorth = false
            var bestScore = CGFloat.greatestFiniteMagnitude
            var bestY: CGFloat = 0

            for col in (-activeRadius)...activeRadius {
                let colCenterX = CGFloat(col) * strideX
                let stagger = Self.columnStagger(col: col, gap: gap)

                if colBottomY[col] == nil {
                    // First card in this column centers cleanly on the staggered origin band.
                    let y = -cardHeight * 0.5 + stagger
                    let centerY = y + cardHeight * 0.5
                    let score = hypot(colCenterX, centerY)
                    if score < bestScore {
                        bestScore = score
                        bestCol = col
                        bestPlaceNorth = false
                        bestY = y
                    }
                } else {
                    let topEdge = colTopY[col] ?? stagger
                    let bottomEdge = colBottomY[col] ?? stagger

                    // Candidate 1: Grow South (+Y)
                    let southY = bottomEdge + gap
                    let southCenterY = southY + cardHeight * 0.5
                    let southScore = hypot(colCenterX, southCenterY)
                    if southScore < bestScore {
                        bestScore = southScore
                        bestCol = col
                        bestPlaceNorth = false
                        bestY = southY
                    }

                    // Candidate 2: Grow North (-Y)
                    let northY = topEdge - gap - cardHeight
                    let northCenterY = northY + cardHeight * 0.5
                    let northScore = hypot(colCenterX, northCenterY)
                    if northScore < bestScore {
                        bestScore = northScore
                        bestCol = col
                        bestPlaceNorth = true
                        bestY = northY
                    }
                }
            }

            let x = CGFloat(bestCol) * strideX - cardWidth * 0.5
            let frame = CGRect(x: x, y: bestY, width: cardWidth, height: cardHeight)

            if colBottomY[bestCol] == nil {
                colTopY[bestCol] = frame.minY
                colBottomY[bestCol] = frame.maxY
            } else if bestPlaceNorth {
                colTopY[bestCol] = frame.minY
            } else {
                colBottomY[bestCol] = frame.maxY
            }

            let ring = max(abs(bestCol), Int(abs(frame.midY) / max(1, cardWidth)))
            let placed = PinterestSpatialCard(pin: pin, frame: frame, ringIndex: ring)
            cards.append(placed)
            added.append(placed)

            if worldBounds == .zero {
                worldBounds = frame
            } else {
                worldBounds = worldBounds.union(frame)
            }
        }
        return added
    }

    /// Returns only cards intersecting the visible world rectangle (plus overscan margin) for 120Hz culling.
    public func visibleCards(in visibleWorldRect: CGRect, overscan: CGFloat = 320) -> [PinterestSpatialCard] {
        guard !cards.isEmpty else { return [] }
        let expanded = visibleWorldRect.insetBy(dx: -overscan, dy: -overscan)
        return cards.filter { $0.frame.intersects(expanded) }
    }

    /// Returns `true` when the camera's visible viewport approaches any outer edge of placed cards.
    public func isApproachingEdge(visibleWorldRect: CGRect, threshold: CGFloat = 460) -> Bool {
        guard !cards.isEmpty, worldBounds != .zero else { return true }
        return visibleWorldRect.minX <= worldBounds.minX + threshold
            || visibleWorldRect.maxX >= worldBounds.maxX - threshold
            || visibleWorldRect.minY <= worldBounds.minY + threshold
            || visibleWorldRect.maxY >= worldBounds.maxY - threshold
    }

    /// Returns cards inside a predictive lookahead region around `visibleWorldRect` shifted along
    /// `lookaheadOffset` (the user's current pan trajectory), ordered closest-first to the predicted
    /// future viewport center so thumbnails along the swipe path decode before entering the screen.
    public func predictivePrefetchCards(
        visibleWorldRect: CGRect,
        lookaheadOffset: CGVector = .zero,
        halo: CGFloat = 720,
        limit: Int = 36
    ) -> [PinterestSpatialCard] {
        guard !cards.isEmpty, limit > 0 else { return [] }
        let projectedRect = visibleWorldRect.offsetBy(dx: lookaheadOffset.dx, dy: lookaheadOffset.dy)
        let searchZone = visibleWorldRect
            .insetBy(dx: -halo, dy: -halo)
            .union(projectedRect.insetBy(dx: -halo * 0.85, dy: -halo * 0.85))

        // Target focus point biases heavily toward where the user is gliding to next.
        let focusCenter = CGPoint(
            x: visibleWorldRect.midX + lookaheadOffset.dx * 0.72,
            y: visibleWorldRect.midY + lookaheadOffset.dy * 0.72
        )

        var candidates: [(card: PinterestSpatialCard, distSq: CGFloat)] = []
        candidates.reserveCapacity(min(cards.count, limit * 2))

        for card in cards where card.frame.intersects(searchZone) {
            let dx = card.frame.midX - focusCenter.x
            let dy = card.frame.midY - focusCenter.y
            candidates.append((card, dx * dx + dy * dy))
        }
        candidates.sort { $0.distSq < $1.distSq }
        return candidates.prefix(limit).map(\.card)
    }

    private static func columnStagger(col: Int, gap: CGFloat) -> CGFloat {
        let pattern: [CGFloat] = [0, 38, -28, 52, -18, 26, -44]
        let idx = ((col % pattern.count) + pattern.count) % pattern.count
        return pattern[idx] + (col == 0 ? 0 : gap * 0.25)
    }
}

/// Pure anchor-locked 2D camera math shared between macOS and iOS infinite canvas controllers.
public nonisolated struct InfiniteSpatialCamera: Equatable, Sendable {
    public var translation: CGPoint
    public var scale: CGFloat

    public static let minScale: CGFloat = 0.24
    public static let maxScale: CGFloat = 3.20

    public init(translation: CGPoint = .zero, scale: CGFloat = 1.0) {
        self.translation = translation
        self.scale = max(Self.minScale, min(Self.maxScale, scale))
    }

    /// Centers world `(0, 0)` at the middle of `viewportSize`.
    public static func centered(in viewportSize: CGSize, scale: CGFloat = 0.92) -> InfiniteSpatialCamera {
        InfiniteSpatialCamera(
            translation: CGPoint(x: viewportSize.width * 0.5, y: viewportSize.height * 0.5),
            scale: scale
        )
    }

    /// Computes the world-space rectangle currently visible inside `viewportSize`.
    public func visibleWorldRect(viewportSize: CGSize) -> CGRect {
        let inv = 1.0 / max(0.01, scale)
        return CGRect(
            x: -translation.x * inv,
            y: -translation.y * inv,
            width: viewportSize.width * inv,
            height: viewportSize.height * inv
        )
    }

    /// Converts a world-space point into viewport screen coordinates.
    public func screenPoint(from worldPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: worldPoint.x * scale + translation.x,
            y: worldPoint.y * scale + translation.y
        )
    }

    /// Converts a viewport screen point into world-space coordinates.
    public func worldPoint(from screenPoint: CGPoint) -> CGPoint {
        let inv = 1.0 / max(0.01, scale)
        return CGPoint(
            x: (screenPoint.x - translation.x) * inv,
            y: (screenPoint.y - translation.y) * inv
        )
    }

    /// Applies continuous zoom anchored strictly at `screenAnchor` so the world point beneath
    /// the cursor or pinch centroid remains stationary to 0.0pt.
    public mutating func zoom(to targetScale: CGFloat, anchoredAt screenAnchor: CGPoint) {
        let clamped = max(Self.minScale, min(Self.maxScale, targetScale))
        guard abs(clamped - scale) > 0.0001 else { return }
        let anchorWorld = worldPoint(from: screenAnchor)
        scale = clamped
        translation = CGPoint(
            x: screenAnchor.x - anchorWorld.x * clamped,
            y: screenAnchor.y - anchorWorld.y * clamped
        )
    }

    public mutating func pan(by screenDelta: CGSize) {
        translation.x += screenDelta.width
        translation.y += screenDelta.height
    }
}

/// Persistent storage for the user's Pinterest shopping-cart collection tray across sessions.
public nonisolated enum PinterestTrayStorage {
    private static let storageKey = "charkle.pinterest.collectionTray.v1"

    public static func load() -> [PinterestPin] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let pins = try? JSONDecoder().decode([PinterestPin].self, from: data) else {
            return []
        }
        return pins
    }

    public static func save(_ pins: [PinterestPin]) {
        guard let data = try? JSONEncoder().encode(pins) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
