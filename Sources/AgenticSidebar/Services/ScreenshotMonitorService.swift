import AppKit
import CoreServices
import Foundation

@MainActor
final class ScreenshotMonitorService {
    /// How macOS names the files it writes for ⇧⌘3/4/5, per language.
    ///
    /// Matching three English-ish prefixes meant the feature reported itself as
    /// enabled in Settings and then never fired on a German, Spanish or Japanese
    /// system — the "I turned it on and nothing happened" failure this project
    /// designs against elsewhere. The list is how it is discovered without asking
    /// the WindowServer, and ``isScreenCaptureByMetadata(_:)`` is the check that
    /// does not depend on the name at all.
    nonisolated static let localizedScreenshotNameFragments = [
        "screenshot", "screen shot", "ekran resmi", "ekran görüntüsü",
        "bildschirmfoto", "bildschirmaufnahme",
        "captura de pantalla", "captura de tela", "pantallazo", "captura de ecrã",
        "capture d'écran", "capture d’écran", "capture d'ecran", "capture d’ecran",
        "schermafbeelding", "schermopname",
        "skärmavbild", "skjermbilde", "skærmbillede", "näyttökuva", "skjermdump",
        "снимок экрана", "знімок екрана", "екранна снимка",
        "スクリーンショット", "스크린샷", "截屏", "截图", "屏幕快照", "螢幕快照",
        "képernyőkép", "zrzut ekranu", "snímek obrazovky", "snímka obrazovky",
        "zaslonska slika", "ekraanipilt", "ekrānuzņēmums", "ekrano kopija",
        "captură de ecran", "snimak ekrana", "στιγμιότυπο οθόνης",
        "צילום מסך", "لقطة الشاشة", "स्क्रीनशॉट", "สกรีนช็อต", "ảnh chụp màn hình",
    ]

    /// Image types macOS writes for a screenshot, including the `.jpeg` and
    /// `.heic` that some export paths produce (only `.png` and `.jpg` used to be
    /// accepted, so those screenshots were invisible).
    nonisolated static let screenshotFileExtensions = ["png", "jpg", "jpeg", "heic", "tiff"]

    /// Whether the file is even an image macOS would write a screenshot as.
    ///
    /// Checked *before* anything else, including before Spotlight is asked: the
    /// scan runs over the whole screenshots folder once a second, and asking
    /// about every PDF, folder and text file on the Desktop was the expensive
    /// half of it.
    nonisolated static func hasScreenshotExtension(_ fileName: String) -> Bool {
        let lowered = fileName.lowercased()
        return screenshotFileExtensions.contains { lowered.hasSuffix("." + $0) }
    }

    /// Whether a file name looks like a screenshot on this system.
    nonisolated static func hasScreenshotName(_ fileName: String) -> Bool {
        guard hasScreenshotExtension(fileName) else {
            return false
        }

        let lowered = fileName.lowercased()
        return localizedScreenshotNameFragments.contains { lowered.contains($0) }
    }

    /// Whether a file is a screenshot: its name, or — only for an image whose
    /// name says nothing — Spotlight's answer.
    ///
    /// `metadataProbe` is called only when the name did not already answer, so a
    /// folder of screenshots costs no Spotlight queries at all and a folder of
    /// other files costs none either.
    nonisolated static func isScreenshotCandidate(
        fileURL: URL,
        metadataProbe: (URL) -> Bool?
    ) -> Bool {
        let fileName = fileURL.lastPathComponent
        guard hasScreenshotExtension(fileName) else {
            return false
        }
        if hasScreenshotName(fileName) {
            return true
        }
        return metadataProbe(fileURL) ?? false
    }

    /// Spotlight's own answer, when the volume is indexed.
    ///
    /// `nil` means "not known", which is not the same as "no": with indexing off,
    /// or for a file created a moment ago, the name test is the only signal there
    /// is.
    nonisolated static func isScreenCaptureByMetadata(_ url: URL) -> Bool? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else {
            return nil
        }

