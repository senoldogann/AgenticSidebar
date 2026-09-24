import Foundation
import XCTest

@testable import AgenticSidebar

final class SimulatorDeviceListTests: XCTestCase {
    /// `simctl` çalışma zamanı kimliğini okunur adına çevirir.
    func testRuntimeDisplayName() {
        XCTAssertEqual(
            SimulatorDeviceListParser.runtimeDisplayName(
                fromIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
            ),
            "iOS 26.5"
        )
        XCTAssertEqual(
            SimulatorDeviceListParser.runtimeDisplayName(
                fromIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-26-5"
            ),
            "watchOS 26.5"
        )
        XCTAssertEqual(
            SimulatorDeviceListParser.runtimeDisplayName(fromIdentifier: "custom-runtime"),
            "custom-runtime"
        )
    }

    /// Yalnız kullanılabilir iPhone cihazları gelir; koşan cihaz başta durur.
    func testDevicesFilterAndOrder() throws {
        let json = """
            {
              "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                  {
                    "udid": "AAAA",
                    "name": "iPhone 17 Pro",
                    "state": "Shutdown",
                    "isAvailable": true,
                    "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
                  },
                  {
                    "udid": "BBBB",
                    "name": "iPhone 16",
                    "state": "Booted",
                    "isAvailable": true,
                    "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16"
                  }
                ],
                "com.apple.CoreSimulator.SimRuntime.watchOS-26-5": [
                  {
                    "udid": "CCCC",
                    "name": "Apple Watch Series 11",
                    "state": "Shutdown",
                    "isAvailable": true,
                    "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11"
                  }
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
                  {
                    "udid": "DDDD",
                    "name": "iPhone 17 Pro",
                    "state": "Shutdown",
                    "isAvailable": false,
                    "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
                  }
                ]
              }
            }
            """

        let devices = SimulatorDeviceListParser.devices(fromJSON: Data(json.utf8))

        XCTAssertEqual(devices.map(\.id), ["BBBB", "AAAA"])
        XCTAssertEqual(devices.first?.runtimeName, "iOS 26.5")
        XCTAssertTrue(devices.first?.isBooted == true)
    }

    /// Yeni çalışma zamanı eskiyi geçer: aynı adlı cihazda iOS 26.5 önce gelir.
    func testNewerRuntimeSortsFirst() {
        let json = """
            {
              "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
                  {
                    "udid": "OLD",
                    "name": "iPhone 17 Pro",
                    "state": "Shutdown",
                    "isAvailable": true,
                    "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
                  }
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                  {
                    "udid": "NEW",
                    "name": "iPhone 17 Pro",
                    "state": "Shutdown",
                    "isAvailable": true,
                    "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
                  }
                ]
              }
            }
            """

        let devices = SimulatorDeviceListParser.devices(fromJSON: Data(json.utf8))

        XCTAssertEqual(devices.map(\.id), ["NEW", "OLD"])
    }

    /// Bozuk çıktı cihaz uydurmaz.
    func testMalformedJSONYieldsNoDevices() {
        XCTAssertEqual(
            SimulatorDeviceListParser.devices(fromJSON: Data("not json".utf8)),
            []
        )
    }

    /// Cihaz tipi alanı yoksa ad üzerinden iPhone olduğu anlaşılır.
    func testDeviceTypeFallsBackToName() {
        let json = """
            {
              "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                  {
                    "udid": "AAAA",
                    "name": "iPhone 17e",
                    "state": "Shutdown"
                  },
                  {
                    "udid": "BBBB",
                    "name": "iPad Pro",
                    "state": "Shutdown"
                  }
                ]
              }
            }
            """

        let devices = SimulatorDeviceListParser.devices(fromJSON: Data(json.utf8))

        XCTAssertEqual(devices.map(\.id), ["AAAA"])
    }
}
