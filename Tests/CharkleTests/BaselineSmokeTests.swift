import Testing
@testable import CharkleCore

@Suite("Charkle M0 Contract Smoke Tests")
struct BaselineSmokeTests {
    @Test("CIELAB hex conversion and perceptual deltaE")
    func labColorDistance() {
        let warm = LabColor.fromHex("#E07A5F")
        let similar = LabColor.fromHex("#D87259")
        let distant = LabColor.fromHex("#1D3557")
        #expect(warm.deltaE(to: similar) < 8.0)
        #expect(warm.deltaE(to: distant) > 40.0)
    }

    @Test("MediaKind detects all supported Charkle media families")
    func mediaKindDetection() {
        #expect(MediaKind.detect(fileExtension: "heic") == .image)
        #expect(MediaKind.detect(fileExtension: "gif") == .animatedImage)
        #expect(MediaKind.detect(fileExtension: "mp4") == .video)
        #expect(MediaKind.detect(fileExtension: "pdf") == .document)
        #expect(MediaKind.detect(fileExtension: "psd") == .designFile)
        #expect(MediaKind.detect(fileExtension: "svg") == .designFile)
        #expect(MediaKind.detect(fileExtension: "mp3") == .audio)
        #expect(MediaKind.detect(fileExtension: "webloc") == .webBookmark)
    }
}
