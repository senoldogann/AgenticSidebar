import AppKit
import Foundation

@MainActor
final class ClipboardMonitorService {
    private let sessionService: AgentSessionService
    private let settingsStore: SettingsStore
    private let pasteboard: any PasteboardReading
    /// Oturum başına besteci tercihleri: pano gönderimi aktif sohbete gider,
    /// o sohbetin modu ve hızı kullanılır. Yoksa genel değer geçerlidir.
    var composerPrefs: SessionComposerPrefs?

    /// Oturumun henüz kabul edemediği kopyalar sırasını burada bekler.
    ///
    /// Tek yuvalı bir tampon, arka arkaya iki kopyalamada ilkini sessizce
    /// düşürüyordu.
    private static let maximumPendingSubmissions = 5

    private var lastChangeCount: Int
    private var lastSubmittedText = ""
    private struct PendingClipboardSubmission: Equatable, Sendable {
        let text: String
        let sessionID: UUID
        /// Yakalama anındaki mod/hız: kuyrukta beklerken kullanıcı modu
        /// değiştirse bile gönderim kayıtlı değerle yapılır.
        let mode: AgentMode
        let speedMode: ResponseSpeedMode
    }

    private var pendingSubmissions: [PendingClipboardSubmission] = []
    private var timer: Timer?

    init(
        sessionService: AgentSessionService,
        settingsStore: SettingsStore
    ) {
        self.sessionService = sessionService
        self.settingsStore = settingsStore
        self.pasteboard = SystemPasteboardReader()
        self.lastChangeCount = pasteboard.snapshot().changeCount
    }

    init(
        sessionService: AgentSessionService,
        settingsStore: SettingsStore,
        pasteboard: any PasteboardReading
    ) {
        self.sessionService = sessionService
        self.settingsStore = settingsStore
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.snapshot().changeCount
    }

    func start() {
        stop()
        lastChangeCount = pasteboard.snapshot().changeCount
        pendingSubmissions = []

        guard settingsStore.autoSubmitClipboard else {
            return
        }

        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        // `.common` keeps polling while AppKit runs a nested loop (window drag,
        // menu tracking, scrolling); a `.default` timer silently paused there.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func syncWithSettings() {
        if settingsStore.autoSubmitClipboard {
            if timer == nil {
                start()
            }
        } else {
            stop()
        }
    }

    /// One polling step. Kept internal so tests can drive the monitor without
    /// depending on timer scheduling.
    func tick() {
        let snapshot = pasteboard.snapshot()
        let didChange = snapshot.changeCount != lastChangeCount

        // The clipboard is tracked even while the feature is disabled: otherwise
        // enabling the setting submits whatever happened to be on the clipboard,
        // which may be a credential copied long before.
        lastChangeCount = snapshot.changeCount

        guard settingsStore.autoSubmitClipboard else {
            pendingSubmissions = []
            return
        }

        if didChange {
            capture(snapshot)
        }

        flushPendingSubmissions()
    }

    private func capture(_ snapshot: PasteboardSnapshot) {
        guard !PasteboardPrivacyMarker.isMarked(snapshot) else {
            AppLog.automation.debug(
                "Ignored a clipboard item marked as concealed or transient"
            )
            return
        }

        guard let copiedString = pasteboard.currentString() else {
            return
        }

        let trimmed = copiedString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastSubmittedText else {
            return
        }

        lastSubmittedText = trimmed
        pendingSubmissions.append(
            PendingClipboardSubmission(
                text: trimmed,
                sessionID: sessionService.activeSessionID,
                mode: effectiveAgentMode,
                speedMode: effectiveSpeedMode
            )
        )

        while pendingSubmissions.count > Self.maximumPendingSubmissions {
            pendingSubmissions.removeFirst()
            AppLog.automation.error(
                "The clipboard queue is full; the oldest capture was dropped"
            )
        }
    }

    /// Bekleyen kopyalar sırayla oturuma verilir.
    ///
    /// `send` çalışan bir turun arkasına ekler; böylece yakalamalar da diğer
    /// mesajlarla aynı kuyruktan geçer ve kullanıcı ne beklediğini görür.
    /// Oturumun hiç kabul edemediği bir istek sırada kalır.
    private var effectiveAgentMode: AgentMode {
        composerPrefs?.effectiveAgentMode(
            for: sessionService.activeSessionID,
            default: settingsStore.agentMode
        ) ?? settingsStore.agentMode
    }

    private var effectiveSpeedMode: ResponseSpeedMode {
        composerPrefs?.effectiveSpeedMode(
            for: sessionService.activeSessionID,
            default: settingsStore.responseSpeedMode
        ) ?? settingsStore.responseSpeedMode
    }
    private func flushPendingSubmissions() {
        while let next = pendingSubmissions.first {
            guard let target = sessionService.session(for: next.sessionID) else {
                pendingSubmissions.removeFirst()
                AppLog.automation.error("A clipboard capture was dropped because its session no longer exists")
                continue
            }
            guard target.canAcceptPrompt else { return }

            let promptText: String
            if next.mode == .exam {
                promptText = """
                    EXAM SOLVER: Please solve the following question. State the direct answer first, followed by a step-by-step derivation:

                    \(next.text)
                    """
            } else {
                promptText = next.text
            }

            let acceptance = target.send(
                promptText,
                attachmentPaths: [],
                speedMode: next.speedMode,
                mode: next.mode
            )

            guard acceptance.wasAccepted else {
                return
            }

            pendingSubmissions.removeFirst()
        }
    }
}
