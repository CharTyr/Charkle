import Foundation

/// Grouped navigation taxonomy for Charkle's centered Settings overlay.
/// Organized into 4 calm sections and 9 focused single-purpose panes.
public enum CharkleSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case foundation
    case capture
    case ecosystem
    case system

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .foundation: "基础与存储"
        case .capture: "采集与操作"
        case .ecosystem: "生态与智能"
        case .system: "系统"
        }
    }

    public var tabs: [CharkleSettingsTab] {
        CharkleSettingsTab.allCases.filter { $0.section == self }
    }
}

public enum CharkleSettingsTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case general
    case library
    case sync
    case notchShelf
    case captureShortcuts
    case ai
    case externalAgents
    case extensions
    case advancedAbout

    public var id: String { rawValue }

    public var section: CharkleSettingsSection {
        switch self {
        case .general, .library, .sync:
            .foundation
        case .notchShelf, .captureShortcuts:
            .capture
        case .ai, .externalAgents, .extensions:
            .ecosystem
        case .advancedAbout:
            .system
        }
    }

    public var label: String {
        switch self {
        case .general: "通用"
        case .library: "素材库"
        case .sync: "云同步"
        case .notchShelf: "刘海浮窗"
        case .captureShortcuts: "采集与快捷键"
        case .ai: "AI 智能"
        case .externalAgents: "外部 Agent"
        case .extensions: "插件与扩展"
        case .advancedAbout: "高级与关于"
        }
    }

    public var iconName: String {
        switch self {
        case .general: "settings"
        case .library: "library"
        case .sync: "drive-sync"
        case .notchShelf: "notch"
        case .captureShortcuts: "screenshot"
        case .ai: "sparkle-board"
        case .externalAgents: "connector"
        case .extensions: "export"
        case .advancedAbout: "filter"
        }
    }
}
