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
        // Başlık cihaz adını içerir, DeviceHub da geçerli sahibin parçasıdır.
        XCTAssertEqual(
            SimulatorWindowSelector.select(deviceName: "iPhone 17", windows: windows)?.windowID,
            3
        )
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
}
