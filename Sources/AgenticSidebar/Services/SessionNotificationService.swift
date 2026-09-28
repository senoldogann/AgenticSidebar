import AppKit
import Foundation
import UserNotifications

/// Manages native macOS system notifications when agent sessions complete turns or tasks.
@MainActor
final class SessionNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SessionNotificationService()

    /// Action invoked when user clicks a notification to switch to the target session.
    ///
    /// `MainActor` yalıtımlıdır: bildirim temsilcisi yalıtımsız bağlamdan gelir,
    /// seçim ise oturum durumunda koşar; yanlış iş parçacığından çağrı derleyici
    /// düzeyinde engellenir. `@Sendable` değildir; atayan kapanış oturum
    /// servisini (`Sendable` olmayan) yakalar.
    var onSelectSession: (@MainActor (UUID) -> Void)?

    private var center: UNUserNotificationCenter?
    /// İzin isteği bir kez yapılır; sonrası kayıtlı kararla sürer. `post`
    /// eşzamanlı kaldığı için ilk istek ateşle-unut bir görevde koşar, ekleme
    /// iznin arkasına zincirlenir — ilk bildirim izin yarışına girmez.
    private var authorizationRequested = false

    /// Son bitiş zilinin zamanı; 3-4 oturum aynı anda bitince her zil
    /// AudioToolbox HAL kurulumunu senkron tetikler ve ana iş parçacığı
    /// üst üste tutulur (örneklemde ~220ms). Patlama anında tek zil çalar.
    private var lastCompletionSoundAt: Date?

    /// Merkezi ilk kullanımda kurar; `init` saf kalır.
    ///
    /// `UNUserNotificationCenter.current()` açılışta eşzamanlı çağrıldığında
    /// yakalanamaz bir ObjC istisnasıyla süreci öldürüyordu (bug 309:
    /// `currentNotificationCenter` içindeki `NSCalendarDate initWithCoder`
    /// çözümü patlıyor, `SessionNotificationService.init:26`,
    /// `AgenticSidebarApp.init:137`). Swift ObjC istisnasını yakalayamaz, o
    /// yüzden savunma çağrıyı açılış yolundan çekmektir: ilk dokunuş ilk
    /// biten turun bildirimiyle olur. Temsilci, bildirimin akabileceği ilk
    /// andan önce atanır; davranış korunur.
    ///
    /// `.app` paketi dışında (`swift run`, test koşucusu) merkez hiç
    /// istenmez: `currentNotificationCenter` paket kimliği olmayan süreçte
    /// yakalanamaz bir iddia istisnasıyla süreci sonlandırır. O durumda
    /// `nil` döner ve bildirim atlanır.
    private func ensureCenter() -> UNUserNotificationCenter? {
        if let center {
            return center
        }
        guard Self.isRunningFromAppBundle() else {
            return nil
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        self.center = center
        return center
    }

    nonisolated static func isRunningFromAppBundle() -> Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    /// Requests macOS user notification permissions if not yet granted.
    @discardableResult
    func requestAuthorization() async -> Bool {
        authorizationRequested = true
        guard let center = ensureCenter() else {
            AppLog.agentSession.info("Notifications skipped: the process is not running from an app bundle")
            return false
        }
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            AppLog.agentSession.error(
                "Notification authorization failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Posts a native macOS notification informing the user that a session has finished.
    ///
    /// `includePreview` kapalıyken transkript alıntısı bildirime konmaz:
    /// alıntı Bildirim Merkezi'nde (kilit ekranı dahil) kalıcı durur.
    func postSessionCompletionNotification(
        sessionID: UUID,
        sessionTitle: String,
        status: AgentSessionStatus,
        previewText: String?,
        soundName: String,
        playSound: Bool,
        enabled: Bool,
        includePreview: Bool = true
    ) {
        guard enabled else { return }

        // Seçilen zil uygulamanın kendisinden çalar; bildirim sessiz kalır.
        // İkisi birden çaldığında her tur sonunda çift zil duyuluyordu.
        // İlk `NSSound` çalımı ses donanımını eşzamanlı kurar (ana iş
        // parçacığında ~100-240 ms); zil bu yüzden ayrık görevde çalar.
        if playSound {
            if soundName == "Default" {
                NSSound.beep()
            } else {
                let now = Date()
                if shouldPlayCompletionSound(now: now) {
                    lastCompletionSoundAt = now
                    let name = soundName
                    Task.detached(priority: .utility) {
                        NSSound(named: name)?.play()
                    }
                }
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

        content.body = Self.body(
            previewText: previewText,
            sessionTitle: sessionTitle,
            includePreview: includePreview
        )

        content.userInfo = ["sessionID": sessionID.uuidString]

        let request = UNNotificationRequest(
            identifier: "session-complete-\(sessionID.uuidString)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )

        // İzin açılışta değil ilk bildirimde istenir: açılış yolunda Apple
        // API'sine hiç dokunulmaz (yukarıdaki çökme), istek hâlâ eklemeden
        // önce tamamlanır. İmza eşzamanlı kalır, arayan değişmez.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.authorizationRequested {
                _ = await self.requestAuthorization()
            }
            guard let center = self.ensureCenter() else {
                return
            }
            do {
                try await center.add(request)
            } catch {
                AppLog.agentSession.error("Failed to deliver session notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Bildirim gövdesi (saf, test edilebilir)

    /// Patlama anında zil teklenir: son zilden bu kadar süre geçmeden yeni zil çalınmaz.
    /// Değişmez sabit olduğu için yalıtımsız bağlamdan da okunur.
    nonisolated static let completionSoundCoalescingInterval: TimeInterval = 2

    /// Saf karar: verilen zamanda zil çalınmalı mı.
    nonisolated static func shouldPlayCompletionSound(
        now: Date,
        lastPlayedAt: Date?
    ) -> Bool {
        guard let lastPlayedAt else {
            return true
        }
        return now.timeIntervalSince(lastPlayedAt) >= completionSoundCoalescingInterval
    }

    private func shouldPlayCompletionSound(now: Date) -> Bool {
        Self.shouldPlayCompletionSound(now: now, lastPlayedAt: lastCompletionSoundAt)
    }

    /// Bildirim gövdesini kurar: önizleme açıksa ilk 160 karakter, kapalıysa
    /// veya alıntı yoksa genel metin.
    nonisolated static func body(
        previewText: String?,
        sessionTitle: String,
        includePreview: Bool
    ) -> String {
        if includePreview, let preview = previewText, !preview.isEmpty {
            return String(preview.prefix(160))
        }
        return "Agent finished working on \(sessionTitle)."
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Uygulama öndeyken de afiş gösterilir; zil uygulamanın kendisinden
        // çaldığı için bildirim sesi istenmez.
        completionHandler([.banner, .list])
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
