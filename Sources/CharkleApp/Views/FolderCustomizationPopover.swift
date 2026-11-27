import CharkleCanvas
import CharkleCore
import SwiftUI

/// macOS-Tahoe-inspired Customize Folder Popover: live folder preview, 7 macOS preset colors + ColorPicker,
/// categorized SF Symbol gallery, and Emoji badge switcher.
public struct FolderCustomizationPopover: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.charkleAccentSource) private var accentSource
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let folder: FolderRecord
    public let onUpdate: (_ colorHex: String?, _ customSymbol: String?) -> Void

    private var accentColor: Color {
        CharkleTheme.accent(for: colorScheme, source: accentSource)
    }

    @State private var selectedColorHex: String?
    @State private var selectedSymbol: String?
    @State private var customColor: Color = Color(charkleHex: "#3B82F6")
    @State private var showEmojiMode: Bool = false
    @State private var customEmojiInput: String = ""

    public static let macOSFolderColors: [(name: String, hex: String)] = [
        ("红色", "#FF453A"),
        ("橙色", "#FF9F0A"),
        ("黄色", "#FFD60A"),
        ("绿色", "#30D158"),
        ("蓝色", "#0A84FF"),
        ("紫色", "#BF5AF2"),
        ("灰色", "#8E8E93")
    ]

    private struct SymbolGroup: Identifiable {
        let id: String
        let title: String
        let symbols: [String]
    }

    private static let symbolGroups: [SymbolGroup] = [
        SymbolGroup(
            id: "design",
            title: "设计与创意",
            symbols: [
                "paintbrush.fill", "paintpalette.fill", "sparkles", "wand.and.stars",
                "swatchpalette.fill", "pencil.and.outline", "scissors", "ruler.fill",
                "square.on.circle", "cube.fill", "view.3d", "scribble.variable"
            ]
        ),
        SymbolGroup(
            id: "media",
            title: "影像与媒体",
            symbols: [
                "photo.fill", "camera.fill", "film.fill", "play.rectangle.fill",
                "music.note", "waveform", "headphones", "book.fill",
                "doc.richtext.fill", "globe", "link", "bubble.left.and.bubble.right.fill"
            ]
        ),
        SymbolGroup(
            id: "people",
            title: "人物与自然",
            symbols: [
                "person.fill", "person.2.fill", "face.smiling", "eye.fill",
                "hand.raised.fill", "heart.fill", "star.fill", "flame.fill",
                "sun.max.fill", "moon.stars.fill", "leaf.fill", "pawprint.fill"
            ]
        ),
        SymbolGroup(
            id: "dev",
            title: "开发与工作",
            symbols: [
                "chevron.left.forwardslash.chevron.right", "terminal.fill", "cpu.fill", "desktopcomputer",
                "iphone", "gamecontroller.fill", "briefcase.fill", "archivebox.fill",
                "tray.full.fill", "bolt.fill", "flag.fill", "bookmark.fill"
            ]
        )
    ]

    private static let emojiPresets: [String] = [
        "🎨", "✨", "🌸", "🌊", "🔥", "⚡️", "🌙", "☀️",
        "🎬", "📷", "🎧", "🎮", "🧩", "📐", "💎", "🚀",
        "💻", "📱", "🧠", "🦊", "🐱", "🌿", "🏔️", "🏙️",
        "⭐️", "❤️", "📌", "🔖", "📦", "🗂️", "🧪", "🛠️"
    ]

    public init(
        folder: FolderRecord,
        onUpdate: @escaping (_ colorHex: String?, _ customSymbol: String?) -> Void
    ) {
        self.folder = folder
        self.onUpdate = onUpdate
        _selectedColorHex = State(initialValue: folder.colorHex)
        _selectedSymbol = State(initialValue: folder.customSymbol)
        if let hex = folder.colorHex {
            _customColor = State(initialValue: Color(charkleHex: hex))
        }
        if folder.customSymbol?.hasPrefix("emoji:") == true {
            _showEmojiMode = State(initialValue: true)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Live Large Folder Preview
            VStack(spacing: 6) {
                CharkleFolderIcon(
                    colorHex: selectedColorHex,
                    customSymbol: selectedSymbol,
                    size: 58,
                    isActive: false
                )
                .animation(CharkleMotion.accessible(CharkleMotion.enterSm, reduced: reduceMotion), value: selectedColorHex)
                .animation(CharkleMotion.accessible(CharkleMotion.enterSm, reduced: reduceMotion), value: selectedSymbol)

                Text(folder.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.top, 16)
            .padding(.bottom, 12)

            // macOS-style Color Dot Strip + Reset + Custom ColorPicker
            HStack(spacing: 8) {
                Button {
                    selectedColorHex = nil
                    commit()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.primary.opacity(0.06))
                            .frame(width: 22, height: 22)
                        Image(systemName: "slash.circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .overlay(
                        Circle()
                            .strokeBorder(selectedColorHex == nil ? accentColor : Color.clear, lineWidth: 2)
                    )
                }
                .buttonStyle(.plain)
                .help("恢复默认颜色")

                ForEach(Self.macOSFolderColors, id: \.hex) { preset in
                    let active = selectedColorHex?.caseInsensitiveCompare(preset.hex) == .orderedSame
                    Button {
                        selectedColorHex = preset.hex
                        commit()
                    } label: {
                        Circle()
                            .fill(Color(charkleHex: preset.hex))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.white.opacity(active ? 0.92 : 0), lineWidth: 2)
                                    .padding(1.5)
                            )
                            .overlay(
                                Circle()
                                    .strokeBorder(active ? accentColor : Color.black.opacity(0.1), lineWidth: active ? 2 : 0.75)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                }

                ColorPicker("", selection: $customColor, supportsOpacity: false)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: customColor) { _, newValue in
                        if let hex = newValue.folderCustomHex {
                            selectedColorHex = hex
                            commit()
                        }
                    }
                    .help("自定义任意颜色")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            Divider()

            // Symbol Grid or Emoji Picker
            ScrollView {
                if showEmojiMode {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 6) {
                            TextField("输入任意表情符号…", text: $customEmojiInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13))
                                .onSubmit { applyCustomEmoji() }
                            Button("应用") { applyCustomEmoji() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(customEmojiInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 8) {
                            ForEach(Self.emojiPresets, id: \.self) { emoji in
                                let token = "emoji:\(emoji)"
                                let active = selectedSymbol == token
                                Button {
                                    selectedSymbol = active ? nil : token
                                    commit()
                                } label: {
                                    Text(emoji)
                                        .font(.system(size: 18))
                                        .frame(width: 30, height: 30)
                                        .background(
                                            active ? accentColor.opacity(0.20) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(14)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Self.symbolGroups) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 8) {
                                    ForEach(group.symbols, id: \.self) { sf in
                                        let token = "sf:\(sf)"
                                        let active = selectedSymbol == token
                                        Button {
                                            selectedSymbol = active ? nil : token
                                            commit()
                                        } label: {
                                            Image(systemName: sf)
                                                .font(.system(size: 15, weight: .medium))
                                                .foregroundStyle(active ? accentColor : Color.primary.opacity(0.76))
                                                .frame(width: 34, height: 30)
                                                .background(
                                                    active ? accentColor.opacity(0.16) : Color.primary.opacity(0.03),
                                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .padding(14)
                }
            }
            .frame(height: 250)

            Divider()

            // Bottom Footer: Clear | Emoji Toggle
            HStack(spacing: 8) {
                Button {
                    selectedColorHex = nil
                    selectedSymbol = nil
                    commit()
                } label: {
                    Text("清除")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    showEmojiMode.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showEmojiMode ? "square.grid.2x2" : "face.smiling")
                            .font(.system(size: 12))
                        Text(showEmojiMode ? "系统图标" : "表情符号")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        showEmojiMode ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .foregroundStyle(showEmojiMode ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
            }
            .padding(10)
        }
        .frame(width: 288)
    }

    private func applyCustomEmoji() {
        let trimmed = customEmojiInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstChar = trimmed.first else { return }
        selectedSymbol = "emoji:\(firstChar)"
        customEmojiInput = ""
        commit()
    }

    private func commit() {
        onUpdate(selectedColorHex, selectedSymbol)
    }
}

private extension Color {
    var folderCustomHex: String? {
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int((nsColor.redComponent * 255).rounded())
        let g = Int((nsColor.greenComponent * 255).rounded())
        let b = Int((nsColor.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}
