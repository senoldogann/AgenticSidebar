import Foundation
import XCTest

@testable import AgenticSidebar

/// Cihaz-içi çökme yakalama: dosya adı, işaret dosyası, rapor biçimi.
///
/// Çıta: açılış işareti yazar, temiz çıkış siler; işaret duruyorsa önceki
/// çalış beklenmedik bitmiştir. Raporda transkript/pano içeriği yoktur.
final class CrashReporterTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("crash-reporter-tests-\(UUID().uuidString)", isDirectory: true)
    }

    func testInstallWritesMarkerAndCleanExitRemovesIt() {
        let directory = temporaryDirectory()
        let saved = CrashReporter.previousRunCrashedAtLaunch
        defer {
            CrashReporter.previousRunCrashedAtLaunch = saved
            try? FileManager.default.removeItem(at: directory)
        }

        CrashReporter.install(in: directory)
        // Taze dizinde önceki çökme yoktur; ama işaret yazılmış olmalıdır.
        XCTAssertEqual(CrashReporter.previousRunCrashedAtLaunch, false)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: CrashReporter.markerURL(in: directory).path
            )
        )

        CrashReporter.markCleanExit(in: directory)
        XCTAssertFalse(CrashReporter.previousRunCrashed(in: directory))
    }

    func testInstallCapturesPreExistingMarkerAsPreviousCrash() {
        let directory = temporaryDirectory()
        let saved = CrashReporter.previousRunCrashedAtLaunch
        defer {
            CrashReporter.previousRunCrashedAtLaunch = saved
            try? FileManager.default.removeItem(at: directory)
        }

        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try? "önceki çalış".write(
            to: CrashReporter.markerURL(in: directory),
            atomically: true,
            encoding: .utf8
        )

        CrashReporter.install(in: directory)
        XCTAssertEqual(CrashReporter.previousRunCrashedAtLaunch, true)
    }

    func testReportFilenameCarriesTimestampAndPID() {
        let name = CrashReporter.reportFilename(
            for: Date(timeIntervalSince1970: 1_700_000_000),
            processID: 4242
        )

        XCTAssertTrue(name.hasPrefix("crash-"))
        XCTAssertTrue(name.hasSuffix(".log"))
        XCTAssertTrue(name.contains("-4242-"))
    }

    func testExceptionReportCarriesNameReasonAndStack() {
        let text = CrashReporter.formatExceptionReport(
            name: "NSInvalidArgumentException",
            reason: "nil argüman",
            stack: ["0   App  0x0000000100003f10 main + 0"],
            appVersion: "1.0 (1)",
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertTrue(text.contains("NSInvalidArgumentException"))
        XCTAssertTrue(text.contains("nil argüman"))
        XCTAssertTrue(text.contains("1.0 (1)"))
        XCTAssertTrue(text.contains("main + 0"))
        XCTAssertFalse(text.lowercased().contains("transcript"))
    }

    func testSignalLineNamesSignal() {
        XCTAssertTrue(CrashReporter.signalLine(signal: SIGSEGV, date: Date()).contains("11"))
    }

    func testReportsListsNewestFirstAndPrunesOldest() {
        let directory = temporaryDirectory()
        let saved = CrashReporter.previousRunCrashedAtLaunch
        defer {
            CrashReporter.previousRunCrashedAtLaunch = saved
            try? FileManager.default.removeItem(at: directory)
        }
        CrashReporter.install(in: directory)

        for index in 0..<(CrashReporter.maximumReports + 3) {
            let url = directory.appendingPathComponent(
                CrashReporter.reportFilename(
                    for: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                    processID: Int32(1000 + index)
                )
            )
            try? "rapor \(index)".write(to: url, atomically: true, encoding: .utf8)
        }

        CrashReporter.install(in: directory)
        let reports = CrashReporter.reports(in: directory)

        XCTAssertEqual(reports.count, CrashReporter.maximumReports)
        XCTAssertTrue(reports.map(\.name) == reports.map(\.name).sorted(by: >))
        XCTAssertFalse(reports.map(\.name).contains { $0.contains("-1000-") })
    }
}
