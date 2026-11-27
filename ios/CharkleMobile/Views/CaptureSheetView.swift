import CharkleCore
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Multi-source mobile capture hub: Photos multi-select, Camera, Files, 1-tap Clipboard,
/// and Web / Xiaohongshu / X / GitHub link or share copy ingestion.
struct CaptureSheetView: View {
    @Bindable var store: MobileAppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedFolderID: UUID?
    @State private var rawLinkText: String = ""
    @State private var notesText: String = ""
    @State private var tagsText: String = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isFileImporterPresented = false
    @State private var isCameraPresented = false
    @State private var autoExtractSocialMedia = false
    @State private var isFolderPickerPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // 1. Target destination picker (top-level roots + hierarchical picker sheet)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("存入位置")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            Spacer()
                            if !store.folderTree.isEmpty {
                                Button {
                                    MobileHaptics.light()
                                    isFolderPickerPresented = true
                                } label: {
                                    Label("按层级选择", systemImage: "list.bullet.indent")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(MobileTheme.accent(for: colorScheme))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                destinationPill(title: "收件箱", id: nil)
                                if let selectedFolderID,
                                   !store.folderTree.contains(where: { $0.folder.id == selectedFolderID }),
                                   let path = FolderHierarchyNode.breadcrumbPath(for: selectedFolderID, in: store.folderTree) {
                                    destinationPill(title: path, id: selectedFolderID)
                                }
                                ForEach(store.folderTree) { node in
                                    destinationPill(title: node.folder.name, id: node.folder.id)
                                }
                            }
                        }
                    }
                    .sheet(isPresented: $isFolderPickerPresented) {
                        NavigationStack {
                            HierarchicalFolderPickerSheet(
                                title: "选择存入文件夹",
                                folderTree: store.folderTree,
                                currentFolderID: selectedFolderID,
                                onPick: { folderID, _ in
                                    selectedFolderID = folderID
                                    isFolderPickerPresented = false
                                }
                            )
                        }
                        .presentationDetents([.medium, .large])
                    }

                    // 2. Quick capture sources grid
                    VStack(alignment: .leading, spacing: 10) {
                        Text("快速采集")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))

                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            PhotosPicker(
                                selection: $photoItems,
                                maxSelectionCount: 20,
                                matching: .any(of: [.images, .videos])
                            ) {
                                CaptureSourceTileView(
                                    icon: "photo.on.rectangle.angled",
                                    title: "从相册导入",
                                    subtitle: "支持图片与视频多选"
                                )
                            }
                            .buttonStyle(MobileTactileButtonStyle())

                            Button {
                                Task {
                                    if await store.captureFromPasteboard(targetFolderID: selectedFolderID) {
                                        dismiss()
                                    }
                                }
                            } label: {
                                CaptureSourceTileView(
                                    icon: "doc.on.clipboard",
                                    title: "收藏剪贴板",
                                    subtitle: "自动识别图片或链接"
                                )
                            }
                            .buttonStyle(MobileTactileButtonStyle())

                            Button {
                                isFileImporterPresented = true
                            } label: {
                                CaptureSourceTileView(
                                    icon: "folder.badge.plus",
                                    title: "从「文件」导入",
                                    subtitle: "图片、PDF、设计稿、3D"
                                )
                            }
                            .buttonStyle(MobileTactileButtonStyle())

                            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                Button {
                                    isCameraPresented = true
                                } label: {
                                    CaptureSourceTileView(
                                        icon: "camera",
                                        title: "拍照采集",
                                        subtitle: "随手拍下实物与色彩灵感"
                                    )
                                }
                                .buttonStyle(MobileTactileButtonStyle())
                            }
                        }
                    }

                    // 3. Link / Xiaohongshu / X / GitHub capture
                    VStack(alignment: .leading, spacing: 10) {
                        Text("粘贴链接或分享口令")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))

                        TextField(
                            "支持 B站、YouTube、小红书、X、GitHub 或任意网页链接…",
                            text: $rawLinkText,
                            axis: .vertical
                        )
                        .lineLimit(3...5)
                        .font(.system(size: 14))
                        .padding(12)
                        .background(
                            MobileTheme.surfaceElevated(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                        )

                        TextField("标签（空格或逗号分隔，可选）", text: $tagsText)
                            .font(.system(size: 13.5))
                            .textInputAutocapitalization(.never)
                            .padding(11)
                            .background(
                                MobileTheme.surfaceElevated(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                            )

                        TextField("备注（可选）", text: $notesText)
                            .font(.system(size: 13.5))
                            .padding(11)
                            .background(
                                MobileTheme.surfaceElevated(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                            )

                        Toggle(isOn: $autoExtractSocialMedia) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("社媒链接自动拆出独立素材")
                                    .font(.system(size: 13.5, weight: .medium))
                                Text("将小红书 / X 帖子内的图片与视频同步存为单独素材，并保留原帖来源")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            }
                        }
                        .tint(MobileTheme.accent(for: colorScheme))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            MobileTheme.surfaceElevated(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                        )

                        Button {
                            Task {
                                let ok = await store.captureURLOrShareText(
                                    rawLinkText,
                                    notes: notesText,
                                    tags: parsedTags,
                                    targetFolderID: selectedFolderID,
                                    autoExtractSocialMedia: autoExtractSocialMedia
                                )
                                if ok { dismiss() }
                            }
                        } label: {
                            HStack {
                                if store.isIngesting {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "plus.circle.fill")
                                }
                                Text(store.isIngesting ? "正在采集与解析…" : "收藏链接 / 文本")
                                    .font(.system(size: 14.5, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                MobileTheme.accentButtonFill(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                            )
                        }
                        .buttonStyle(MobileTactileButtonStyle())
                        .disabled(rawLinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isIngesting)
                    }
                }
                .padding(16)
            }
            .background(MobileTheme.galleryGround(for: colorScheme))
            .navigationTitle("采集素材")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                selectedFolderID = store.activeFolderIDForCapture
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await importSelectedPhotos(items) }
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.image, .movie, .pdf, .plainText, .audio, .usdz, .data],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task { await importFiles(urls) }
                case .failure(let error):
                    store.showToast("选择文件失败：\(error.localizedDescription)", tone: .error)
                }
            }
            .fullScreenCover(isPresented: $isCameraPresented) {
                CameraCaptureView { image in
                    isCameraPresented = false
                    guard let image, let data = image.jpegData(compressionQuality: 0.92) else { return }
                    let name = "相机拍摄-\(Int(Date().timeIntervalSince1970)).jpg"
                    Task {
                        _ = await store.ingestInputs(
                            [.imageData(data, suggestedName: name, sourceURL: nil)],
                            targetFolderID: selectedFolderID,
                            tags: parsedTags
                        )
                        dismiss()
                    }
                }
                .ignoresSafeArea()
            }
        }
    }

    private var parsedTags: [String] {
        tagsText
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func destinationPill(title: String, id: UUID?) -> some View {
        let selected = selectedFolderID == id
        return Button {
            selectedFolderID = id
        } label: {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    selected
                        ? MobileTheme.accentButtonFill(for: colorScheme)
                        : MobileTheme.surfaceElevated(for: colorScheme),
                    in: Capsule()
                )
                .overlay(Capsule().strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: selected ? 0 : 0.75))
        }
        .buttonStyle(.plain)
    }

    private func importSelectedPhotos(_ items: [PhotosPickerItem]) async {
        var inputs: [CaptureInput] = []
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "CharklePhotoImports-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for (index, item) in items.enumerated() {
            if let data = try? await item.loadTransferable(type: Data.self) {
                let isVideo = item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) })
                if isVideo {
                    let fileURL = tempDir.appending(path: "video-\(index + 1).mov")
                    if (try? data.write(to: fileURL, options: .atomic)) != nil {
                        inputs.append(.fileURL(fileURL))
                    }
                } else {
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    let name = "相册素材-\(Int(Date().timeIntervalSince1970))-\(index + 1).\(ext)"
                    inputs.append(.imageData(data, suggestedName: name, sourceURL: nil))
                }
            }
        }
        photoItems = []
        guard !inputs.isEmpty else {
            store.showToast("未能读取所选相册项目", tone: .warning)
            return
        }
        _ = await store.ingestInputs(inputs, targetFolderID: selectedFolderID, tags: parsedTags)
        dismiss()
    }

    private func importFiles(_ urls: [URL]) async {
        var scopedURLs: [URL] = []
        for url in urls {
            if url.startAccessingSecurityScopedResource() {
                scopedURLs.append(url)
            }
        }
        defer {
            for url in scopedURLs {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let pureRefURLs = urls.filter { PureRefCodec.isPureRefFileURL($0) }
        let regularURLs = urls.filter { !PureRefCodec.isPureRefFileURL($0) }
        var didImportAny = false

        if !pureRefURLs.isEmpty {
            let results = await store.importPureRefScenes(urls: pureRefURLs, targetFolderID: selectedFolderID)
            didImportAny = didImportAny || !results.isEmpty
        }
        if !regularURLs.isEmpty {
            let inputs = regularURLs.map { CaptureInput.fileURL($0) }
            let imported = await store.ingestInputs(inputs, targetFolderID: selectedFolderID, tags: parsedTags)
            didImportAny = didImportAny || !imported.isEmpty
        }
        if didImportAny {
            dismiss()
        }
    }
}

private struct CaptureSourceTileView: View {
    let icon: String
    let title: String
    let subtitle: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(MobileTheme.accent(for: colorScheme))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            MobileTheme.surfaceElevated(for: colorScheme),
            in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
        )
    }
}

private struct CameraCaptureView: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onFinish: (UIImage?) -> Void

        init(onFinish: @escaping (UIImage?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage
            onFinish(image)
        }
    }
}
