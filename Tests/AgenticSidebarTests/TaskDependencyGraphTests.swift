import Foundation
import XCTest

@testable import AgenticSidebar

final class TaskDependencyGraphTests: XCTestCase {

    func testSelfEdgeThrowsError() throws {
        let projectID = UUID()
        let task = CodingTask(
            id: UUID(),
            projectID: projectID,
            title: "Task A",
            objective: "Do A",
            status: .backlog
        )

        let edge = TaskDependency(
            projectID: projectID,
            prerequisiteTaskID: task.id,
            dependentTaskID: task.id
        )

        XCTAssertThrowsError(
            try TaskDependencyGraph.add(edge, to: [], tasks: [task])
        ) { error in
            guard let graphError = error as? DependencyGraphError else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
            XCTAssertEqual(graphError, .selfDependency(task.id))
        }
    }

    func testDirectCycleThrowsError() throws {
        let projectID = UUID()
        let taskA = CodingTask(id: UUID(), projectID: projectID, title: "A", objective: "Do A")
        let taskB = CodingTask(id: UUID(), projectID: projectID, title: "B", objective: "Do B")

        let edgeAB = TaskDependency(projectID: projectID, prerequisiteTaskID: taskA.id, dependentTaskID: taskB.id)
        let existing = try TaskDependencyGraph.add(edgeAB, to: [], tasks: [taskA, taskB])

        let edgeBA = TaskDependency(projectID: projectID, prerequisiteTaskID: taskB.id, dependentTaskID: taskA.id)
        XCTAssertThrowsError(
            try TaskDependencyGraph.add(edgeBA, to: existing, tasks: [taskA, taskB])
        ) { error in
            guard let graphError = error as? DependencyGraphError else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
            switch graphError {
            case .cyclicDependency:
                break
            default:
                XCTFail("Expected cyclicDependency, got \(graphError)")
            }
        }
    }

    func testIndirectCycleThrowsError() throws {
        let projectID = UUID()
        let taskA = CodingTask(id: UUID(), projectID: projectID, title: "A", objective: "Do A")
        let taskB = CodingTask(id: UUID(), projectID: projectID, title: "B", objective: "Do B")
        let taskC = CodingTask(id: UUID(), projectID: projectID, title: "C", objective: "Do C")

        let edgeAB = TaskDependency(projectID: projectID, prerequisiteTaskID: taskA.id, dependentTaskID: taskB.id)
        let edgeBC = TaskDependency(projectID: projectID, prerequisiteTaskID: taskB.id, dependentTaskID: taskC.id)

        var edges = try TaskDependencyGraph.add(edgeAB, to: [], tasks: [taskA, taskB, taskC])
        edges = try TaskDependencyGraph.add(edgeBC, to: edges, tasks: [taskA, taskB, taskC])

        let edgeCA = TaskDependency(projectID: projectID, prerequisiteTaskID: taskC.id, dependentTaskID: taskA.id)
        XCTAssertThrowsError(
            try TaskDependencyGraph.add(edgeCA, to: edges, tasks: [taskA, taskB, taskC])
        ) { error in
            guard let graphError = error as? DependencyGraphError else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
            switch graphError {
            case .cyclicDependency:
                break
            default:
                XCTFail("Expected cyclicDependency, got \(graphError)")
            }
        }
    }

    func testDuplicateEdgeThrowsError() throws {
        let projectID = UUID()
        let taskA = CodingTask(id: UUID(), projectID: projectID, title: "A", objective: "Do A")
        let taskB = CodingTask(id: UUID(), projectID: projectID, title: "B", objective: "Do B")

        let edge = TaskDependency(projectID: projectID, prerequisiteTaskID: taskA.id, dependentTaskID: taskB.id)
        let edges = try TaskDependencyGraph.add(edge, to: [], tasks: [taskA, taskB])

        XCTAssertThrowsError(
            try TaskDependencyGraph.add(edge, to: edges, tasks: [taskA, taskB])
        ) { error in
            guard let graphError = error as? DependencyGraphError else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
            XCTAssertEqual(graphError, .duplicateDependency(edge))
        }
    }

