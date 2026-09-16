import SwiftUI

/// The agent's own task list, shown while it works.
///
/// It is the list the backend keeps for the session (`GET /session/:id/todo`),
/// rendered as a card so a long turn reads as progress rather than as an
/// unexplained wait: the header counts what is done, the rows show what is next,
/// and the card collapses so it never competes with the answer for the screen.
struct AgentTodoChecklistView: View {
    let todos: [AgentTodo]
    let preset: AppThemePreset
    let isDark: Bool

    @State private var isExpanded = true

    private var accent: Color {
        preset.accentGradient.first ?? .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(todos.enumerated()), id: \.element.id) { _, todo in
                        row(todo)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(
            (isDark ? preset.surfaceDark : preset.surfaceLight).opacity(isDark ? 0.55 : 0.75),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    (isDark ? preset.borderSubtleDark : preset.borderSubtleLight).opacity(0.7),
                    lineWidth: 1
                )
        )
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AgentTodoPresentation.summary(todos))
    }

    private var header: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("To-dos")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(AgentTodoPresentation.progress(todos))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .interactiveHoverPill(cornerRadius: 10)
        .help(isExpanded ? "Hide the task list" : "Show the task list")
    }

    private func row(_ todo: AgentTodo) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbolName(for: todo.status))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint(for: todo.status))
                .frame(width: 14)
                .padding(.top, 1)

            Text(todo.content)
                .font(.system(size: 12))
                .foregroundStyle(todo.status == .cancelled ? .tertiary : .primary)
                .strikethrough(todo.status == .completed, color: .secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .accessibilityLabel(
            "\(todo.content), \(statusName(todo.status))"
        )
    }

    private func symbolName(for status: AgentTodo.Status) -> String {
        switch status {
        case .pending:
            "circle"
        case .inProgress:
            "circle.dotted"
        case .completed:
            "checkmark.circle.fill"
        case .cancelled:
            "xmark.circle"
        }
    }

    private func tint(for status: AgentTodo.Status) -> Color {
        switch status {
        case .pending:
            .secondary
        case .inProgress:
            accent
        case .completed:
            .green
        case .cancelled:
            Color.secondary.opacity(0.5)
        }
    }

    private func statusName(_ status: AgentTodo.Status) -> String {
        switch status {
        case .pending: "pending"
        case .inProgress: "in progress"
        case .completed: "done"
        case .cancelled: "cancelled"
        }
    }
}
