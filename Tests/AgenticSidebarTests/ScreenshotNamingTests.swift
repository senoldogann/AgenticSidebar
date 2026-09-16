import XCTest
@testable import AgenticSidebar

/// The auto-analysis feature reported itself as enabled on every system and only
/// worked on three of them, because it matched three literal prefixes.
final class ScreenshotNamingTests: XCTestCase {
    func testNamesMacOSUsesInEveryLanguageAreRecognised() {
        let names = [
            "Screenshot 2026-09-16 at 13.15.40.png",
            "Ekran Resmi 2026-09-16 13.15.40.png",
            "Bildschirmfoto 2026-09-16 um 13.15.40.png",
            "Captura de pantalla 2026-09-16 a las 13.15.40.png",
            "Capture d’écran 2026-09-16 à 13.15.40.png",
            "Schermafbeelding 2026-09-16 om 13.15.40.png",
            "Skärmavbild 2026-09-16 kl. 13.15.40.png",
            "Näyttökuva 2026-09-16 klo 13.15.40.png",
            "Снимок экрана 2026-09-16 в 13.15.40.png",
            "スクリーンショット 2026-09-16 13.15.40.png",
            "스크린샷 2026-09-16 13.15.40.png",
            "截屏 2026-09-16 13.15.40.png",
            "Zrzut ekranu 2026-09-16 o 13.15.40.png",
            "Képernyőkép 2026-09-16 13.15.40.png"
        ]

        for name in names {
            XCTAssertTrue(
                ScreenshotMonitorService.hasScreenshotName(name),
                "\(name) is what this system calls a screenshot"
            )
        }
    }

    func testTheExportExtensionsAreAccepted() {
        for name in [
            "Screenshot 2026-09-16 at 13.15.40.jpg",
            "Screenshot 2026-09-16 at 13.15.40.jpeg",
            "Screenshot 2026-09-16 at 13.15.40.heic"
        ] {
            XCTAssertTrue(ScreenshotMonitorService.hasScreenshotName(name), name)
        }
    }

    func testOrdinaryImagesAndFoldersAreNotMistakenForScreenshots() {
        for name in [
            "IMG_4821.png",
            "holiday.png",
            "Screenshot",
            "Screenshot-notes.md",
            "Screenshot 2026.png.bak",
            "chart.tiff.png"
        ] {
            XCTAssertFalse(ScreenshotMonitorService.hasScreenshotName(name), name)
        }
    }

    /// The metadata check is the fallback for a system macOS names differently
    /// from everything in the list; a file it cannot answer for reports `nil`,
    /// which is not the same as "no".
    func testMetadataAnswerIsOptional() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-not-indexed-\(UUID().uuidString).png")

        XCTAssertNil(ScreenshotMonitorService.isScreenCaptureByMetadata(missing))
    }

    /// The scan runs over the whole screenshots folder once a second, so a file
    /// that cannot be a screenshot must be rejected without asking Spotlight:
    /// every PDF, folder and text file on the Desktop used to cost a query.
    func testSpotlightIsOnlyAskedAboutImagesWhoseNameSaysNothing() {
        var queries: [String] = []
        let probe: (URL) -> Bool? = { url in
            queries.append(url.lastPathComponent)
            return nil
        }

        let folder = URL(fileURLWithPath: "/Users/tester/Desktop", isDirectory: true)
        let candidates = [
            "Screen Shot 2026-09-16 at 13.15.40.png",
            "holiday.png",
            "invoice.pdf",
            "notes.txt",
            "projects",
            "archive.zip",
            "Screenshot 2026.png.bak"
        ]

        let matched = candidates.filter { name in
            ScreenshotMonitorService.isScreenshotCandidate(
                fileURL: folder.appendingPathComponent(name),
                metadataProbe: probe
            )
        }

        XCTAssertEqual(
            matched,
            ["Screen Shot 2026-09-16 at 13.15.40.png"],
            "Only the file whose name matched is reported without help"
        )
        XCTAssertEqual(
            queries,
            ["holiday.png"],
            "The one image with a silent name is the only file Spotlight is asked about"
        )
    }

    /// An image whose name says nothing is still a screenshot when Spotlight says
    /// so — that fallback is what makes a differently-named system work.
    func testSpotlightsAnswerIsUsedWhenTheNameSaysNothing() {
        let url = URL(fileURLWithPath: "/Users/tester/Desktop/IMG_0001.png")

        XCTAssertTrue(
            ScreenshotMonitorService.isScreenshotCandidate(fileURL: url) { _ in true }
        )
        XCTAssertFalse(
            ScreenshotMonitorService.isScreenshotCandidate(fileURL: url) { _ in false }
        )
        XCTAssertFalse(
            ScreenshotMonitorService.isScreenshotCandidate(fileURL: url) { _ in nil },
            "A file Spotlight cannot answer for is left alone"
        )
    }
}
