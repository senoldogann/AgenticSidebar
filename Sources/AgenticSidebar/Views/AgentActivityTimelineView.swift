import SwiftUI

struct AgentActivityTimelineView: View {
    let group: AgentTurnActivityGroup

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if hiddenActivityCount > 0 {
                    Text("\(hiddenActivityCount) earlier activities")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                ForEach(visibleActivities) { activity in
                    activityRow(activity)
                }
            }
            .padding(.top, 8)
        } label: {
            let presentation = AgentActivityPresentation(
                kind: summaryActivity.kind
            )

            HStack(spacing: 8) {
                activityStatus(summaryActivity.phase)
                    .frame(width: 14, height: 14)

                Image(systemName: presentation.symbolName)
                    .foregroundStyle(.secondary)

                Text(presentation.title)
                    .font(.caption.weight(.medium))

                Spacer()

                Text("\(group.activities.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            .quinary,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityLabel("Agent activity")
        .accessibilityValue(
            AgentActivityPresentation(kind: summaryActivity.kind).title
        )
    }

    private var visibleActivities: ArraySlice<AgentActivity> {
        group.activities.suffix(8)
    }

    private var hiddenActivityCount: Int {
        max(0, group.activities.count - visibleActivities.count)
    }

    private var summaryActivity: AgentActivity {
        if let runningActivity = group.activities.last(where: { $0.phase == .running }) {
            return runningActivity
        }

        guard let lastActivity = group.activities.last else {
            preconditionFailure(
                "Agent activity group \(group.id) must contain at least one activity."
            )
        }

        return lastActivity
    }

    @ViewBuilder
    private func activityRow(_ activity: AgentActivity) -> some View {
        let presentation = AgentActivityPresentation(kind: activity.kind)

        HStack(spacing: 8) {
            activityStatus(activity.phase)
                .frame(width: 14, height: 14)

            Label(presentation.title, systemImage: presentation.symbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func activityStatus(_ phase: AgentActivityPhase) -> some View {
        switch phase {
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "slash.circle")
                .foregroundStyle(.secondary)
        }
    }
}
