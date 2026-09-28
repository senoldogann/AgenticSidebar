import CoreGraphics
import Foundation
import Synchronization
import XCTest

@testable import AgenticSidebar

/// Gerçek bir açık simülatörden framebuffer karesi okur. Açık cihaz yoksa
/// atlanır: CI'da simülatör yoktur, yerel makinede `xcrun simctl boot` ile
/// bir cihaz açıkken koşar.
final class SimulatorFramebufferSmokeTests: XCTestCase {
    private struct BootedList: Decodable {
        struct Entry: Decodable {
            let udid: String
            let state: String
        }

        let devices: [String: [Entry]]
    }

    private func bootedDeviceUDID() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "booted", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("simctl is unavailable (exit \(process.terminationStatus))")
        }
        let list = try JSONDecoder().decode(BootedList.self, from: data)
        guard let udid = list.devices.values.flatMap({ $0 }).first(where: { $0.state == "Booted" })?.udid else {
            throw XCTSkip("No booted simulator; boot one with `xcrun simctl boot <udid>` to run this test")
        }
        return udid
    }

    func testBootedSimulatorDeliversScreenOnlyFrames() async throws {
        let udid = try bootedDeviceUDID()
        let stream = SimulatorFramebufferStream()
        let frames = Mutex<[CGImage]>([])

        try await stream.start(
            udid: udid,
            maximumPixelSize: 1400,
            onFrame: { image in frames.withLock { $0.append(image) } },
            onEnded: {}
        )
        defer { stream.stop() }

        let deadline = Date().addingTimeInterval(5)
        while frames.withLock({ $0.isEmpty }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let first = try XCTUnwrap(frames.withLock { $0.first }, "no frame arrived within 5 s")

        // Yalnız cihaz ekranı: dikey, uzun kenar tavanda, pencere kromu yok
        // (DeviceHub penceresi yatay ve çok daha geniş olurdu).
        XCTAssertGreaterThan(first.height, first.width)
        XCTAssertLessThanOrEqual(max(first.width, first.height), 1400)
        XCTAssertGreaterThan(first.width, 200)
    }

    func testTargetSizeKeepsAspectAndNeverUpscales() {
        XCTAssertEqual(
            SimulatorFramebufferImage.targetSize(width: 1206, height: 2622, maximumPixelSize: 1400),
            SimulatorFramebufferImage.PixelSize(width: 644, height: 1400)
        )
        XCTAssertEqual(
            SimulatorFramebufferImage.targetSize(width: 600, height: 800, maximumPixelSize: 1400),
            SimulatorFramebufferImage.PixelSize(width: 600, height: 800)
        )
    }
}
