import CoreGraphics
import Foundation
import Vision
import os

private let visionLogger = Logger(subsystem: "com.charkle.core", category: "Vision")

public nonisolated enum VisionAnalyzer {
    /// Runs OCR and FeaturePrint in a single `VNImageRequestHandler` pass so the decoded pixel buffer
    /// is uploaded to Vision/Metal once instead of twice.
    public static func analyzeSync(in cgImage: CGImage) -> (ocrText: String, featurePrintData: Data?) {
        autoreleasepool {
            let ocrRequest = VNRecognizeTextRequest()
            ocrRequest.recognitionLevel = .accurate
            ocrRequest.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            ocrRequest.usesLanguageCorrection = true

            let featureRequest = VNGenerateImageFeaturePrintRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([ocrRequest, featureRequest])
                let text = (ocrRequest.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                let featureData = featureRequest.results?.first.flatMap {
                    try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
                }
                return (text, featureData)
            } catch {
                visionLogger.debug("Combined Vision analysis fell back to split pass: \(error.localizedDescription, privacy: .private)")
                return (recognizeTextSync(in: cgImage), generateFeaturePrint(for: cgImage))
            }
        }
    }

    public static func recognizeTextSync(in cgImage: CGImage) -> String {
        autoreleasepool {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
                let observations = request.results ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                return lines.joined(separator: "\n")
            } catch {
                visionLogger.debug("OCR failed: \(error.localizedDescription, privacy: .private)")
                return ""
            }
        }
    }

    /// Generate serialized `VNFeaturePrintObservation` data for offline visual similarity & Search-by-Image.
    public static func generateFeaturePrint(for cgImage: CGImage) -> Data? {
        autoreleasepool {
            let request = VNGenerateImageFeaturePrintRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
                guard let observation = request.results?.first else {
                    return nil
                }
                return try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
            } catch {
                visionLogger.debug("FeaturePrint failed: \(error.localizedDescription, privacy: .private)")
                return nil
            }
        }
    }

    static func unarchiveFeaturePrint(_ data: Data) -> VNFeaturePrintObservation? {
        autoreleasepool {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
        }
    }

    static func visualDistance(between lhs: VNFeaturePrintObservation, and rhs: VNFeaturePrintObservation) -> Float? {
        var distance: Float = 0
        do {
            try lhs.computeDistance(&distance, to: rhs)
            return distance
        } catch {
            return nil
        }
    }

    /// Compute perceptual visual distance between two serialized `VNFeaturePrintObservation` payloads.
    /// Lower is more visually similar (0 = identical; on Revision 2 unrelated images sit around 0.98–1.25).
    public static func visualDistance(between lhsData: Data, and rhsData: Data) -> Float? {
        autoreleasepool {
            guard let lhs = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: lhsData),
                  let rhs = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: rhsData) else {
                return nil
            }
            return visualDistance(between: lhs, and: rhs)
        }
    }

    /// Calibrated visual similarity in `[0, 1]` for Apple Vision `VNFeaturePrintObservation` L2 distance.
    ///
    /// Calibrated to Vision Revision 2 (unit-normalized vectors in `[0, sqrt(2)]`):
    /// - `<= 0.40`: near-identical / same visual series (`1.0`)
    /// - `0.40 ... 0.86`: genuinely similar visual style, layout, or subject (`0.22 ... 1.0`)
    /// - `>= 0.95`: unrelated images (`0.0` — never padded or mislabeled as visually similar)
    public static func visualSimilarity(forDistance distance: Float) -> Double {
        guard distance.isFinite, distance >= 0 else { return 0 }
        let strictCutoff: Float = 0.95
        let strongFloor: Float = 0.40
        guard distance < strictCutoff else { return 0 }
        if distance <= strongFloor { return 1.0 }
        let normalized = Double(strictCutoff - distance) / Double(strictCutoff - strongFloor)
        return pow(normalized, 0.85)
    }

    /// Offline Apple Vision primary subject bounding box using Attention-Based Saliency
    /// (falling back to Objectness Saliency). Converts Vision's bottom-left origin into
    /// top-left normalized coordinates (`0...1`).
    public static func detectPrimarySubjectBox(in cgImage: CGImage) -> NormalizedCropRect? {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let attentionRequest = VNGenerateAttentionBasedSaliencyImageRequest()
        let objectnessRequest = VNGenerateObjectnessBasedSaliencyImageRequest()

        do {
            try handler.perform([attentionRequest, objectnessRequest])
        } catch {
            visionLogger.debug("Saliency detection failed: \(error.localizedDescription, privacy: .private)")
            return nil
        }

        let boxes: [CGRect] = [
            attentionRequest.results?.first?.salientObjects ?? [],
            objectnessRequest.results?.first?.salientObjects ?? []
        ]
            .first(where: { !$0.isEmpty })?
            .map(\.boundingBox) ?? []

        guard !boxes.isEmpty else { return nil }

        // Union salient regions (preferring the largest/most central salient box when multiple distant regions exist)
        let unionRect = boxes.reduce(boxes[0]) { $0.union($1) }
        guard unionRect.width > 0.04, unionRect.height > 0.04 else { return nil }

        // Vision coordinates: origin at bottom-left -> flip Y to top-left
        let top = max(0.0, min(1.0, 1.0 - Double(unionRect.maxY)))
        let bottom = max(top, min(1.0, 1.0 - Double(unionRect.minY)))
        let left = max(0.0, min(1.0, Double(unionRect.minX)))
        let right = max(left, min(1.0, Double(unionRect.maxX)))
        return NormalizedCropRect(boxTop: top, bottom: bottom, left: left, right: right).clamped()
    }

}
