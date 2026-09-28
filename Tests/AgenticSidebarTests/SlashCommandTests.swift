import Foundation
import XCTest

@testable import AgenticSidebar

/// Yerleşik eğik-çizgi komutları: listeleme, süzme ve `/goal` önek ayrıştırma.
/// Bestecideki `/` paneli bu tipten beslenir; liste boşsa kullanıcı komutları
/// hiç keşfedemez.
final class SlashCommandTests: XCTestCase {
    func testAllListsGoalBeforeBtw() {
        XCTAssertEqual(SlashCommand.all.map(\.name), ["goal", "btw", "model"])
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
        XCTAssertEqual(SlashCommand.model.prefix, "/model ")
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

    func testParseModelQueryExtractsQuery() {
        XCTAssertEqual(SlashCommand.parseModelQuery(from: "/model gpt-5"), "gpt-5")
        XCTAssertEqual(SlashCommand.parseModelQuery(from: "/MODEL Claude"), "Claude")
    }

    func testParseModelQueryRejectsBareAndGlued() {
        XCTAssertNil(SlashCommand.parseModelQuery(from: "/model"))
        XCTAssertNil(SlashCommand.parseModelQuery(from: "/model "))
        XCTAssertNil(SlashCommand.parseModelQuery(from: "/modelx gpt"))
    }

    func testMatchingModelsFiltersByDisplayNameOrID() {
        let models = [
            ProviderModelCapability(id: ProviderModelID("openai/gpt-5"), displayName: "GPT-5", variants: []),
            ProviderModelCapability(id: ProviderModelID("anthropic/claude-sonnet-4"), displayName: "Claude Sonnet 4", variants: []),
        ]
        XCTAssertEqual(SlashCommand.matchingModels(query: "", in: models), models)
        XCTAssertEqual(SlashCommand.matchingModels(query: "gpt", in: models).map(\.displayName), ["GPT-5"])
        XCTAssertEqual(SlashCommand.matchingModels(query: "CLAUDE", in: models).map(\.displayName), ["Claude Sonnet 4"])
        XCTAssertTrue(SlashCommand.matchingModels(query: "zzz", in: models).isEmpty)
    }
}
