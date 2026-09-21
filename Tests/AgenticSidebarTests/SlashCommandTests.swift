import Foundation
import XCTest

@testable import AgenticSidebar

/// Yerleşik eğik-çizgi komutları: listeleme, süzme ve `/goal` önek ayrıştırma.
/// Bestecideki `/` paneli bu tipten beslenir; liste boşsa kullanıcı komutları
/// hiç keşfedemez.
final class SlashCommandTests: XCTestCase {
    func testAllListsGoalBeforeBtw() {
        XCTAssertEqual(SlashCommand.all.map(\.name), ["goal", "btw"])
    }

    func testMatchingEmptyQueryReturnsAll() {
        XCTAssertEqual(SlashCommand.matching(query: ""), SlashCommand.all)
    }

    func testMatchingFiltersCaseInsensitively() {
        XCTAssertEqual(SlashCommand.matching(query: "bt"), [.btw])
        XCTAssertEqual(SlashCommand.matching(query: "GO"), [.goal])
    }

    func testMatchingWithoutHitReturnsEmpty() {
        XCTAssertTrue(SlashCommand.matching(query: "zzz").isEmpty)
    }

    func testPrefixEndsWithSpace() {
        XCTAssertEqual(SlashCommand.btw.prefix, "/btw ")
        XCTAssertEqual(SlashCommand.goal.prefix, "/goal ")
    }

    func testParseGoalExtractsObjective() {
        XCTAssertEqual(SlashCommand.parseGoal(from: "/goal fix the crash"), "fix the crash")
    }

    func testParseGoalRejectsBareCommand() {
        XCTAssertNil(SlashCommand.parseGoal(from: "/goal"))
        XCTAssertNil(SlashCommand.parseGoal(from: "/goal "))
        XCTAssertNil(SlashCommand.parseGoal(from: "/goal   "))
    }

    func testParseGoalRejectsGluedName() {
        XCTAssertNil(SlashCommand.parseGoal(from: "/goalx do it"))
    }

    func testParseGoalIsCaseInsensitive() {
        XCTAssertEqual(SlashCommand.parseGoal(from: "/GOAL Do it"), "Do it")
    }
}
