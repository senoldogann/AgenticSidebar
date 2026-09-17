import AppKit
import Foundation
import UserNotifications

/// Manages native macOS system notifications when agent sessions complete turns or tasks.
@MainActor
final class SessionNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SessionNotificationService()

    /// Action invoked when user clicks a notification to switch to the target session.
    var onSelectSession: ((UUID) -> Void)?

    private let center: UNUserNotificationCenter

    override init() {
        self.center = UNUserNotificationCenter.current()
        super.init()
        center.delegate = self
    }

    /// Requests macOS user notification permissions if not yet granted.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// Posts a native macOS notification informing the user that a session has finished.
    func postSessionCompletionNotification(
        sessionID: UUID,
        sessionTitle: String,
        status: AgentSessionStatus,
        previewText: String?,
        soundName: String,
        playSound: Bool,
        enabled: Bool
    ) {
        guard enabled else { return }

        // Play the chosen completion sound via NSSound for immediate, reliable macOS audio
        if playSound {
            if soundName == "Default" {
                NSSound.beep()
            } else {
                NSSound(named: soundName)?.play()
            }
        }

        let content = UNMutableNotificationContent()
        switch status {
        case .completed:
            content.title = "Task Completed"
        case .failed:
            content.title = "Task Failed"
        case .cancelled:
            content.title = "Task Cancelled"
        default:
            content.title = "Session Update"
        }

        content.subtitle = sessionTitle

        if let preview = previewText, !preview.isEmpty {
            let truncated = preview.prefix(160)
            content.body = String(truncated)
        } else {
            content.body = "Agent finished working on \(sessionTitle)."
        }

        content.userInfo = ["sessionID": sessionID.uuidString]

        if playSound {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: "session-complete-\(sessionID.uuidString)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )

        center.add(request) { error in
            if let error {
                AppLog.agentSession.error("Failed to deliver session notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Present banner and sound even when the app is active/focused
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let rawID = userInfo["sessionID"] as? String, let sessionID = UUID(uuidString: rawID) {
            Task { @MainActor in
                self.onSelectSession?(sessionID)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        completionHandler()
    }
}
