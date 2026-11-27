import Foundation

public enum NotchTargetMode: String, CaseIterable, Hashable, Sendable {
    case inbox
    case folder
    case activeMoodboard

    public var localizedTitle: String {
        switch self {
        case .inbox: "收件箱"
        case .folder: "指定文件夹"
        case .activeMoodboard: "当前活跃情绪板"
        }
    }
}

/// Controls whether the Notch Shelf opens directly with Recent Assets or as a slim Collection Capsule.
public enum NotchShelfPresentationMode: String, CaseIterable, Hashable, Sendable {
    /// Always open with Quick Capture + Drop Well + Recent Assets strip.
    case alwaysShowRecent
    /// Show only the slim Collection Capsule during drag-to-notch triggers;
    /// show Recent Assets when opened without dragging (hover / hotkey / menu bar).
    case dropOnlyOnDrag
    /// Always open as a slim Collection Capsule first; reveal Recent Assets on explicit click.
    case alwaysDropOnlyUntilExpanded

    public var shortLabel: String {
        switch self {
        case .alwaysShowRecent: "始终完整"
        case .dropOnlyOnDrag: "拖放极简"
        case .alwaysDropOnlyUntilExpanded: "默认仅收集"
        }
    }

    public var settingsSubtitle: String {
        switch self {
        case .alwaysShowRecent:
            "拖放、悬停或快捷键唤出时，均直接显示收集区与最近素材横条"
        case .dropOnlyOnDrag:
            "拖入文件或链接时仅弹出轻巧收集窗；无拖放悬停或快捷键唤出时完整展示最近素材"
        case .alwaysDropOnlyUntilExpanded:
            "常规触发默认只显示简洁收集窗，点击窗内「展开最近素材」后再展开浏览"
        }
    }
}

/// How the Notch Shelf was triggered to open from its collapsed state.
public enum NotchExpandTrigger: Hashable, Sendable {
    case drag
    case hover
    case manual
    case statusBanner
}

/// Observable animation & interaction state driving the fixed transparent Notch Shelf NSPanel.
/// Supports Slim Collection Capsule (quick capture + drop well + 1-click Recent Assets expand),
/// Compact Shelf (+ Recent Assets horizontal strip), and Expanded Full-Waterfall Shelf.
@Observable
public final class NotchShelfState {
    public static let topEarRadius: CGFloat = 12
    public static let bottomCornerRadius: CGFloat = 24

    public var isExpanded: Bool = false
    public var isRecentStripExpanded: Bool = true
    public var isFullGalleryExpanded: Bool = false
    public var isMinimalCaptureOnly: Bool = false
    public var isPinnedOpen: Bool = false
    public var isDropTargeted: Bool = false
    public var dragItemCount: Int = 0

    /// Measured physical MacBook camera housing notch & active display geometry.
    public var physicalNotchWidth: CGFloat = 204
    public var physicalNotchHeight: CGFloat = 0
    public var hasPhysicalNotch: Bool = false
    public var activeScreenWidth: CGFloat = 1440
    public var activeScreenHeight: CGFloat = 900

    public var targetMode: NotchTargetMode = .inbox
    public var selectedFolderID: UUID?

    public var clipboardXPostURL: URL?
    public var clipboardLink: ClipboardDetectedLink?
    public var processingMessage: String?
    public var statusBanner: String?
    public var lastDropTimestamp: Date?

    public init() {}

    /// Height of the top wing row aligned beside the physical MacBook camera notch.
    public var topNotchBandHeight: CGFloat {
        max(38, physicalNotchHeight + (hasPhysicalNotch ? 2 : 0))
    }

    /// Central horizontal dead zone kept strictly empty inside `topNotchBandHeight` for the camera housing.
    public var notchCenterClearanceWidth: CGFloat {
        max(216, physicalNotchWidth + 24)
    }

    /// Inner capsule width in Compact mode (excluding the two concave top ears).
    public var compactBodyWidth: CGFloat {
        max(636, notchCenterClearanceWidth + 390)
    }

    /// Total width of `NotchShellShape` in Compact mode including both concave top bezel ears.
    public var compactShapeWidth: CGFloat {
        compactBodyWidth + Self.topEarRadius * 2
    }

    /// Total height of the slim drop-only Collection Capsule (quick capture + drop well + expand pill).
    public var dropOnlyCardHeight: CGFloat {
        topNotchBandHeight + 164
    }

    /// Total height of the pure-black notch capsule in Compact mode (keeps quick capture + recent strip).
    public var compactCardHeight: CGFloat {
        topNotchBandHeight + 292
    }

    /// Determines whether the Recent Assets strip should start expanded when opening from collapsed state.
    public static func shouldShowRecentStripOnExpand(
        presentationMode: NotchShelfPresentationMode,
        trigger: NotchExpandTrigger
    ) -> Bool {
        switch presentationMode {
        case .alwaysShowRecent:
            return true
        case .dropOnlyOnDrag:
            return trigger == .hover || trigger == .manual
        case .alwaysDropOnlyUntilExpanded:
            return false
        }
    }

    /// Inner capsule width in Full-Waterfall Gallery mode.
    public var fullGalleryBodyWidth: CGFloat {
        min(980, max(720, activeScreenWidth - 140))
    }

    /// Total width of `NotchShellShape` in Full-Waterfall Gallery mode.
    public var fullGalleryShapeWidth: CGFloat {
        fullGalleryBodyWidth + Self.topEarRadius * 2
    }

    /// Total height of the pure-black notch capsule in Full-Waterfall Gallery mode.
    public var fullGalleryCardHeight: CGFloat {
        min(580, max(440, activeScreenHeight - 160))
    }

    /// Fixed maximum shape width for the backing transparent `NSPanel` so expanding/collapsing
    /// between compact & full gallery NEVER calls `NSWindow.setFrame` mid-spring.
    public var maxPanelShapeWidth: CGFloat {
        max(compactShapeWidth, fullGalleryShapeWidth)
    }

    /// Fixed maximum card height for the backing transparent `NSPanel`.
    public var maxPanelCardHeight: CGFloat {
        max(topNotchBandHeight + 292, fullGalleryCardHeight)
    }

    /// Active inner capsule width between vertical side walls (excluding the two concave top ears).
    public var expandedBodyWidth: CGFloat {
        (isFullGalleryExpanded && !isMinimalCaptureOnly) ? fullGalleryBodyWidth : compactBodyWidth
    }

    /// Active total width of `NotchShellShape` including both concave top bezel ears.
    public var expandedShapeWidth: CGFloat {
        expandedBodyWidth + Self.topEarRadius * 2
    }

    /// Active total height of the expanded pure-black notch capsule.
    public var expandedCardHeight: CGFloat {
        if isFullGalleryExpanded && !isMinimalCaptureOnly {
            return fullGalleryCardHeight
        }
        return isRecentStripExpanded ? compactCardHeight : dropOnlyCardHeight
    }
}
