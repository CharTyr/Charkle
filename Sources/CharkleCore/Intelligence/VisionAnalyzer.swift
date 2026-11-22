import CoreGraphics
import Foundation
import Vision
import os

private let visionLogger = Logger(subsystem: "com.charkle.core", category: "Vision")

public nonisolated enum VisionAnalyzer {
    public static func recognizeTextSync(in cgImage: CGImage) -> String {
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

    /// Generate serialized `VNFeaturePrintObservation` data for offline visual similarity & Search-by-Image.
    public static func generateFeaturePrint(for cgImage: CGImage) -> Data? {
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

    /// Compute perceptual visual distance between two serialized `VNFeaturePrintObservation` payloads.
    /// Lower is more visually similar (0 = identical; on Revision 2 unrelated images sit around 0.98–1.25).
    public static func visualDistance(between lhsData: Data, and rhsData: Data) -> Float? {
        guard let lhs = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: lhsData),
              let rhs = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: rhsData) else {
            return nil
        }
        var distance: Float = 0
        do {
            try lhs.computeDistance(&distance, to: rhs)
            return distance
        } catch {
            return nil
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

}
