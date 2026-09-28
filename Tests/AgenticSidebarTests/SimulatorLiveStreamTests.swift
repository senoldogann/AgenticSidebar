import CoreGraphics
import XCTest

@testable import AgenticSidebar

final class SimulatorLiveStreamTests: XCTestCase {
    private func window(
        id: CGWindowID = 1,
        owner: String? = "com.apple.iphonesimulator",
        title: String? = "iPhone 17",
        onScreen: Bool = true,
        area: CGFloat = 1000
    ) -> SimulatorWindowInfo {
        SimulatorWindowInfo(
            windowID: id,
            ownerBundleID: owner,
            title: title,
            isOnScreen: onScreen,
            area: area
        )
    }

    func testSelectsSimulatorWindowMatchingDeviceName() {
        let windows = [
            window(id: 1, owner: "com.apple.Safari", title: "iPhone 17"),
            window(id: 2, title: "iPhone 17"),
        ]
        XCTAssertEqual(
            SimulatorWindowSelector.select(deviceName: "iPhone 17", windows: windows)?.windowID,
            2
        )
    }

    func testPrefersLargestMatchingWindow() {
        let windows = [
            window(id: 1, area: 500),
            window(id: 2, area: 4000),
        ]
        XCTAssertEqual(
            SimulatorWindowSelector.select(deviceName: "iPhone 17", windows: windows)?.windowID,
            2
        )
    }

    func testIgnoresOffScreenAndTitleMismatch() {
        let windows = [
            window(id: 1, onScreen: false),
            window(id: 2, title: "iPhone 16"),
            window(id: 3, owner: "com.apple.dt.DeviceHub", title: "iPhone 17 Pro - iOS 26.5"),
        ]
        // Başlık cihaz adıyla başlayıp ayırıcıyla sürer; DeviceHub da
        // geçerli sahibin parçasıdır.
        XCTAssertEqual(
            SimulatorWindowSelector.select(deviceName: "iPhone 17 Pro", windows: windows)?.windowID,
            3
        )
        // "iPhone 17" aranırken "iPhone 17 Pro" penceresi yakalanmaz.
        XCTAssertNil(SimulatorWindowSelector.select(deviceName: "iPhone 17", windows: windows))
    }

    func testTitleMatchRequiresTheNameToEnd() {
        XCTAssertTrue(SimulatorWindowSelector.titleMatches("iphone 17 pro", deviceName: "iphone 17 pro"))
        XCTAssertTrue(SimulatorWindowSelector.titleMatches("iphone 17 pro – ios 26.5", deviceName: "iphone 17 pro"))
        XCTAssertFalse(SimulatorWindowSelector.titleMatches("iphone 17 pro max", deviceName: "iphone 17 pro"))
    }

    func testReturnsNilWithoutMatch() {
        XCTAssertNil(SimulatorWindowSelector.select(deviceName: "iPhone 17", windows: []))
        XCTAssertNil(SimulatorWindowSelector.select(deviceName: "  ", windows: [window()]))
        XCTAssertNil(
            SimulatorWindowSelector.select(deviceName: "iPad", windows: [window()])
        )
    }

    func testEvenPixelRoundsDownToEven() {
        XCTAssertEqual(SimulatorLiveStream.evenPixel(901), 900)
        XCTAssertEqual(SimulatorLiveStream.evenPixel(900), 900)
        XCTAssertEqual(SimulatorLiveStream.evenPixel(1), 2)
    }

    func testDenialMapsToDeniedPhase() {
        let error = NSError(
            domain: "com.apple.ScreenCaptureKit.SCStreamError",
            code: -3801,
            userInfo: [NSLocalizedDescriptionKey: "User denied"]
        )
        guard case .denied = SimulatorLiveStream.phase(for: error) else {
            return XCTFail("Expected denied phase")
        }
    }