    func testCrossProjectEdgeThrowsError() throws {
        let projectID1 = UUID()
        let projectID2 = UUID()
        let taskA = CodingTask(id: UUID(), projectID: projectID1, title: "A", objective: "Do A")
        let taskB = CodingTask(id: UUID(), projectID: projectID2, title: "B", objective: "Do B")

        let edge = TaskDependency(projectID: projectID1, prerequisiteTaskID: taskA.id, dependentTaskID: taskB.id)

        XCTAssertThrowsError(
            try TaskDependencyGraph.add(edge, to: [], tasks: [taskA, taskB])
        ) { error in
            guard let graphError = error as? DependencyGraphError else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
            switch graphError {
            case .crossProjectDependency:
                break
            default:
                XCTFail("Expected crossProjectDependency, got \(graphError)")
            }
        }
    }

    func testMissingPredecessorThrowsError() throws {
        let projectID = UUID()
        let missingTaskID = UUID()
        let taskB = CodingTask(id: UUID(), projectID: projectID, title: "B", objective: "Do B")

        let edge = TaskDependency(projectID: projectID, prerequisiteTaskID: missingTaskID, dependentTaskID: taskB.id)

        XCTAssertThrowsError(
            try TaskDependencyGraph.add(edge, to: [], tasks: [taskB])
        ) { error in
            guard let graphError = error as? DependencyGraphError else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
            XCTAssertEqual(graphError, .taskNotFound(missingTaskID))
        }
    }

    func testDependencyInReviewDoesNotMakeDependentReady() throws {
        let projectID = UUID()
        let taskA = CodingTask(
            id: UUID(),
            projectID: projectID,
            title: "A",
            objective: "Do A",
            status: .review
        )
        let taskB = CodingTask(
            id: UUID(),
            projectID: projectID,
            title: "B",
            objective: "Do B",
            status: .ready
        )

        let edgeAB = TaskDependency(projectID: projectID, prerequisiteTaskID: taskA.id, dependentTaskID: taskB.id)
        let ready = TaskDependencyGraph.readyIDs(tasks: [taskA, taskB], dependencies: [edgeAB])

        // taskB depends on taskA which is in .review (not .done), so taskB cannot be ready.
        // taskA is in .review (not .ready), so neither is ready.
        XCTAssertFalse(ready.contains(taskB.id))
        XCTAssertFalse(ready.contains(taskA.id))
    }

    func testReadyIDsDeterministicOrder() throws {
        let projectID = UUID()
        let baseDate = Date()
        let taskA = CodingTask(
            id: UUID(),
            projectID: projectID,
            title: "A",
            objective: "Lower priority",
            priority: 1,
            status: .ready,
            createdAt: baseDate.addingTimeInterval(10)
        )
        let taskB = CodingTask(
            id: UUID(),
            projectID: projectID,
            title: "B",
            objective: "Higher priority",
            priority: 5,
            status: .ready,
            createdAt: baseDate.addingTimeInterval(20)
        )
        let taskC = CodingTask(
            id: UUID(),
            projectID: projectID,
            title: "C",
            objective: "Same high priority, earlier creation",
            priority: 5,
            status: .ready,
            createdAt: baseDate
        )

        let ready = TaskDependencyGraph.readyIDs(tasks: [taskA, taskB, taskC], dependencies: [])
        // Priority descending: 5 before 1.
        // Between B and C (both priority 5): C is earlier (baseDate vs baseDate+20).
        XCTAssertEqual(ready, [taskC.id, taskB.id, taskA.id])
    }

    func testDeepAcyclicGraphTerminatesWithoutOverflow() throws {
        let projectID = UUID()
        let count = 1000
        var tasks: [CodingTask] = []
        var edges: [TaskDependency] = []

        for i in 0..<count {
            let task = CodingTask(
                id: UUID(),
                projectID: projectID,
                title: "Task \(i)",
                objective: "Step \(i)",
                status: i == 0 ? .ready : .backlog
            )
            tasks.append(task)
            if i > 0 {
                edges.append(
                    TaskDependency(
                        projectID: projectID,
                        prerequisiteTaskID: tasks[i - 1].id,
                        dependentTaskID: task.id
                    )
                )
            }
        }

        let ready = TaskDependencyGraph.readyIDs(tasks: tasks, dependencies: edges)
        XCTAssertEqual(ready, [tasks[0].id])
    }
}
