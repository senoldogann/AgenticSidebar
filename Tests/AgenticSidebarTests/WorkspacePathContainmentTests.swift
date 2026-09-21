import Foundation
import XCTest

@testable import AgenticSidebar

/// Çalışma alanı dışına taşma denetiminin paylaşılan testi.
///
/// Çözümleyici ve çalıştırıcı aynı helper'ı kullanır; sembolik bağ kaçışı
/// (`workspace/evil` → `/etc`) iki tarafta da reddedilmelidir.
final class WorkspacePathContainmentTests: XCTestCase {
    func testPlainSubdirectoryIsContained() throws {
        let workspace = try makeWorkspace()
        XCTAssertFalse(WorkspacePathContainment.relativePath(".", escapesWorkspace: workspace))
        XCTAssertFalse(WorkspacePathContainment.relativePath("sub/dir", escapesWorkspace: workspace))
        XCTAssertFalse(WorkspacePathContainment.relativePath("  sub/dir  ", escapesWorkspace: workspace))
    }

    func testAbsoluteAndParentPathsEscape() throws {
        let workspace = try makeWorkspace()
        XCTAssertTrue(WorkspacePathContainment.relativePath("/etc", escapesWorkspace: workspace))
        XCTAssertTrue(WorkspacePathContainment.relativePath("../outside", escapesWorkspace: workspace))
        XCTAssertTrue(WorkspacePathContainment.relativePath("sub/../../outside", escapesWorkspace: workspace))
    }

    func testSymlinkInsideWorkspaceEscapingOutsideIsRejected() throws {
        let workspace = try makeWorkspace()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
            "containment-outside-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("evil"),
            withDestinationURL: outside
        )

        XCTAssertTrue(
            WorkspacePathContainment.relativePath("evil", escapesWorkspace: workspace),
            "Çalışma alanı içindeki dışa dönük bağ kaçış sayılmalı"
        )
        XCTAssertTrue(
            WorkspacePathContainment.relativePath("evil/nested", escapesWorkspace: workspace)
        )
    }

    func testSymlinkInsideWorkspaceStayingInsideIsAllowed() throws {
        let workspace = try makeWorkspace()
        let inner = workspace.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("link"),
            withDestinationURL: inner
        )

        XCTAssertFalse(
            WorkspacePathContainment.relativePath("link", escapesWorkspace: workspace),
            "İçeride kalan bağ reddedilmemeli"
        )
    }

    func testEmptyAndDotPathsAreContained() throws {
        // Boş ve nokta yollar çalışma dizininin kendisidir, kaçış değildir.
        let workspace = try makeWorkspace()
        XCTAssertFalse(WorkspacePathContainment.relativePath("", escapesWorkspace: workspace))
        XCTAssertFalse(WorkspacePathContainment.relativePath("   ", escapesWorkspace: workspace))
        XCTAssertFalse(WorkspacePathContainment.relativePath(".", escapesWorkspace: workspace))
    }

    func testDanglingSymlinkEscapingOutsideIsRejected() throws {
        // Sarkan bağ da kaçıştır: hedef diskte yok ama dışarıyı gösterir.
        let workspace = try makeWorkspace()
        let missingOutside = FileManager.default.temporaryDirectory.appendingPathComponent(
            "containment-missing-\(UUID().uuidString)/target", isDirectory: false
        )
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("dangling"),
            withDestinationURL: missingOutside
        )

        XCTAssertTrue(
            WorkspacePathContainment.relativePath("dangling", escapesWorkspace: workspace),
            "Dışarıyı gösteren sarkan bağ kaçış sayılmalı"
        )
        XCTAssertTrue(
            WorkspacePathContainment.relativePath("dangling/nested", escapesWorkspace: workspace)
        )
    }

    // MARK: - Helpers

    private func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "containment-ws-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
        return workspace
    }
}
