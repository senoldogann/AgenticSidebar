import Foundation
import UniformTypeIdentifiers
import XCTest

@testable import AgenticSidebar

/// Ekran görüntüsü önizlemesinden sürüklenen ham veri dosya eki olur.
final class DroppedImageAttachmentTests: XCTestCase {
    func testFileExtensionFollowsTheOfferedType() {
        XCTAssertEqual(
            DroppedImageAttachment.fileExtension(forTypeIdentifier: UTType.png.identifier),
            "png"
        )
        XCTAssertEqual(
            DroppedImageAttachment.fileExtension(forTypeIdentifier: UTType.tiff.identifier),
            "tiff"
        )
        XCTAssertEqual(
            DroppedImageAttachment.fileExtension(forTypeIdentifier: UTType.jpeg.identifier),
            "jpg"
        )
        XCTAssertEqual(
            DroppedImageAttachment.fileExtension(forTypeIdentifier: "com.example.unknown"),
            "png"
        )
    }

    func testSaveWritesTheBytesVerbatim() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // En küçük geçerli PNG: içerik aynen durmalı, yeniden kodlanmamalı.
        let bytes = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        ])
        let url = try DroppedImageAttachment.save(
            bytes,
            suggestedName: "Screenshot",
            typeIdentifier: UTType.png.identifier,
            uniquifier: "img001",
            fileManager: .default,
            baseURL: base
        )

        XCTAssertEqual(url.pathExtension, "png")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Screenshot-"))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testSaveWithoutAStorageLocationOrDataThrows() {
        XCTAssertThrowsError(
            try DroppedImageAttachment.save(Data([0x01]), fileManager: .default, baseURL: nil)
        ) { error in
            XCTAssertEqual(error as? DroppedImageAttachmentError, .noStorageLocation)
        }

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertThrowsError(
            try DroppedImageAttachment.save(Data(), fileManager: .default, baseURL: base)
        ) { error in
            XCTAssertEqual(error as? DroppedImageAttachmentError, .emptyData)
        }
    }
}
