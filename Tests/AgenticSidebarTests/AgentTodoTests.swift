import Foundation
import XCTest

@testable import AgenticSidebar

final class AgentTodoDecodingTests: XCTestCase {
    func testTheBackendsOwnListDecodes() throws {
        let json = """
            [
              {"id": "1", "content": "Read the parser", "status": "completed", "priority": "high"},
              {"id": "2", "content": "Add the card", "status": "in_progress", "priority": "medium"},
              {"id": "3", "content": "Run the tests", "status": "pending"}
            ]
            """

        let todos = try JSONDecoder().decode([AgentTodo].self, from: Data(json.utf8))

        XCTAssertEqual(todos.map(\.content), ["Read the parser", "Add the card", "Run the tests"])
        XCTAssertEqual(todos.map(\.status), [.completed, .inProgress, .pending])
        XCTAssertEqual(todos[0].priority, "high")
        XCTAssertNil(todos[2].priority)
    }

    /// The list is the backend's, so a value this app has not seen must not drop a
    /// task the agent is tracking: a checklist that silently loses rows is worse
    /// than one that shows an unknown task as still pending.
    func testAnUnknownStatusOrMissingIdKeepsTheTask() throws {
        let json = """
            [
              {"content": "No id here", "status": "waiting-for-review"},
              {"id": "9", "content": "Known status", "status": "cancelled"}
            ]
            """

        let todos = try JSONDecoder().decode([AgentTodo].self, from: Data(json.utf8))

        XCTAssertEqual(todos.count, 2)
        XCTAssertEqual(todos[0].id, "No id here", "A missing id falls back to the text")
        XCTAssertEqual(todos[0].status, .pending)
        XCTAssertEqual(todos[1].status, .cancelled)
        XCTAssertTrue(todos[1].status.isFinished)
        XCTAssertFalse(todos[0].status.isFinished)
    }

    func testATaskWithoutTextIsNotATask() {
        let json = """
            [{"id": "1", "status": "pending"}]
            """

        XCTAssertThrowsError(
            try JSONDecoder().decode([AgentTodo].self, from: Data(json.utf8))
        )
    }
}

final class AgentTodoPresentationTests: XCTestCase {
    private func todo(
        _ content: String,
        _ status: AgentTodo.Status
    ) -> AgentTodo {
        AgentTodo(id: content, content: content, status: status)
    }

    func testProgressCountsOnlyWhatIsFinished() {
        let todos = [
            todo("a", .completed),
            todo("b", .cancelled),
            todo("c", .inProgress),
            todo("d", .pending),
        ]

        XCTAssertEqual(
            AgentTodoPresentation.progress(todos),
            "1/4",
            "A cancelled task is not progress"
        )
        XCTAssertEqual(AgentTodoPresentation.progress([]), "0/0")
    }

    func testTheCurrentTaskIsTheOneBeingWorkedOnThenTheNextOne() {
        let running = [todo("a", .completed), todo("b", .inProgress), todo("c", .pending)]
        XCTAssertEqual(AgentTodoPresentation.currentTask(running)?.content, "b")

        let waiting = [todo("a", .completed), todo("b", .pending)]
        XCTAssertEqual(AgentTodoPresentation.currentTask(waiting)?.content, "b")

        XCTAssertNil(AgentTodoPresentation.currentTask([todo("a", .completed)]))
        XCTAssertEqual(AgentTodoPresentation.summary(running), "To-dos 1/3 · b")
        XCTAssertEqual(
            AgentTodoPresentation.summary([todo("a", .completed)]),
            "To-dos 1/1"
        )
    }
}

final class AgentTodoPlacementTests: XCTestCase {
    private let unfinished = [AgentTodo(id: "1", content: "a", status: .pending)]
    private let finished = [AgentTodo(id: "1", content: "a", status: .completed)]

    func testThereIsNothingToShowWithoutATaskList() {
        XCTAssertFalse(AgentTodoPlacement.shouldShow(todos: [], isTurnRunning: true))
        XCTAssertFalse(AgentTodoPlacement.shouldShow(todos: [], isTurnRunning: false))
    }

    func testTheChecklistStaysWhileTheTurnRunsEvenIfEveryRowIsDone() {
        XCTAssertTrue(
            AgentTodoPlacement.shouldShow(todos: finished, isTurnRunning: true),
            "The agent may still be writing the summary of what it finished"
        )
    }

    func testAFinishedTurnStopsShowingItsChecklist() {
        XCTAssertFalse(AgentTodoPlacement.shouldShow(todos: finished, isTurnRunning: false))
        XCTAssertTrue(
            AgentTodoPlacement.shouldShow(todos: unfinished, isTurnRunning: false),
            "Work the agent stopped on is still work it has not done"
        )
    }
}

final class AgentTodoToolKindTests: XCTestCase {
    func testATaskListToolIsRecognisedAsOne() {
        XCTAssertEqual(
            ProviderActivityDescriptor.sanitizedTool(
                id: ProviderActivityID("p1"),
                toolName: "todowrite"
            ).kind,
            .todo
        )
        XCTAssertEqual(
            ProviderActivityDescriptor.sanitizedTool(
                id: ProviderActivityID("p2"),
                toolName: "todo_write"
            ).kind,
            .todo
        )
    }

    /// Checked before the file-change groups on purpose: a task list filed as a
    /// write would be the wrong icon *and* would miss the checklist refresh.
    func testAnOrdinaryWriteIsStillAWrite() {
        XCTAssertEqual(
            ProviderActivityDescriptor.sanitizedTool(
                id: ProviderActivityID("p1"),
                toolName: "write"
            ).kind,
            .update
        )
        XCTAssertEqual(
            ProviderActivityDescriptor.sanitizedTool(
                id: ProviderActivityID("p2"),
                toolName: "edit"
            ).kind,
            .edit
        )
    }
}
