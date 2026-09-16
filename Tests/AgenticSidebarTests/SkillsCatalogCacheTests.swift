import Foundation
import XCTest
@testable import AgenticSidebar

/// Discovery used to read and parse every `SKILL.md` on the main actor on every
/// appearance of the extensions screen. The cache is what makes that cheap, so
/// these tests assert the *non-read* property rather than timing it.
final class SkillsCatalogCacheTests: XCTestCase {
    func testAnUnchangedLibraryIsAnsweredWithoutReadingTheFilesAgain() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let skillFile = try writeSkill(named: "code-review", description: "First", in: root)
        let cache = SkillsCatalogCache(
            catalog: SkillsCatalog(
                roots: [SkillRoot(url: root, isManaged: true, label: "test")]
            )
        )

        let first = await cache.scan()
        XCTAssertEqual(first.map(\.description), ["First"])

        // Make the file impossible to read *without* changing its modification
        // date (permissions change `ctime`, which the fingerprint does not look
        // at). A scan that read the file again could not possibly succeed, so the
        // answer distinguishes "cached" from "re-read".
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: skillFile.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: skillFile.path
            )
        }

        let second = await cache.scan()

        XCTAssertEqual(
            second.map(\.description),
            ["First"],
            "An unchanged fingerprint must return the cached answer instead of re-parsing every file"
        )

        await cache.invalidate()
        let afterInvalidation = await cache.scan()
        XCTAssertNil(
            afterInvalidation.first?.description,
            "Sanity: with the cache dropped, the unreadable file is read again and reported as unreadable"
        )
    }

    func testANewSkillIsFoundBecauseTheFolderChanged() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try writeSkill(named: "code-review", description: "First", in: root)

        let cache = SkillsCatalogCache(
            catalog: SkillsCatalog(
                roots: [SkillRoot(url: root, isManaged: true, label: "test")]
            )
        )
        _ = await cache.scan()

        _ = try writeSkill(named: "release-notes", description: "Second", in: root)

        let rescanned = await cache.scan()
        XCTAssertEqual(rescanned.map(\.name), ["code-review", "release-notes"])
    }

    func testEditingAManifestIsPickedUp() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let skillFile = try writeSkill(named: "code-review", description: "First", in: root)

        let cache = SkillsCatalogCache(
            catalog: SkillsCatalog(
                roots: [SkillRoot(url: root, isManaged: true, label: "test")]
            )
        )
        _ = await cache.scan()

        try Data(manifest(name: "code-review", description: "Updated").utf8)
            .write(to: skillFile)
        // A second later, so the modification date really differs.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: skillFile.path
        )

        let rescanned = await cache.scan()
        XCTAssertEqual(rescanned.map(\.description), ["Updated"])
    }

    func testAMissingRootIsNotAnError() async {
        let cache = SkillsCatalogCache(
            catalog: SkillsCatalog(
                roots: [
                    SkillRoot(
                        url: FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString, isDirectory: true),
                        isManaged: false,
                        label: "missing"
                    )
                ]
            )
        )

        let skills = await cache.scan()
        XCTAssertTrue(skills.isEmpty)
    }

    @discardableResult
    private func writeSkill(
        named name: String,
        description: String,
        in root: URL
    ) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let skillFile = directory.appendingPathComponent("SKILL.md")
        try Data(manifest(name: name, description: description).utf8).write(to: skillFile)
        return skillFile
    }

    private func manifest(name: String, description: String) -> String {
        """
        ---
        name: \(name)
        description: \(description)
        ---

        Body
        """
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillsCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
