import Foundation

/// One task the agent is tracking while it works.
///
/// The list is the agent's own, kept by OpenCode for the session and read back
/// from it (`GET /session/:id/todo`): the app never edits it, it only shows what
/// the agent wrote so a long turn is legible while it runs instead of only after
/// it ends.
struct AgentTodo: Identifiable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
        case cancelled

        /// Whether the agent is done with it, one way or another.
        var isFinished: Bool {
            self == .completed || self == .cancelled
        }
    }

    let id: String
    let content: String
    let status: Status
    /// The agent's own ranking, shown only as a hint: `high`, `medium`, `low`.
    let priority: String?

    init(
        id: String,
        content: String,
        status: Status = .pending,
        priority: String? = nil
    ) {
        self.id = id
        self.content = content
        self.status = status
        self.priority = priority
    }
}

/// Tolerant decoding.
///
/// The list belongs to the backend and its shape is not the app's to freeze: an
/// unknown status must not drop a task the agent is tracking, and a missing id
/// must not either — a checklist that quietly loses rows is worse than one that
/// shows a task as still pending.
extension AgentTodo: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id
        case content
        case status
        case priority
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode(String.self, forKey: .content)
        id = (try? container.decode(String.self, forKey: .id)) ?? content
        status = (try? container.decode(Status.self, forKey: .status)) ?? .pending
        priority = try? container.decode(String.self, forKey: .priority)
    }
}

/// What the checklist card says about a list.
enum AgentTodoPresentation {
    /// `3/7`, counting only the tasks the agent finished — a cancelled task is
    /// not progress.
    static func progress(_ todos: [AgentTodo]) -> String {
        "\(todos.filter { $0.status == .completed }.count)/\(todos.count)"
    }

    /// The task to name under the header: the one being worked on, else the next
    /// one waiting. This is what tells the user *what* the agent is doing now.
    static func currentTask(_ todos: [AgentTodo]) -> AgentTodo? {
        todos.first { $0.status == .inProgress }
            ?? todos.first { $0.status == .pending }
    }

    static func summary(_ todos: [AgentTodo]) -> String {
        let progress = progress(todos)
        guard let current = currentTask(todos) else {
            return "To-dos \(progress)"
        }

        return "To-dos \(progress) · \(current.content)"
    }
}

/// Kartın nerede duracağı, böylece her görünüm kendisi karar vermez.
enum AgentTodoPlacement {
    /// Kontrol listesi yalnız bestecinin üstündeki panelde durur: tur
    /// başlayınca boş başlar, ajan yazdıkça dolar, biten turun eski
    /// maddeleri yeni turda görünmez.
    static func shouldShow(todos: [AgentTodo], isTurnRunning: Bool) -> Bool {
        guard !todos.isEmpty else {
            return false
        }

        return isTurnRunning || todos.contains { !$0.status.isFinished }
    }
}
