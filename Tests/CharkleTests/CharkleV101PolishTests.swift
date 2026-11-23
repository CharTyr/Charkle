import CharkleCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("v1.0.1 Hierarchy, Markdown README & EXIF/AI Prompt Tests")
struct CharkleV101PolishTests {
    @Test("FolderHierarchyNode builds nested tree, sorts deterministically, and tolerates cycles")
    func folderHierarchyTree() {
        let artID = UUID()
        let subA = UUID()
        let subB = UUID()
        let grandChild = UUID()
        let logoID = UUID()
        let orphanID = UUID()

        let folders: [FolderRecord] = [
            FolderRecord(id: subB, name: "川瀬巴水", parentID: artID, sortOrder: 2),
            FolderRecord(id: grandChild, name: "精选", parentID: subA, sortOrder: 0),
            FolderRecord(id: logoID, name: "Logo", parentID: nil, sortOrder: 1),
            FolderRecord(id: subA, name: "mashiroka", parentID: artID, sortOrder: 1),
            FolderRecord(id: artID, name: "插画", parentID: nil, sortOrder: 0),
            FolderRecord(id: orphanID, name: "独立目录", parentID: UUID(), sortOrder: 2)
        ]

        let roots = FolderHierarchyNode.buildTree(from: folders)
        #expect(roots.map(\.folder.name) == ["插画", "Logo", "独立目录"])
        #expect(roots[0].children.map(\.folder.name) == ["mashiroka", "川瀬巴水"])
        #expect(roots[0].children[0].children.map(\.folder.name) == ["精选"])
        #expect(roots[0].contains(folderID: grandChild))
        #expect(!roots[1].contains(folderID: grandChild))

        let flat = FolderHierarchyNode.flattened(from: folders)
        #expect(flat.map { ($0.folder.name, $0.depth) }.map { "\($0.0):\($0.1)" } == [
            "插画:0", "mashiroka:1", "精选:2", "川瀬巴水:1", "Logo:0", "独立目录:0"
        ])
    }

    @Test("MarkdownDocumentParser parses GitHub README HTML hero, relative SVG/WebP images, and GFM tables")
    func githubReadmeHTMLAndGFMTable() {
        let readme = """
        <p align="center">
          <img src="site/src/app/icon.svg" width="72" height="72" alt="" />
        </p>

        <h1 align="center">Sample Icons</h1>

        <p align="center">
          <strong>An open toolkit that draws animated icons.</strong><br />
          Plus 2,800+ open-source icons drawn with it.
        </p>

        <p align="center">
          <a href="#install-the-kit">Install the kit</a> &middot;
          <a href="https://icons.example.com/icons/">Browse the icons</a>
        </p>

        <p align="center">
          <img src="assets/hover.webp" alt="Sixteen icons" />
        </p>

        ## What's included

        | Part | What you get |
        | --- | :---: |
        | **Toolkit** | Rules and engine |
        | **Website** | [icons.example.com](https://icons.example.com) |

        ```html
        <p align="center">Keep raw code untouched</p>
        ```
        """

        let ctx = MarkdownURLContext.github(owner: "example-org", repo: "sample-icons", branch: "main")
        let blocks = MarkdownDocumentParser.parse(readme, urlContext: ctx)

        // 1. Centered SVG image with width=72, height=72 & resolved raw URL
        guard case .image(_, let iconImg, let iconAlign) = blocks[0] else {
            Issue.record("Expected first block to be image, got \(blocks[0])")
            return
        }
        #expect(iconAlign == .center)
        #expect(iconImg.url == "https://raw.githubusercontent.com/example-org/sample-icons/main/site/src/app/icon.svg")
        #expect(iconImg.width == 72)
        #expect(iconImg.height == 72)

        // 2. Centered H1
        guard case .heading(_, let level, let h1Text, let h1Align) = blocks[1] else {
            Issue.record("Expected second block to be heading, got \(blocks[1])")
            return
        }
        #expect(level == 1)
        #expect(h1Text == "Sample Icons")
        #expect(h1Align == .center)

        // 3. Centered paragraph with converted **strong** and <br />
        guard case .paragraph(_, let pText, let pAlign) = blocks[2] else {
            Issue.record("Expected third block to be paragraph, got \(blocks[2])")
            return
        }
        #expect(pAlign == .center)
        #expect(pText.contains("**An open toolkit that draws animated icons.**"))
        #expect(pText.contains("\nPlus 2,800+ open-source icons drawn with it."))

        // 4. Centered link bar with resolved GitHub anchor + decoded &middot;
        guard case .paragraph(_, let linksText, let linksAlign) = blocks[3] else {
            Issue.record("Expected fourth block to be links paragraph")
            return
        }
        #expect(linksAlign == .center)
        #expect(linksText.contains("[Install the kit](https://github.com/example-org/sample-icons#install-the-kit)"))
        #expect(linksText.contains("·"))

        // 5. Centered hover.webp resolved against raw.githubusercontent.com
        guard case .image(_, let hoverImg, let hoverAlign) = blocks[4] else {
            Issue.record("Expected fifth block to be hover.webp image")
            return
        }
        #expect(hoverAlign == .center)
        #expect(hoverImg.url == "https://raw.githubusercontent.com/example-org/sample-icons/main/assets/hover.webp")

        // 6. H2 + GFM Table
        guard case .heading(_, 2, "What's included", .leading) = blocks[5] else {
            Issue.record("Expected H2 What's included, got \(blocks[5])")
            return
        }
        guard case .table(_, let headers, let aligns, let rows) = blocks[6] else {
            Issue.record("Expected GFM table block, got \(blocks[6])")
            return
        }
        #expect(headers == ["Part", "What you get"])
        #expect(aligns == [.leading, .center])
        #expect(rows.count == 2)
        #expect(rows[0][0] == "**Toolkit**")
        #expect(rows[1][1] == "[icons.example.com](https://icons.example.com)")

        // 7. Fenced code block preserves raw HTML verbatim
        guard case .code(_, let lang, let code) = blocks[7] else {
            Issue.record("Expected code block")
            return
        }
        #expect(lang == "html")
        #expect(code == #"<p align="center">Keep raw code untouched</p>"#)
    }

    @Test("ImageMetadataExtractor parses A1111 parameters, ComfyUI graph JSON, and real PNG tEXt + JPEG EXIF")
    func exifAndAIGenerationParsing() throws {
        // 1. A1111 / Forge parameters
        let a1111 = """
        masterpiece, ukiyo-e seaside sail, golden sunset <lora:woodblock_v2:0.8>
        Negative prompt: blurry, lowres, watermark
        Steps: 28, Sampler: DPM++ 2M, Schedule type: Karras, CFG scale: 7, Seed: 4219837412, Size: 896x1152, Model hash: a1b2c3d4, Model: flux1-dev, Clip skip: 2, Version: f2.0.1v1.10.1-forge
        """
        let parsedA1111 = try #require(ImageMetadataExtractor.parseA1111Parameters(a1111))
        #expect(parsedA1111.generator == "SD WebUI Forge")
        #expect(parsedA1111.prompt?.contains("ukiyo-e seaside sail") == true)
        #expect(parsedA1111.negativePrompt == "blurry, lowres, watermark")
        #expect(parsedA1111.steps == 28)
        #expect(parsedA1111.sampler == "DPM++ 2M")
        #expect(parsedA1111.scheduler == "Karras")
        #expect(parsedA1111.cfgScale == 7.0)
        #expect(parsedA1111.seed == "4219837412")
        #expect(parsedA1111.modelName == "flux1-dev")
        #expect(parsedA1111.clipSkip == 2)
        #expect(parsedA1111.loras == ["woodblock_v2:0.8"])

        // 2. ComfyUI graph JSON
        let comfyJSON = """
        {
          "3": { "class_type": "KSampler", "inputs": { "seed": 998877665544, "steps": 24, "cfg": 6.5, "sampler_name": "euler", "scheduler": "normal", "positive": ["6", 0], "negative": ["7", 0] } },
          "4": { "class_type": "CheckpointLoaderSimple", "inputs": { "ckpt_name": "models/sdxl_base.safetensors" } },
          "5": { "class_type": "EmptyLatentImage", "inputs": { "width": 1024, "height": 1536 } },
          "6": { "class_type": "CLIPTextEncode", "inputs": { "text": "serene alpine lake at dawn, cinematic lighting" } },
          "7": { "class_type": "CLIPTextEncode", "inputs": { "text": "oversaturated, artifact" } },
          "8": { "class_type": "LoraLoader", "inputs": { "lora_name": "film_grain.safetensors" } }
        }
        """
        let parsedComfy = try #require(ImageMetadataExtractor.parseComfyUIPromptJSON(comfyJSON))
        #expect(parsedComfy.generator == "ComfyUI")
        #expect(parsedComfy.prompt == "serene alpine lake at dawn, cinematic lighting")
        #expect(parsedComfy.negativePrompt == "oversaturated, artifact")
        #expect(parsedComfy.modelName == "sdxl_base.safetensors")
        #expect(parsedComfy.sampler == "euler")
        #expect(parsedComfy.scheduler == "normal")
        #expect(parsedComfy.steps == 24)
        #expect(parsedComfy.cfgScale == 6.5)
        #expect(parsedComfy.seed == "998877665544")
        #expect(parsedComfy.sizeText == "1024 × 1536")
        #expect(parsedComfy.loras == ["film_grain.safetensors"])

        // 3. Synthetic JPEG with full EXIF + TIFF + GPS written via CGImageDestination
        let tmpDir = FileManager.default.temporaryDirectory.appending(path: "charkle-exif-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let jpegURL = tmpDir.appending(path: "shot.jpg")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let cgImage = try #require(ctx.makeImage())

        let dest = try #require(CGImageDestinationCreateWithURL(jpegURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "SONY",
                kCGImagePropertyTIFFModel: "ILCE-7M4",
                kCGImagePropertyTIFFSoftware: "Lightroom Classic"
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "FE 35mm F1.4 GM",
                kCGImagePropertyExifDateTimeOriginal: "2026:08:12 17:45:20",
                kCGImagePropertyExifExposureTime: 0.001,
                kCGImagePropertyExifFNumber: 1.4,
                kCGImagePropertyExifISOSpeedRatings: [100],
                kCGImagePropertyExifFocalLength: 35.0
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 35.6762,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 139.6503,
                kCGImagePropertyGPSLongitudeRef: "E"
            ]
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))

        let extracted = ImageMetadataExtractor.extract(from: jpegURL)
        let exif = try #require(extracted.photoExif)
        #expect(exif.cameraDisplayName == "SONY ILCE-7M4")
        #expect(exif.lensModel == "FE 35mm F1.4 GM")
        #expect(exif.capturedAt == "2026-08-12 17:45:20")
        #expect(exif.exposureTime == "1/1000s")
        #expect(exif.formattedAperture == "f/1.4")
        #expect(exif.iso == 100)
        #expect(exif.exposureSummary == "35mm · f/1.4 · 1/1000s · ISO 100")
        #expect(exif.software == "Lightroom Classic")
        #expect(abs((exif.latitude ?? 0) - 35.6762) < 0.001)
        #expect(abs((exif.longitude ?? 0) - 139.6503) < 0.001)

        // 4. Synthetic PNG with raw tEXt `parameters` chunk
        let pngURL = tmpDir.appending(path: "gen.png")
        let pngDest = try #require(CGImageDestinationCreateWithURL(pngURL as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(pngDest, cgImage, nil)
        #expect(CGImageDestinationFinalize(pngDest))

        var pngBytes = try Data(contentsOf: pngURL)
        // Insert a tEXt chunk right before the 12-byte IEND chunk
        let iendSize = 12
        let textPayload = Data("parameters\0\(a1111)".utf8)
        var chunk = Data()
        var lenBE = UInt32(textPayload.count).bigEndian
        chunk.append(Data(bytes: &lenBE, count: 4))
        chunk.append(Data("tEXt".utf8))
        chunk.append(textPayload)
        var fakeCRC = UInt32(0).bigEndian
        chunk.append(Data(bytes: &fakeCRC, count: 4))
        pngBytes.insert(contentsOf: chunk, at: pngBytes.count - iendSize)
        try pngBytes.write(to: pngURL)

        let pngExtracted = ImageMetadataExtractor.extract(from: pngURL)
        let pngAI = try #require(pngExtracted.aiGeneration)
        #expect(pngAI.modelName == "flux1-dev")
        #expect(pngAI.steps == 28)
        #expect(pngAI.seed == "4219837412")
    }

    @Test("InspectorInfoSection normalizes persisted order, drags EXIF to top, and steps past hidden cards")
    func inspectorSectionOrdering() {
        // Deduplicates, ignores unknown legacy keys, and appends missing sections in default order.
        let normalized = InspectorInfoSection.normalizedOrder(from: ["photoExif", "unknownKey", "photoExif", "previewIdentity"])
        #expect(normalized.first == .photoExif)
        #expect(normalized[1] == .previewIdentity)
        #expect(normalized.count == InspectorInfoSection.defaultOrder.count)

        // Drag EXIF to top above previewIdentity
        let exifTop = InspectorInfoSection.moving(.photoExif, toTarget: .previewIdentity, in: InspectorInfoSection.defaultOrder)
        #expect(exifTop.first == .photoExif)
        #expect(exifTop[1] == .previewIdentity)

        // Step mediaSpecs up when aiGeneration & photoExif are hidden for a screenshot
        let visible: [InspectorInfoSection] = [.previewIdentity, .quickActions, .colorsAndTags, .notesAndOCR, .mediaSpecs]
        let stepped = InspectorInfoSection.stepping(.mediaSpecs, delta: -1, visible: visible, in: InspectorInfoSection.defaultOrder)
        let mediaIdx = stepped.firstIndex(of: .mediaSpecs)!
        let notesIdx = stepped.firstIndex(of: .notesAndOCR)!
        #expect(mediaIdx < notesIdx)

        // Move to bottom
        let movedBottom = InspectorInfoSection.movingToBottom(.previewIdentity, in: exifTop)
        #expect(movedBottom.last == .previewIdentity)
    }
}