        // The attribute name is spelled out: the C constant `kMDItemIsScreenCapture`
        // is not visible to Swift, and this string is the name Spotlight answers to.
        guard
            let value = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString),
            let isScreenCapture = value as? Bool
        else {
            return nil
        }

        return isScreenCapture
    }

    struct PendingSubmission {
        let prompt: String
        let attachmentPath: String?
        /// Yakalama anındaki mod/hız: kuyrukta beklerken kullanıcı modu
        /// değiştirse bile gönderim kayıtlı değerle yapılır. Güncel modu
        /// flush anında okumak, exam için hazırlanmış güvenilmez girdiyi
        /// `build` yetkisiyle koştururdu (TOCTOU yetki tırmanması).
        let mode: AgentMode
        let speedMode: ResponseSpeedMode
    }

    static let defaultScreenshotsDirectoryURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop", isDirectory: true)

    static let defaultTemporaryDirectoryURL = FileManager.default
        .temporaryDirectory
        .appendingPathComponent(AppIdentity.name, isDirectory: true)
        .appendingPathComponent("Screenshots", isDirectory: true)

    /// Read by ``scanRecentScreenshots``, which runs off the main actor.
    nonisolated private static let recentFileWindow: TimeInterval = 60
    nonisolated private static let temporaryScreenshotLifetime: TimeInterval = 24 * 60 * 60
    private static let maximumTrackedPaths = 256

    /// Oturumun henüz kabul edemediği yakalamalar sırasını burada bekler.
    ///
    /// Tek yuvalı bir tampon, arka arkaya iki ekran görüntüsünde ilkini sessizce
    /// düşürüyordu.
    private static let maximumPendingSubmissions = 5

    private let sessionService: AgentSessionService
    private let settingsStore: SettingsStore
    /// Oturum başına besteci tercihleri: ekran gönderimi aktif sohbete gider,
    /// o sohbetin modu ve hızı kullanılır. Yoksa genel değer geçerlidir.
    var composerPrefs: SessionComposerPrefs?
    private let textRecognizer: any ScreenshotTextRecognizing
    private let pasteboard: any PasteboardReading
    private let screenshotsDirectoryURL: URL
    private let temporaryDirectoryURL: URL

    private var lastPasteboardChangeCount: Int
    private var trackedFilePaths: [String] = []
    private var trackedFilePathSet: Set<String> = []
    private var pendingSubmissions: [PendingSubmission] = []
    private var timer: Timer?
    /// Whether a tick is still running; see ``tick()``.
    private var isTicking = false

    init(
        sessionService: AgentSessionService,
        settingsStore: SettingsStore
    ) {
        self.sessionService = sessionService
        self.settingsStore = settingsStore
        self.textRecognizer = VisionScreenshotTextRecognizer()
        self.pasteboard = SystemPasteboardReader()
        self.screenshotsDirectoryURL = Self.defaultScreenshotsDirectoryURL
        self.temporaryDirectoryURL = Self.defaultTemporaryDirectoryURL
        self.lastPasteboardChangeCount = pasteboard.snapshot().changeCount
    }

    init(
        sessionService: AgentSessionService,
        settingsStore: SettingsStore,
        textRecognizer: any ScreenshotTextRecognizing,
        pasteboard: any PasteboardReading,
        screenshotsDirectoryURL: URL?,
        temporaryDirectoryURL: URL?
    ) {
        self.sessionService = sessionService
        self.settingsStore = settingsStore
        self.textRecognizer = textRecognizer
        self.pasteboard = pasteboard
        self.screenshotsDirectoryURL = screenshotsDirectoryURL ?? Self.defaultScreenshotsDirectoryURL
        self.temporaryDirectoryURL = temporaryDirectoryURL ?? Self.defaultTemporaryDirectoryURL
        self.lastPasteboardChangeCount = pasteboard.snapshot().changeCount
    }

    func start() {
        stop()
        lastPasteboardChangeCount = pasteboard.snapshot().changeCount
        pendingSubmissions = []
        trackedFilePaths = []
        trackedFilePathSet = []

        guard settingsStore.autoAnalyzeScreenshots else {
            return
        }

        // Geçici süpürme eşzamanlı: küçük dizin, test de bunu bekler.
        // Açılış tohumlaması arka planda: büyük klasör ana işi tutmasın.
        let screenshotsURL = screenshotsDirectoryURL
        let temporaryURL = temporaryDirectoryURL
        Self.removeStaleTemporaryScreenshots(in: temporaryURL)
        Task.detached(priority: .utility) { [weak self] in
            let seeded = Set(
                Self.scanRecentScreenshots(in: screenshotsURL, now: Date()).map(\.path)
            )
            await MainActor.run { [weak self] in
                self?.trackedFilePathSet = seeded
            }
        }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.tick()
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
        if settingsStore.autoAnalyzeScreenshots {
            if timer == nil {
                start()
            }
        } else {
            stop()
        }
    }

    /// One polling step. Kept internal so tests can drive the monitor without
    /// depending on timer scheduling.
    func tick() async {
        guard settingsStore.autoAnalyzeScreenshots else {
            pendingSubmissions = []
            return
        }

        // One tick at a time. The scan and the OCR are awaited, and a second
        // timer firing inside them would only repeat the same work on the same
        // list of files.
        guard !isTicking else {
            return
        }
        isTicking = true
        defer { isTicking = false }

        for fileURL in await scannedRecentScreenshotFileURLs()
        where !trackedFilePathSet.contains(fileURL.path) {
            // Mark before awaiting so a slow analysis cannot re-process the file.
            track(fileURL.path)
            await analyzeScreenshot(at: fileURL)
        }

        await capturePasteboardImageIfNeeded()
        flushPendingSubmissions()
    }

    nonisolated static func buildIntentPrompt(
        fileName: String,
        extractedText: String,
        mode: AgentMode = .build
    ) -> String {
        let contentSection: String
        if extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contentSection = "(No machine-readable text found in screenshot)"
        } else {
            contentSection = "Extracted content from screenshot:\n\"\"\"\n\(extractedText)\n\"\"\""
        }

        if mode == .exam {
            return """
                [Screenshot captured: \(fileName)]
                \(contentSection)

                EXAM SOLVER: Inspect this screenshot carefully. Identify any test, exam, quiz, or homework questions visible in the image. State the direct answer first (e.g. "**Correct Answer: B**"), then provide the step-by-step mathematical derivation, reasoning, or code solution.
                """
        }

        if mode == .review {
            return """
                [Screenshot captured: \(fileName)]
                \(contentSection)

                REVIEW MODE: Inspect this screenshot for bugs, security vulnerabilities, performance bottlenecks, or code quality issues. Provide your review findings grouped by severity and conclude with a prioritized remediation plan in a ```plan block. Do not modify files directly.
                """
        }

        return """
            [Screenshot captured: \(fileName)]
            \(contentSection)

            Please inspect this screenshot carefully: infer intent, if there is a question or problem solve it and provide the direct answer, or describe what is shown.
            """
    }

    private func analyzeScreenshot(at fileURL: URL) async {
        let extractedText = await textRecognizer.recognizeText(at: fileURL)

        enqueue(
            Self.buildIntentPrompt(
                fileName: fileURL.lastPathComponent,
                extractedText: extractedText,
                mode: effectiveAgentMode
            ),
            attachmentPath: fileURL.path,
            mode: effectiveAgentMode,
            speedMode: effectiveSpeedMode
        )
    }

    private func capturePasteboardImageIfNeeded() async {
        let snapshot = pasteboard.snapshot()

        guard snapshot.changeCount != lastPasteboardChangeCount else {
            return
        }
        lastPasteboardChangeCount = snapshot.changeCount

        guard !PasteboardPrivacyMarker.isMarked(snapshot) else {
            AppLog.automation.debug(
                "Ignored a clipboard image marked as concealed or transient"
            )
            return
        }

        guard
            snapshot.containsImage,
            let pngData = pasteboard.imagePNGData()
        else {
            return
        }

        let attachmentPath = writeTemporaryScreenshot(pngData)
        let extractedText = await textRecognizer.recognizeText(inImageData: pngData)

        enqueue(
            Self.buildIntentPrompt(
                fileName: "Clipboard Screenshot",
                extractedText: extractedText,
                mode: effectiveAgentMode
            ),
            attachmentPath: attachmentPath,
            mode: effectiveAgentMode,
            speedMode: effectiveSpeedMode
        )
    }

    /// Screenshots are kept on disk only while the in-memory transcript can still
    /// reference them; stale files from earlier runs are swept at startup.
    private func writeTemporaryScreenshot(_ pngData: Data) -> String? {
        let fileURL = temporaryDirectoryURL.appendingPathComponent(
            "screenshot-\(UUID().uuidString).png"
        )

        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try pngData.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            return fileURL.path
        } catch {
            AppLog.automation.error(
                "Could not persist the clipboard screenshot: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func enqueue(_ prompt: String, attachmentPath: String?, mode: AgentMode, speedMode: ResponseSpeedMode) {
        pendingSubmissions.append(
            PendingSubmission(
                prompt: prompt,
                attachmentPath: attachmentPath,
                mode: mode,
                speedMode: speedMode
            )
        )

        while pendingSubmissions.count > Self.maximumPendingSubmissions {
            pendingSubmissions.removeFirst()
            AppLog.automation.error(
                "The screenshot queue is full; the oldest capture was dropped"
            )
        }
    }

    /// Bekleyen yakalamalar sırayla oturuma verilir.
    ///
    /// `send` çalışan bir turun arkasına ekler; böylece ekran görüntüleri de
    /// diğer mesajlarla aynı kuyruktan geçer. Oturumun hiç kabul edemediği bir
    /// istek sırada kalır.
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
        while let next = pendingSubmissions.first, sessionService.canAcceptPrompt {
            let acceptance = sessionService.send(
                next.prompt,
                attachmentPaths: next.attachmentPath.map { [$0] } ?? [],
                speedMode: next.speedMode,
                mode: next.mode
            )

            guard acceptance.wasAccepted else {
                return
            }

            pendingSubmissions.removeFirst()
        }
    }

    private func track(_ path: String) {
        trackedFilePaths.append(path)
        trackedFilePathSet.insert(path)

        while trackedFilePaths.count > Self.maximumTrackedPaths {
            trackedFilePathSet.remove(trackedFilePaths.removeFirst())
        }
    }

    /// The per-second scan, off the main actor.
    private func scannedRecentScreenshotFileURLs() async -> [URL] {
        let directoryURL = screenshotsDirectoryURL
        let now = Date()
        return await Task.detached(priority: .utility) {
            Self.scanRecentScreenshots(in: directoryURL, now: now)
        }.value
    }

    /// One walk of the screenshots folder, filtered to the files that appeared in
    /// the last minute.
    ///
    /// `nonisolated` and static so the per-second caller can run it off the main
    /// actor: enumerating a Desktop with thousands of entries and reading every
    /// file's modification date is the most expensive thing this service does.
    nonisolated static func scanRecentScreenshots(
        in directoryURL: URL,
        now: Date,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        return contents.filter { url in
            guard
                isScreenshotCandidate(
                    fileURL: url,
                    metadataProbe: isScreenCaptureByMetadata
                )
            else {
                return false
            }

            guard let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                let modDate = resourceValues.contentModificationDate
            else {
                return false
            }

            return now.timeIntervalSince(modDate) < recentFileWindow
        }
    }

    nonisolated private static func removeStaleTemporaryScreenshots(in directoryURL: URL) {
        let fileManager = FileManager.default

        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }

        let cutoff = Date().addingTimeInterval(-temporaryScreenshotLifetime)

        for fileURL in contents {
            guard
                let modified =
                    try? fileURL
                    .resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                modified < cutoff
            else {
                continue
            }

            do {
                try fileManager.removeItem(at: fileURL)
            } catch {
                AppLog.automation.error(
                    "Could not remove an expired screenshot file: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
