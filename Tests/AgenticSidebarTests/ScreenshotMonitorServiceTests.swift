import Foundation
import XCTest

@testable import AgenticSidebar

@MainActor
final class ScreenshotMonitorServiceTests: XCTestCase {
    private var workspaceURL: URL!
    private var screenshotsDirectoryURL: URL!
    private var temporaryDirectoryURL: URL!
    private var settingsSuiteName: String!

    override func setUp() async throws {
        try await super.setUp()

        workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenshot-monitor-tests-\(UUID().uuidString)")
        screenshotsDirectoryURL = workspaceURL.appendingPathComponent("Screenshots")
        temporaryDirectoryURL = workspaceURL.appendingPathComponent("Temporary")

        try FileManager.default.createDirectory(
            at: screenshotsDirectoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )

        settingsSuiteName = "AgenticSidebarTests.Screenshot.\(UUID().uuidString)"
        UserDefaults(suiteName: settingsSuiteName)!
            .removePersistentDomain(forName: settingsSuiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workspaceURL)
        UserDefaults(suiteName: settingsSuiteName)?
            .removePersistentDomain(forName: settingsSuiteName)
        try await super.tearDown()
    }

    func testNewScreenshotIsAnalysedOnceAndSubmittedWithItsPath() async throws {
        let recorder = ScreenshotSubmissionRecorder()
        let service = await makeService(recorder: recorder)
        let (monitor, _) = makeMonitor(service: service, recognizer: "Solve for x: 2x + 4 = 10")

        monitor.start()
        monitor.stop()

        _ = try writeScreenshot(named: "Screenshot 2026-09-16 at 10.00.00.png")

        await monitor.tick()

        var submissions = await waitForSubmissions(recorder, count: 1)
        XCTAssertEqual(submissions.count, 1)
        let submission = try XCTUnwrap(submissions.first)
        XCTAssertTrue(submission.prompt.contains("Screenshot 2026-09-16 at 10.00.00.png"))
        XCTAssertTrue(submission.prompt.contains("Solve for x: 2x + 4 = 10"))
        XCTAssertEqual(submission.attachmentPaths.count, 1)
        XCTAssertEqual(
            submission.attachmentPaths.first
                .map { URL(fileURLWithPath: $0).pathExtension },
            "png"
        )
        XCTAssertTrue(
            submission.attachmentPaths.first?.contains("Screenshot_2026-09-16_at_10.00.00") == true,
            "The screenshot itself must be attached to the prompt (staged under a sanitized name)"
        )

        await monitor.tick()

        submissions = await waitForSubmissions(recorder, count: 1)
        XCTAssertEqual(submissions.count, 1, "The same screenshot must not be analysed twice")
    }

    func testScreenshotCapturedWhileBusyIsQueuedUntilIdle() async throws {
        let recorder = ScreenshotSubmissionRecorder()
        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        let service = await makeService(
            recorder: recorder,
            streamFactory: { _ in
                ProviderStream(events: pair.stream)
            })
        let (monitor, _) = makeMonitor(service: service, recognizer: "queued text")

        monitor.start()
        monitor.stop()

        let activeTask = try XCTUnwrap(service.submit("busy turn"))
        _ = try writeScreenshot(named: "Screenshot 2026-09-16 at 11.00.00.png")

        await monitor.tick()
        var submissions = await waitForSubmissions(recorder, count: 1)
        XCTAssertEqual(submissions.count, 1, "Only the manual turn ran so far")

        pair.continuation.yield(.completed)
        pair.continuation.finish()
        await activeTask.value

        await monitor.tick()
        submissions = await waitForSubmissions(recorder, count: 2)
        XCTAssertEqual(submissions.count, 2)
        XCTAssertTrue(submissions[1].prompt.contains("queued text"))
    }

    /// Exam modunda yakalanıp kuyrukta bekleyen ekran görüntüsü, flush anında
    /// kullanıcı Build'e geçmiş olsa bile kayıtlı modla (readonly exam) gider.
    func testQueuedSubmissionKeepsCaptureTimeMode() async throws {
        let recorder = ScreenshotSubmissionRecorder()
        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        let service = await makeService(
            recorder: recorder,
            streamFactory: { _ in
                ProviderStream(events: pair.stream)
            })
        let (monitor, store) = makeMonitor(service: service, recognizer: "exam text", mode: .exam)

        monitor.start()
        monitor.stop()

        let activeTask = try XCTUnwrap(service.submit("busy turn"))
        _ = try writeScreenshot(named: "Screenshot 2026-09-16 at 12.00.00.png")

        await monitor.tick()
        var submissions = await waitForSubmissions(recorder, count: 1)
        XCTAssertEqual(submissions.count, 1, "Only the manual turn ran so far")

        // Kuyrukta beklerken mod değişir: flush güncel modu değil kayıtlıyı kullanmalı.
        store.agentMode = .build

        pair.continuation.yield(.completed)
        pair.continuation.finish()
        await activeTask.value

        await monitor.tick()
        submissions = await waitForSubmissions(recorder, count: 2)
        XCTAssertEqual(submissions.count, 2)
        XCTAssertTrue(submissions[1].prompt.contains("EXAM SOLVER"))
        XCTAssertEqual(submissions[1].mode, .exam)
    }

