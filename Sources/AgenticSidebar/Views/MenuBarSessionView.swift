import AppKit
import SwiftUI

struct MenuBarSessionView: View {
    let sessionService: AgentSessionService
    let mainWindowController: MainWindowController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let presentationState = SessionPresentationState(
                agentSessionState: sessionService.state
            )

            VStack(alignment: .leading, spacing: 12) {
                Label(
                    presentationState.statusTitle,
                    systemImage: presentationState.symbolName
                )
                .font(.headline)

                Text(
                    ElapsedTimeFormatter.string(
                        seconds: presentationState.elapsed(at: context.date)
                    )
                )
                .monospacedDigit()
                .foregroundStyle(.secondary)

                Divider()

                Button("Show AgenticSidebar") {
                    mainWindowController.show()
                }

                SettingsLink {
                    Text("Settings…")
                }

                Button("Quit AgenticSidebar") {
                    NSApp.terminate(nil)
                }
            }
            .padding(14)
            .frame(width: 240)
        }
    }
}
