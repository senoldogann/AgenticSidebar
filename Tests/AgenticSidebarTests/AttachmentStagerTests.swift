import Foundation
import XCTest

@testable import AgenticSidebar

/// Tur başında ek sabitleme: dışarıdaki küçük dosya oturum klasörüne
/// kopyalanır, uygulama evindeki ve büyük dosya yerinde kalır, kayıp ve
/// tekrar düşer. Hepsi doğrulanmış yola dönüşür, ölü yol tura girmez.
final class AttachmentStagerTests: XCTestCase {
    func testOutsideSmallFileIsCopiedIntoSessionFolder() throws {
        let roots = try makeRoots()
        defer { remove(roots.top) }

        let source = roots.outside.appendingPathComponent("Ekran Resmi.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source)

        let staged = AttachmentStager.stage(
            paths: [source.path],
            sessionID: UUID(),
            date: Date(timeIntervalSince1970: 1_780_000_000),
            uniquifier: "a1b2c3",
            fileManager: FileManager.default,
            baseURL: roots.base
        )

        XCTAssertEqual(staged.count, 1)
        let stagedURL = URL(fileURLWithPath: try XCTUnwrap(staged.first))
        XCTAssertEqual(
            stagedURL.deletingLastPathComponent().lastPathComponent,
            AttachmentStager.directoryName
        )
        XCTAssertTrue(staged[0].hasSuffix(".png"))
        XCTAssertTrue(staged[0].contains("Ekran_Resmi"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged[0]))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: staged[0])),
            Data([0x89, 0x50, 0x4E, 0x47])
        )
    }

    func testManagedAndOversizedFilesStayInPlace() throws {
        let roots = try makeRoots()
        defer { remove(roots.top) }

        let managed = roots.base
            .appendingPathComponent("DroppedImages/drop-x/shot.png")
        try FileManager.default.createDirectory(
            at: managed.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x01]).write(to: managed)

        let big = roots.outside.appendingPathComponent("big.png")
        try Data(
            repeating: 0x02,
            count: AttachmentStager.maximumStagedBytes + 1
        ).write(to: big)

        let smallSession = UUID()
        let staged = AttachmentStager.stage(
            paths: [managed.path, big.path],
            sessionID: smallSession,
            date: Date(timeIntervalSince1970: 1_780_000_000),
            uniquifier: "d4e5f6",
            fileManager: FileManager.default,
            baseURL: roots.base
        )

        XCTAssertEqual(
            staged,
            [managed.path, big.path],
            "Uygulama evindeki dosya zaten kalıcıdır, büyük dosyanın kopyası diski şişirir"
        )
    }

    func testMissingAndDuplicatePathsAreDropped() throws {
        let roots = try makeRoots()
        defer { remove(roots.top) }

        let source = roots.outside.appendingPathComponent("note.md")
        try Data("# hi".utf8).write(to: source)

        let staged = AttachmentStager.stage(
            paths: [source.path, source.path, roots.outside.appendingPathComponent("gone.md").path],
            sessionID: UUID(),
            date: Date(timeIntervalSince1970: 1_780_000_000),
            uniquifier: "aa11bb",
            fileManager: FileManager.default,
            baseURL: roots.base
        )

        XCTAssertEqual(staged.count, 1)
    }

    func testExtensionlessFileStaysExtensionless() throws {
        let roots = try makeRoots()
        defer { remove(roots.top) }

        let source = roots.outside.appendingPathComponent("README")
        try Data("hi".utf8).write(to: source)

        let staged = AttachmentStager.stage(
            paths: [source.path],
            sessionID: UUID(),
            date: Date(timeIntervalSince1970: 1_780_000_000),
            uniquifier: "cc22dd",
            fileManager: FileManager.default,
            baseURL: roots.base
        )

        let name = try XCTUnwrap(staged.first.map { URL(fileURLWithPath: $0).lastPathComponent })
        XCTAssertTrue(name.hasPrefix("README") == false, "Oturum öneki başa gelir")
        XCTAssertFalse(name.contains("."), "Uzantısız dosya uzantı kazanmamalı")
    }

    func testNilBaseURLOnlyFiltersMissingFiles() throws {
        let roots = try makeRoots()
        defer { remove(roots.top) }

        let source = roots.outside.appendingPathComponent("keep.md")
        try Data("hi".utf8).write(to: source)

        let staged = AttachmentStager.stage(
            paths: [source.path, roots.outside.appendingPathComponent("gone.md").path],
            sessionID: UUID(),
            date: Date(timeIntervalSince1970: 1_780_000_000),
            uniquifier: "ee33ff",
            fileManager: FileManager.default,
            baseURL: nil
        )

        XCTAssertEqual(staged, [source.path])
    }

    private struct Roots {
        let top: URL
        let base: URL
        let outside: URL
    }

    private func makeRoots() throws -> Roots {
        let top = FileManager.default.temporaryDirectory
            .appendingPathComponent("stager-tests-\(UUID().uuidString)")
        let base = top.appendingPathComponent("AppHome")
        let outside = top.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        return Roots(top: top, base: base, outside: outside)
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
