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
    /// Lower is more visually similar (0 = identical; typically < 0.85 means strong visual match).
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

}
