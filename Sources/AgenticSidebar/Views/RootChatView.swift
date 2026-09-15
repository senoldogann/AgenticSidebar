import SwiftUI

struct RootChatView: View {
    @Environment(\.openWindow) private var openWindow

    let sessionService: AgentSessionService
    let mainWindowController: MainWindowController
    let capturePrivacyController: CapturePrivacyController

    var body: some View {
        NavigationSplitView {
            ConversationSidebarView()
        } detail: {
            ConversationDetailView(sessionService: sessionService)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 520)
        .background {
            WindowLifecycleBridge(
                windowController: mainWindowController,
                capturePrivacyController: capturePrivacyController
            )
            .frame(width: 0, height: 0)
        }
        .onAppear {
            mainWindowController.setReopenAction {
                openWindow(id: "main")
            }
        }
        .task {
            await sessionService.refreshCapabilities()
        }
    }
}
