import Foundation

public enum DependencyGraphError: LocalizedError, Equatable, Sendable {
    case selfDependency(UUID)
    case cyclicDependency(prerequisiteID: UUID, dependentID: UUID)
    case duplicateDependency(TaskDependency)
    case crossProjectDependency(edgeProjectID: UUID, prerequisiteProjectID: UUID, dependentProjectID: UUID)
    case taskNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .selfDependency(let id):
            return "Task \(id) cannot depend on itself."
        case .cyclicDependency(let prereq, let dep):
            return "Adding dependency from \(prereq) to \(dep) introduces a cycle."
        case .duplicateDependency(let edge):
            return "Dependency already exists from \(edge.prerequisiteTaskID) to \(edge.dependentTaskID)."
        case .crossProjectDependency(let edgeProject, let prereqProject, let depProject):
            return "Cross-project dependency not permitted. Edge project: \(edgeProject), prereq: \(prereqProject), dep: \(depProject)."
        case .taskNotFound(let id):
            return "Task with ID \(id) not found."
        }
    }
}

public enum TaskDependencyGraph: Sendable {

    /// Adds a dependency edge to existing edges after validating against self-edges,
    /// missing tasks, cross-project tasks, duplicates, and cycles.
    ///
    /// - Parameters:
    ///   - edge: The new dependency edge to add.
    ///   - existing: Currently existing edges.
    ///   - tasks: The collection of all known tasks in the project.
    /// - Returns: A new array containing existing edges plus the new edge.
    public static func add(
        _ edge: TaskDependency,
        to existing: [TaskDependency],
        tasks: [CodingTask]
    ) throws -> [TaskDependency] {
        guard edge.prerequisiteTaskID != edge.dependentTaskID else {
            throw DependencyGraphError.selfDependency(edge.prerequisiteTaskID)
        }

        let taskMap = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let prereqTask = taskMap[edge.prerequisiteTaskID] else {
            throw DependencyGraphError.taskNotFound(edge.prerequisiteTaskID)
        }
        guard let depTask = taskMap[edge.dependentTaskID] else {
            throw DependencyGraphError.taskNotFound(edge.dependentTaskID)
        }

        guard prereqTask.projectID == edge.projectID && depTask.projectID == edge.projectID else {
            throw DependencyGraphError.crossProjectDependency(
                edgeProjectID: edge.projectID,
                prerequisiteProjectID: prereqTask.projectID,
                dependentProjectID: depTask.projectID
            )
        }

        let isDuplicate = existing.contains {
            $0.prerequisiteTaskID == edge.prerequisiteTaskID
                && $0.dependentTaskID == edge.dependentTaskID
        }
        if isDuplicate {
            throw DependencyGraphError.duplicateDependency(edge)
        }

        // Cycle detection using iterative DFS:
        // Adding edge U -> V creates a cycle if and only if there is already a directed path from V to U.
        var adj: [UUID: [UUID]] = [:]
        for e in existing {
            adj[e.prerequisiteTaskID, default: []].append(e.dependentTaskID)
        }

        var stack: [UUID] = [edge.dependentTaskID]
        var visited: Set<UUID> = []

        while let current = stack.popLast() {
            if current == edge.prerequisiteTaskID {
                throw DependencyGraphError.cyclicDependency(
                    prerequisiteID: edge.prerequisiteTaskID,
                    dependentID: edge.dependentTaskID
                )
            }
            if visited.insert(current).inserted {
                for neighbor in adj[current, default: []] {
                    if !visited.contains(neighbor) {
                        stack.append(neighbor)
                    }
                }
            }
        }

        var updated = existing
        updated.append(edge)
        return updated
    }

    /// Computes the IDs of tasks that are ready to be scheduled.
    ///
    /// A task is ready if:
    /// 1. Its status is `.ready`.
    /// 2. All of its prerequisite tasks exist in `tasks`, belong to the same project, and have status `.done`.
    ///
    /// Results are returned in deterministic order:
    /// - Priority descending (higher priority first)
    /// - Creation time ascending (earlier first)
    /// - Task ID UUID string ascending
    public static func readyIDs(tasks: [CodingTask], dependencies: [TaskDependency]) -> [UUID] {
        let taskMap = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var prereqsForDependent: [UUID: [UUID]] = [:]
        for dep in dependencies {
            prereqsForDependent[dep.dependentTaskID, default: []].append(dep.prerequisiteTaskID)
        }

        let readyTasks = tasks.filter { task in
            guard task.status == .ready else { return false }

            let prereqs = prereqsForDependent[task.id, default: []]
            for prereqID in prereqs {
                guard let prereqTask = taskMap[prereqID] else {
                    return false
                }
                guard prereqTask.projectID == task.projectID else {
                    return false
                }
                guard prereqTask.status == .done else {
                    return false
                }
            }
            return true
        }

        let sortedTasks = readyTasks.sorted { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority > rhs.priority
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        return sortedTasks.map(\.id)
    }
}
