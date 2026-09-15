import AppKit
import SwiftUI

struct MenuBarSessionView: View {
    let sessionStore: SessionPresentationStore
    let mainWindowController: MainWindowController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    sessionStore.state.statusTitle,
                    systemImage: sessionStore.state.symbolName
                )
                .font(.headline)

                Text(
                    ElapsedTimeFormatter.string(
                        seconds: sessionStore.state.elapsed(at: context.date)
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
