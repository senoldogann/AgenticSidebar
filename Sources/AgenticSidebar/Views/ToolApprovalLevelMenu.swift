import SwiftUI

/// The approval level, switchable while the agent is running.
///
/// It lives in the window toolbar rather than only in Settings because the level
/// is a decision you change *while* watching the agent do something — a turn that
/// keeps asking about safe commands, or one that needs to get through a step
/// without a prompt. The level is applied per request, so choosing here takes
/// effect on the next tool call; the waiting prompts are re-answered with the new
/// level at the same time, so the queue cannot contradict the choice.
///
/// The pending count is shown here for the same reason: the number is the answer
/// to "is it waiting on me?".
struct ToolApprovalLevelMenu: View {
    let settingsStore: SettingsStore
    let permissionApprovalCenter: PermissionApprovalCenter

    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        Menu {
            ForEach(ToolApprovalPolicy.allCases) { policy in
                Button {
                    apply(policy)
                } label: {
                    Label {
                        Text("\(policy.displayName) — \(policy.summary)")
                    } icon: {
                        Image(systemName: settingsStore.toolApprovalPolicy == policy
                            ? "checkmark"
                            : policy.symbolName)
                    }
                }
            }

            if !permissionApprovalCenter.pending.isEmpty {
                Divider()

                Button {
                    permissionApprovalCenter.rejectAll()
                } label: {
                    Label("Deny all pending", systemImage: "xmark.circle")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: settingsStore.toolApprovalPolicy.symbolName)
                    .font(.system(size: 11, weight: .semibold))

                Text(settingsStore.toolApprovalPolicy.displayName)
                    .font(.system(size: 11.5, weight: .semibold))

                if !permissionApprovalCenter.pending.isEmpty {
                    Text("\(permissionApprovalCenter.pending.count)")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Color.orange.opacity(0.9),
                            in: Capsule()
                        )
                        .foregroundStyle(.white)
                }
            }
            .foregroundStyle(settingsStore.toolApprovalPolicy.isUnrestricted ? Color.orange : .primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(
            "Tool approvals: \(settingsStore.toolApprovalPolicy.displayName). \(settingsStore.toolApprovalPolicy.summary) Changes apply to the running agent on its next tool call."
        )
        .accessibilityLabel(
            "Tool approvals, \(settingsStore.toolApprovalPolicy.displayName), \(permissionApprovalCenter.pending.count) pending"
        )
    }

    private func apply(_ policy: ToolApprovalPolicy) {
        guard settingsStore.toolApprovalPolicy != policy else {
            return
        }

        settingsStore.toolApprovalPolicy = policy
        // The prompts on screen were asked under the previous level.
        permissionApprovalCenter.reinterpretPendingRequests()
    }
}