    func testMissingWindowMapsToUnavailable() {
        let error = SimulatorLiveStreamError.noWindow(deviceName: "iPhone 17")
        guard case .unavailable = SimulatorLiveStream.phase(for: error) else {
            return XCTFail("Expected unavailable phase")
        }
    }

    func testWaitForWindowReturnsImmediatelyWhenPresent() async throws {
        let found = try await SimulatorLiveStream.waitForWindow(
            deviceName: "iPhone 17",
            attempts: 3,
            pause: .milliseconds(1)
        ) { _ in 42 }
        XCTAssertEqual(found, 42)
    }

    func testWaitForWindowRetriesUntilWindowAppears() async throws {
        final class CallCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func next() -> Int {
                lock.withLock {
                    value += 1
                    return value
                }
            }
            var count: Int {
                lock.withLock { value }
            }
        }
        let calls = CallCounter()
        let found = try await SimulatorLiveStream.waitForWindow(
            deviceName: "iPhone 17",
            attempts: 5,
            pause: .milliseconds(1)
        ) { _ in
            if calls.next() < 3 {
                throw SimulatorLiveStreamError.noWindow(deviceName: "iPhone 17")
            }
            return 7
        }
        XCTAssertEqual(found, 7)
        XCTAssertEqual(calls.count, 3)
    }

    func testWaitForWindowGivesUpWithLastError() async {
        do {
            _ = try await SimulatorLiveStream.waitForWindow(
                deviceName: "iPhone 17",
                attempts: 2,
                pause: .milliseconds(1)
            ) { _ in
                throw SimulatorLiveStreamError.noWindow(deviceName: "iPhone 17")
            }
            XCTFail("Expected noWindow error")
        } catch let error as SimulatorLiveStreamError {
            XCTAssertEqual(error, .noWindow(deviceName: "iPhone 17"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Hızlı başlangıç

    func testWaitPauseUsesFastStartForFirstAttempts() {
        // Üretim aralığında ilk 3 deneme hızlı koşar.
        XCTAssertEqual(
            SimulatorLiveStream.waitPause(attempt: 0, basePause: .milliseconds(750)),
            .milliseconds(150)
        )
        XCTAssertEqual(
            SimulatorLiveStream.waitPause(attempt: 2, basePause: .milliseconds(750)),
            .milliseconds(150)
        )
        // 4. denemeden sonra normal aralığa dönülür.
        XCTAssertEqual(
            SimulatorLiveStream.waitPause(attempt: 3, basePause: .milliseconds(750)),
            .milliseconds(750)
        )
    }

    func testWaitPauseKeepsCustomPauseForTests() {
        // Test aralığı hızlı başlangıçtan etkilenmez.
        XCTAssertEqual(
            SimulatorLiveStream.waitPause(attempt: 0, basePause: .milliseconds(1)),
            .milliseconds(1)
        )
    }

    func testWindowWaitBudgetKeepsTwentySeconds() {
        // Bütçe korunur: 3 × 150 ms + 26 × 750 ms ≈ 20 sn.
        let fastCount = SimulatorLiveStream.windowWaitFastAttempts
        let total = SimulatorLiveStream.windowWaitAttempts
        XCTAssertEqual(fastCount, 3)
        XCTAssertEqual(total, 29)
        let budgetMs = fastCount * 150 + (total - fastCount) * 750
        XCTAssertTrue(budgetMs >= 19000 && budgetMs <= 21000, "Bütçe ~20 sn olmalı")
    }

    // MARK: - Gizli pencere yedeği

    func testSelectIncludingHiddenAllowsOffScreenWindow() {
        let hidden = window(id: 9, onScreen: false)
        XCTAssertNil(SimulatorWindowSelector.select(deviceName: "iPhone 17", windows: [hidden]))
        XCTAssertEqual(
            SimulatorWindowSelector.selectIncludingHidden(deviceName: "iPhone 17", windows: [hidden])?.windowID,
            9
        )
    }

    func testResolveWindowIDPrefersOnScreen() {
        let onScreen = [window(id: 1, onScreen: true, area: 1000)]
        let all = [window(id: 2, onScreen: false, area: 4000)]
        XCTAssertEqual(
            SimulatorLiveStream.resolveWindowID(deviceName: "iPhone 17", onScreenWindows: onScreen, allWindows: all),
            1
        )
    }

    func testResolveWindowIDFallsBackToHidden() {
        let hidden = [window(id: 2, onScreen: false, area: 4000)]
        XCTAssertEqual(
            SimulatorLiveStream.resolveWindowID(deviceName: "iPhone 17", onScreenWindows: [], allWindows: hidden),
            2
        )
    }

    func testResolveWindowIDReturnsNilWithoutMatch() {
        XCTAssertNil(
            SimulatorLiveStream.resolveWindowID(deviceName: "iPhone 17", onScreenWindows: [], allWindows: [])
        )
        XCTAssertNil(
            SimulatorLiveStream.resolveWindowID(
                deviceName: "iPad",
                onScreenWindows: [window()],
                allWindows: [window()]
            )
        )
    }

    // MARK: - Kama bekçisi

    func testWedgeKeepsWhenRecentlyFramed() {
        XCTAssertEqual(
            SimulatorLiveStream.wedgeDecision(phase: .active, secondsSinceFrame: 1, didRestart: false),
            .keep
        )
    }

    func testWedgeKeepsWithoutFrameInfo() {
        XCTAssertEqual(
            SimulatorLiveStream.wedgeDecision(phase: .active, secondsSinceFrame: nil, didRestart: false),
            .keep
        )
    }

    func testWedgeRestartsOnceAfterStall() {
        // 3 sn sessizlikte tek yeniden başlatma denenir.
        XCTAssertEqual(
            SimulatorLiveStream.wedgeDecision(phase: .active, secondsSinceFrame: 3.5, didRestart: false),
            .restart
        )
    }

    func testWedgeGivesUpAfterSecondStall() {
        // İkinci sessizlikte `simctl` yedeğine düşülür.
        XCTAssertEqual(
            SimulatorLiveStream.wedgeDecision(phase: .active, secondsSinceFrame: 5, didRestart: true),
            .giveUp
        )
    }

    func testWedgeIgnoresNonActivePhase() {
        let stalled: TimeInterval = 10
        XCTAssertEqual(
            SimulatorLiveStream.wedgeDecision(phase: .starting, secondsSinceFrame: stalled, didRestart: false),
            .keep
        )
        XCTAssertEqual(
            SimulatorLiveStream.wedgeDecision(phase: .idle, secondsSinceFrame: stalled, didRestart: false),
            .keep
        )
        XCTAssertEqual(
            SimulatorLiveStream.wedgeDecision(
                phase: .unavailable(message: "kapalı"),
                secondsSinceFrame: stalled,
                didRestart: false
            ),
            .keep
        )
    }

    func testWedgeTimeoutIsThreeSeconds() {
        XCTAssertEqual(SimulatorLiveStream.wedgeTimeoutSeconds, 3, accuracy: 0.001)
    }

    func testWedgeUnavailableMessageIsActionable() {
        // İleti pencereyi açmaya yönlendirir ve yedeği söyler.
        let message = SimulatorLiveStream.wedgeUnavailableMessage.lowercased()
        XCTAssertTrue(message.contains("simctl"), "Yedek yol belirtilmeli")
        XCTAssertTrue(message.contains("simulator window"), "Pencere eylemi belirtilmeli")
    }

    // MARK: - LiveFrameMailbox

    final class ScheduleCounter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var value = 0
        func increment() {
            lock.withLock { value += 1 }
        }
    }

    func testMailboxSchedulesOnceAndDeliversLatest() {
        let mailbox = LiveFrameMailbox()
        let counter = ScheduleCounter()
        mailbox.store(tinyImage(gray: 10)) { counter.increment() }
        mailbox.store(tinyImage(gray: 20)) { counter.increment() }
        mailbox.store(tinyImage(gray: 30)) { counter.increment() }
        XCTAssertEqual(counter.value, 1, "Art arda kareler tek teslimat planlamalı")
        XCTAssertNotNil(mailbox.take(), "Bekleyen kare alınmalı")
        XCTAssertNil(mailbox.take(), "Kutu boşken nil dönmeli")
    }

    func testMailboxReschedulesAfterTake() {
        let mailbox = LiveFrameMailbox()
        let counter = ScheduleCounter()
        mailbox.store(tinyImage(gray: 1)) { counter.increment() }
        XCTAssertNotNil(mailbox.take())
        mailbox.store(tinyImage(gray: 2)) { counter.increment() }
        XCTAssertEqual(counter.value, 2, "Alımdan sonraki kare yeniden planlamalı")
    }

    func testMailboxCoalescesConcurrentStores() {
        let mailbox = LiveFrameMailbox()
        let counter = ScheduleCounter()
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            mailbox.store(self.tinyImage(gray: 7)) { counter.increment() }
        }
        XCTAssertEqual(counter.value, 1, "Eşzamanlı 100 kare tek teslimat planlamalı")
        XCTAssertNotNil(mailbox.take())
    }

    private func tinyImage(gray: UInt8) -> CGImage {
        let provider = CGDataProvider(data: Data([gray, gray, gray, 255]) as CFData)!
        return CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    // MARK: - İzin preflight (Ekran Kaydı yoksa 20 sn beklenmez)

    @MainActor
    func testStartSkipsWindowWaitWhenScreenCaptureDenied() async {
        let stream = SimulatorLiveStream(permissionReader: DenyingScreenCaptureReader())
        let started = Date()
        stream.start(deviceName: "iPhone 17 Pro")
        var phase = stream.phase
        let deadline = Date().addingTimeInterval(5)
        while (phase == .starting || phase == .idle) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            phase = stream.phase
        }
        XCTAssertEqual(phase, .denied(message: SimulatorLiveStream.permissionHint))
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            5,
            "Red, 20 sn'lik pencere beklemesine girmeden düşmeli"
        )
        stream.stop()
    }

    // MARK: - Pencere konuğu seçimi (yol > kayıt)

    func testPickWindowHostPrefersSimulatorAppPath() {
        let simURL = URL(fileURLWithPath: "/Xcode/Contents/Developer/Applications/Simulator.app")
        let hubURL = URL(fileURLWithPath: "/Xcode/Contents/Applications/DeviceHub.app")
        let picked = SimulatorService.pickWindowHost(
            simulatorAppURL: simURL,
            registered: [("com.apple.dt.Devices", hubURL)]
        )
        XCTAssertEqual(picked?.bundleIdentifier, "com.apple.iphonesimulator")
        XCTAssertEqual(picked?.url, simURL)
    }

    func testPickWindowHostFallsBackToFirstRegistered() {
        let hubURL = URL(fileURLWithPath: "/Xcode/Contents/Applications/DeviceHub.app")
        let picked = SimulatorService.pickWindowHost(
            simulatorAppURL: nil,
            registered: [("com.apple.dt.Devices", hubURL)]
        )
        XCTAssertEqual(picked?.bundleIdentifier, "com.apple.dt.Devices")
        XCTAssertEqual(picked?.url, hubURL)
    }

    func testPickWindowHostReturnsNilWhenEmpty() {
        XCTAssertNil(SimulatorService.pickWindowHost(simulatorAppURL: nil, registered: []))
    }
}

/// Ekran Kaydı reddini taklit eden okuyucu: preflight hızlı `.denied`
/// yolunu test eder, sistem istemi göstermez.
private struct DenyingScreenCaptureReader: ComputerUseAppPermissionReading {
    func permissions() -> ComputerUsePermissions {
        .denied
    }

    func requestScreenRecording() async -> Bool {
        false
    }
}
