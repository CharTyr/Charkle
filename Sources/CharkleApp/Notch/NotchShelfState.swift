import Foundation

public enum NotchTargetMode: Hashable, Sendable {
    case inbox
    case folder
    case activeMoodboard
}

/// Observable animation & interaction state driving the fixed transparent Notch Shelf NSPanel.
@Observable
public final class NotchShelfState {
    public var isExpanded: Bool = false
    public var isDropTargeted: Bool = false
    public var dragItemCount: Int = 0
    public var notchTopInset: CGFloat = 0
    public var hasPhysicalNotch: Bool = false

    public var targetMode: NotchTargetMode = .inbox
    public var selectedFolderID: UUID?

    public var statusBanner: String?
    public var lastDropTimestamp: Date?

    public init() {}
}