    func testExpiredTemporaryScreenshotsAreRemovedAtStartup() async throws {
        let expiredURL = temporaryDirectoryURL.appendingPathComponent("expired.png")
        let freshURL = temporaryDirectoryURL.appendingPathComponent("fresh.png")
        try Data([0x01]).write(to: expiredURL)
        try Data([0x02]).write(to: freshURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-(48 * 60 * 60))],
            ofItemAtPath: expiredURL.path
        )

        let recorder = ScreenshotSubmissionRecorder()
        let service = await makeService(recorder: recorder)
        let (monitor, _) = makeMonitor(service: service, recognizer: "")

        monitor.start()
        monitor.stop()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: expiredURL.path),
            "Screenshots left over from earlier runs must be swept"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshURL.path))
    }

    func testShouldRescanMatrix() {
        let now = Date()
        XCTAssertTrue(
            ScreenshotMonitorService.shouldRescan(directoryModDate: now, lastScannedModDate: nil),
            "İlk tarama her zaman koşar"
        )
        XCTAssertTrue(
            ScreenshotMonitorService.shouldRescan(directoryModDate: nil, lastScannedModDate: now),
            "Okunamayan dizin her zaman taranır, yoksa yeni dosya kaçardı"
        )
        XCTAssertTrue(
            ScreenshotMonitorService.shouldRescan(
                directoryModDate: now.addingTimeInterval(1),
                lastScannedModDate: now
            )
        )
        XCTAssertFalse(
            ScreenshotMonitorService.shouldRescan(directoryModDate: now, lastScannedModDate: now),
            "Değişmeyen dizin taranmaz (enerji)"
        )
    }

    func testTickSkipsUnchangedDirectoryAndFindsNewFiles() async throws {
        let recorder = ScreenshotSubmissionRecorder()
        let service = await makeService(recorder: recorder)
        let (monitor, _) = makeMonitor(service: service, recognizer: "skip text")

        monitor.start()
        monitor.stop()

        await monitor.tick()
        var submissions = await waitForSubmissions(recorder, count: 0)
        XCTAssertEqual(submissions.count, 0)

        _ = try writeScreenshot(named: "Screenshot 2026-09-16 at 13.00.00.png")
        await monitor.tick()
        submissions = await waitForSubmissions(recorder, count: 1)
        XCTAssertEqual(submissions.count, 1)

        await monitor.tick()
        submissions = await waitForSubmissions(recorder, count: 1)
        XCTAssertEqual(submissions.count, 1, "Dizin değişmediyse ikinci tarama atlanır, yine de kayıt korunur")
    }

    /// Submissions run inside a MainActor task, so the recorder is polled instead
    /// of being asserted synchronously.
    private func waitForSubmissions(
        _ recorder: ScreenshotSubmissionRecorder,
        count: Int
    ) async -> [ScreenshotSubmission] {
        for _ in 0..<200 {
            let submissions = await recorder.submissions()
            if submissions.count >= count {
                return submissions
            }
            try? await Task.sleep(for: .milliseconds(5))
        }

        return await recorder.submissions()
    }

    private func writeScreenshot(named fileName: String) throws -> URL {
        let fileURL = screenshotsDirectoryURL.appendingPathComponent(fileName)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fileURL)
        return fileURL
    }

    private func makeMonitor(
        service: AgentSessionService,
        recognizer: String,
        mode: AgentMode = .build
    ) -> (ScreenshotMonitorService, SettingsStore) {
        let defaults = UserDefaults(suiteName: settingsSuiteName)!
        let store = SettingsStore(defaults: defaults)
        store.autoAnalyzeScreenshots = true
        store.agentMode = mode

        return (
            ScreenshotMonitorService(
                sessionService: service,
                settingsStore: store,
                textRecognizer: StubScreenshotTextRecognizer(text: recognizer),
                pasteboard: EmptyPasteboardReader(),
                screenshotsDirectoryURL: screenshotsDirectoryURL,
                temporaryDirectoryURL: temporaryDirectoryURL
            ), store
        )
    }

    private func makeService(
        recorder: ScreenshotSubmissionRecorder,
        streamFactory: @escaping @Sendable (ProviderRequest) async throws -> ProviderStream = { _ in
            let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
            pair.continuation.yield(.completed)
            pair.continuation.finish()
            return ProviderStream(events: pair.stream)
        }
    ) async -> AgentSessionService {
        let runtime = TestProviderRuntime(
            id: ProviderID("alpha"),
            displayName: "Alpha",
            models: [
                ProviderModelCapability(
                    id: ProviderModelID("alpha-1"),
                    displayName: "Alpha 1",
                    variants: []
                )
            ],
            streamFactory: { request in
                await recorder.record(request)
                return try await streamFactory(request)
            }
        )

        let service = AgentSessionService(runtimes: [runtime])
        await service.refreshCapabilities()
        return service
    }
}

private struct StubScreenshotTextRecognizer: ScreenshotTextRecognizing {
    let text: String

    func recognizeText(at fileURL: URL) async -> String {
        text
    }

    func recognizeText(inImageData data: Data) async -> String {
        text
    }
}

private struct EmptyPasteboardReader: PasteboardReading {
    func snapshot() -> PasteboardSnapshot {
        PasteboardSnapshot(
            changeCount: 0,
            types: [],
            containsImage: false
        )
    }

    func currentString() -> String? {
        nil
    }

    func imagePNGData() -> Data? {
        nil
    }
}

private struct ScreenshotSubmission: Sendable {
    let prompt: String
    let attachmentPaths: [String]
    let mode: AgentMode
}

private actor ScreenshotSubmissionRecorder {
    private var recorded: [ScreenshotSubmission] = []

    func record(_ request: ProviderRequest) {
        let message = request.messages.last

        recorded.append(
            ScreenshotSubmission(
                prompt: message?.text ?? "",
                attachmentPaths: message?.attachmentPaths ?? [],
                mode: request.mode
            )
        )
    }

    func submissions() -> [ScreenshotSubmission] {
        recorded
    }
}
