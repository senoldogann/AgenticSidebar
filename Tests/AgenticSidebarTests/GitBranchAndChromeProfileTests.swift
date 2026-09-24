import Foundation
import XCTest

@testable import AgenticSidebar

/// `GitBranchListParser` ve `ChromeProfileResolver`: saf veri dönüşümleri,
/// süreç ve dosya yok.
final class GitBranchAndChromeProfileTests: XCTestCase {
    func testBranchesAreTrimmedAndBlankLinesDropped() {
        XCTAssertEqual(
            GitBranchListParser.branches(fromListOutput: "main\n  feature/x\n\n"),
            ["main", "feature/x"]
        )
        XCTAssertEqual(GitBranchListParser.branches(fromListOutput: ""), [])
    }

    func testCurrentBranchIsNilWhenDetached() {
        XCTAssertEqual(
            GitBranchListParser.currentBranch(fromShowCurrentOutput: "main\n"),
            "main"
        )
        XCTAssertNil(GitBranchListParser.currentBranch(fromShowCurrentOutput: "\n"))
    }

    func testDirtyCountIgnoresBlankLines() {
        XCTAssertEqual(
            GitBranchListParser.dirtyCount(fromStatusOutput: " M a.swift\nA  b.swift\n"),
            2
        )
        XCTAssertEqual(GitBranchListParser.dirtyCount(fromStatusOutput: ""), 0)
    }

    func testChromePrefersDefaultProfile() {
        let data = Data(
            """
            {"profile":{"info_cache":{"Profile 1":{"name":"Work"},"Default":{"name":"Personal"}}}}
            """.utf8
        )

        XCTAssertEqual(
            ChromeProfileResolver.personalProfile(localStateData: data),
            ChromeProfileResolver.Profile(directory: "Default", name: "Personal")
        )
    }

    func testChromeFallsBackToFirstProfileAlphabetically() {
        let data = Data(
            """
            {"profile":{"info_cache":{"Profile 2":{"name":"B"},"Profile 1":{"name":"A"}}}}
            """.utf8
        )

        XCTAssertEqual(
            ChromeProfileResolver.personalProfile(localStateData: data)?.directory,
            "Profile 1"
        )
    }

    func testChromeReturnsNilWithoutProfiles() {
        XCTAssertNil(ChromeProfileResolver.personalProfile(localStateData: Data("{}".utf8)))
        XCTAssertNil(ChromeProfileResolver.personalProfile(localStateData: Data("bozuk".utf8)))
    }
}
