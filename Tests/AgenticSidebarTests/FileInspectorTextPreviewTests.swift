import XCTest
@testable import AgenticSidebar

/// Dosya denetçisinin metin önizlemesi.
///
/// Asıl söz şu: dosya ne kadar büyük olursa olsun okunan bayt sayısı sınırlıdır
/// ve okuma gövdenin çizildiği iş parçacığında yapılmaz — `readTextPrefix`
/// `nonisolated` olduğu için çağıran onu ana iş parçacığının dışına taşıyabilir.
final class FileInspectorTextPreviewTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-inspector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testHugeFileIsReadOnlyUpToTheBoundedPrefix() throws {
        let url = directory.appendingPathComponent("huge.log")
        let line = "0123456789 the quick brown fox jumps over the lazy dog\n"
        let repetitions = 60_000 // ~3 MB, sınırın üstünde
        let content = String(repeating: line, count: repetitions)
        try content.write(to: url, atomically: true, encoding: .utf8)

        let text = try XCTUnwrap(FileInspectorPanelView.readTextPrefix(of: url))

        XCTAssertTrue(
            text.hasSuffix("… [truncated]"),
            "sınırın üstündeki dosya kırpılır"
        )
        XCTAssertLessThan(
            text.count,
            content.count / 3,
            "dosyanın tamamı okunmaz"
        )
    }

    func testSmallTextFileIsReturnedWhole() throws {
        let url = directory.appendingPathComponent("notes.md")
        try "# Başlık\n\nİçerik\n".write(to: url, atomically: true, encoding: .utf8)

        let text = try XCTUnwrap(FileInspectorPanelView.readTextPrefix(of: url))

        XCTAssertEqual(text, "# Başlık\n\nİçerik\n")
    }

    func testBinaryFileIsReportedAsUnreadable() throws {
        let url = directory.appendingPathComponent("blob.bin")
        try Data([0xFF, 0xFE, 0x00, 0x01, 0x80]).write(to: url)

        XCTAssertNil(FileInspectorPanelView.readTextPrefix(of: url))
    }

    func testMissingFileIsReportedAsUnreadable() {
        let url = directory.appendingPathComponent("does-not-exist.txt")

        XCTAssertNil(FileInspectorPanelView.readTextPrefix(of: url))
    }
}
