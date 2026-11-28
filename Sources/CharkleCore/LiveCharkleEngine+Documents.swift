import Foundation

extension LiveCharkleEngine {
    // MARK: - Documents & Version Stacks

    public func detectVersionStackCandidate(
        for fileURL: URL,
        targetFolderID: UUID?
    ) async throws -> VersionStackCandidate? {
        nil
    }

    public func detectVersionStackCandidate(
        forAssetID assetID: UUID
    ) async throws -> VersionStackCandidate? {
        nil
    }

    public func manageVersionStack(
        _ mutation: VersionStackMutation
    ) async throws -> [AssetRecord] {
        var out: [AssetRecord] = []
        for id in mutation.assetIDs {
            if let asset = try await database.asset(id: id) {
                out.append(asset)
            }
        }
        return out
    }

    public func readStructuredDocument(
        assetID: UUID
    ) async throws -> StructuredDocumentPayload {
        guard let asset = try await database.asset(id: assetID) else {
            throw DriveTransportError.fileNotFound(assetID.uuidString)
        }
        let ext = (asset.fileName as NSString).pathExtension
        let family = asset.richMetadata?.document?.formatFamily ?? DocumentFormatFamily.detect(fileExtension: ext).rawValue
        let text = asset.ocrText ?? asset.richMetadata?.textExcerpt ?? asset.notes
        let blocks = text.isEmpty ? [] : [DocumentBlock(id: "blk-0", index: 0, kind: .paragraph, text: text)]
        return StructuredDocumentPayload(
            assetID: asset.id,
            formatFamily: family,
            title: asset.title,
            authorOrEditor: asset.richMetadata?.versionStack?.editorName,
            wordCount: asset.richMetadata?.document?.wordCount ?? text.count,
            pageCount: max(1, asset.richMetadata?.document?.pageCount ?? 1),
            hasTextLayer: asset.richMetadata?.document?.hasTextLayer ?? true,
            hasNativeRevisions: asset.richMetadata?.document?.hasNativeRevisions ?? false,
            blocks: blocks,
            plainText: text
        )
    }

    public func compareDocumentVersions(
        baseAssetID: UUID,
        targetAssetID: UUID,
        sheetName: String? = nil,
        primaryKeyCol: Int? = nil,
        useOCRIfScanned: Bool = false
    ) async throws -> DocumentComparisonReport {
        guard let base = try await database.asset(id: baseAssetID) else {
            throw DriveTransportError.fileNotFound(baseAssetID.uuidString)
        }
        guard let target = try await database.asset(id: targetAssetID) else {
            throw DriveTransportError.fileNotFound(targetAssetID.uuidString)
        }
        let ext = (target.fileName as NSString).pathExtension
        let family = target.richMetadata?.document?.formatFamily ?? DocumentFormatFamily.detect(fileExtension: ext).rawValue
        return DocumentComparisonReport(
            baseAssetID: base.id,
            targetAssetID: target.id,
            baseTitle: base.title,
            targetTitle: target.title,
            formatFamily: family,
            summary: DocumentDiffSummary(comparedToAssetID: base.id),
            supportsVisualPageOverlay: family == DocumentFormatFamily.pdf.rawValue
        )
    }

    public func synthesizeDocumentVersion(
        baseAssetID: UUID,
        targetAssetID: UUID,
        preferTargetAsTemplate: Bool = true,
        decisions: [DocumentMergeDecision],
        editorName: String? = nil,
        changeNote: String? = nil
    ) async throws -> AssetRecord {
        guard let target = try await database.asset(id: targetAssetID) else {
            throw DriveTransportError.fileNotFound(targetAssetID.uuidString)
        }
        return target
    }
}
