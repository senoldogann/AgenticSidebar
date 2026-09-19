import Foundation
import XCTest

@testable import AgenticSidebar

final class OpenCodeQuestionEventRouterTests: XCTestCase {
    func testOwnQuestionPreservesBackendIDChoicesAndQuestionOrder() throws {
        var router = OpenCodeQuestionEventRouter(sessionID: "ses_owner")
        let events = router.consume(
            line:
                #"data: {"type":"question.asked","properties":{"id":"que_1","sessionID":"ses_owner","questions":[{"question":"Database?","header":"Database","options":[{"label":"SQLite","description":"Local"},{"label":"Postgres","description":"Server"}],"multiple":false,"custom":true},{"question":"Extras?","header":"Extras","options":[{"label":"Redis","description":"Cache"}],"multiple":true,"custom":false}],"tool":{"messageID":"msg_1","callID":"call_1"}}}"#
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.requestID, "que_1")
        XCTAssertEqual(events.first?.remoteSessionID, "ses_owner")
        XCTAssertEqual(events.first?.questions.map(\.prompt), ["Database?", "Extras?"])
        XCTAssertEqual(events.first?.questions.first?.options.map(\.label), ["SQLite", "Postgres"])
        XCTAssertEqual(events.first?.questions.first?.options.first?.description, "Local")
        XCTAssertEqual(events.first?.questions[1].isMultiSelect, true)
        XCTAssertEqual(events.first?.questions[1].allowCustomAnswer, false)
    }

    func testGlobalEventDoesNotAttributeForeignQuestionButReleasesVerifiedChild() throws {
        var router = OpenCodeQuestionEventRouter(sessionID: "ses_owner")
        let foreign =
            #"data: {"type":"question.asked","properties":{"id":"que_foreign","sessionID":"ses_foreign","questions":[{"question":"Private?","header":"Private","options":[]}]}}"#
        let child =
            #"data: {"type":"question.asked","properties":{"id":"que_child","sessionID":"ses_child","questions":[{"question":"Choice?","header":"Choice","options":[]}]}}"#
        XCTAssertTrue(router.consume(line: foreign).isEmpty)
        XCTAssertTrue(router.consume(line: child).isEmpty)
        let parentTask =
            #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_owner","part":{"id":"prt_task","type":"tool","tool":"task","state":{"status":"running","input":{},"metadata":{"sessionId":"ses_child"}}}}}"#
        let released = router.consume(line: parentTask)
        XCTAssertEqual(released.map(\.requestID), ["que_child"])
        XCTAssertTrue(router.consume(line: child).isEmpty, "A repeated SSE event must not display the same question twice")
    }
}

/// Runtime lifecycle (T3): the router and the normalizer must agree on what
/// counts as a subagent delegation tool, or delegated questions never surface.
final class OpenCodeSubagentToolPredicateTests: XCTestCase {
    func testSharedPredicateRecognisesDelegationTools() {
        for tool in [
            "task", "subagent", "sub_agent",
            "run_subagent", "call_subagent", "invoke_subagent", "browser_subagent",
            "subagent_explore", "delegate_task", "delegate_agent", "delegate", "agent",
        ] {
            XCTAssertTrue(
                ProviderActivityDescriptor.isSubagentTool(tool),
                "\(tool) delegates to a child session"
            )
        }
        XCTAssertTrue(ProviderActivityDescriptor.isSubagentTool("TASK"))
        for tool in ["read", "bash", "question", "todowrite", "mcp__github__get_user"] {
            XCTAssertFalse(
                ProviderActivityDescriptor.isSubagentTool(tool),
                "\(tool) runs in this session"
            )
        }
    }

    func testRouterLearnsChildOwnershipFromDelegateTaskTool() {
        var router = OpenCodeQuestionEventRouter(sessionID: "ses_owner")
        let child =
            #"data: {"type":"question.asked","properties":{"id":"que_child","sessionID":"ses_child","questions":[{"question":"Choice?","header":"Choice","options":[]}]}}"#
        XCTAssertTrue(router.consume(line: child).isEmpty)
        let parentPart =
            #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_owner","part":{"id":"prt_delegate","type":"tool","tool":"delegate_task","state":{"status":"running","input":{},"metadata":{"sessionId":"ses_child"}}}}}"#
        XCTAssertEqual(
            router.consume(line: parentPart).map(\.requestID),
            ["que_child"],
            "A delegated question must surface no matter which delegation tool name the backend used"
        )
    }
}
