import Foundation

public enum NotchTargetMode: Hashable, Sendable {
    case inbox
    case folder
    case activeMoodboard
}

/// Observable animation & interaction state driving the fixed transparent Notch Shelf NSPanel.
@Observable
public final class NotchShelfState {
    public static let topEarRadius: CGFloat = 12
    public static let bottomCornerRadius: CGFloat = 24

    public var isExpanded: Bool = false
    public var isDropTargeted: Bool = false
    public var dragItemCount: Int = 0

    /// Measured physical MacBook camera housing notch geometry (from `NSScreen.safeAreaInsets` &
    /// `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`), with safe fallbacks for external/mirrored displays.
    public var physicalNotchWidth: CGFloat = 204
    public var physicalNotchHeight: CGFloat = 0
    public var hasPhysicalNotch: Bool = false

    public var targetMode: NotchTargetMode = .inbox
    public var selectedFolderID: UUID?

    public var clipboardXPostURL: URL?
    public var processingMessage: String?
    public var statusBanner: String?
    public var lastDropTimestamp: Date?

    public init() {}

    /// Height of the top wing row aligned beside the physical MacBook camera notch.
    /// Always reserves at least 38pt (or the measured hardware notch height + 2pt) so full-width controls
    /// rendered below this band are never occluded on any MacBook Pro/Air display or scaling mode.
    public var topNotchBandHeight: CGFloat {
        max(38, physicalNotchHeight + (hasPhysicalNotch ? 2 : 0))
    }

    /// Central horizontal dead zone kept strictly empty inside `topNotchBandHeight` for the camera housing.
    public var notchCenterClearanceWidth: CGFloat {
        max(216, physicalNotchWidth + 24)
    }

    /// Inner capsule width between vertical side walls (excluding the two concave top ears).
    /// Scales up automatically on large-text MacBook scalings so both wings keep comfortable room.
    public var expandedBodyWidth: CGFloat {
        max(476, notchCenterClearanceWidth + 244)
    }

    /// Total width of `NotchShellShape` including both concave top bezel ears.
    public var expandedShapeWidth: CGFloat {
        expandedBodyWidth + Self.topEarRadius * 2
    }

    /// Total height of the expanded pure-black notch capsule.
    public var expandedCardHeight: CGFloat {
        topNotchBandHeight + 178
    }
}
