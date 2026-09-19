import Foundation
import XCTest

@testable import AgenticSidebar

/// Hedef kalıcılığı: tur atar, bozuk dosya paneli çökertmez, yarım koşu
/// güvenli faza indirgenerek devam eder.
final class GoalStoreTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("goal-run.json")
    }

    private func makeStored(phase: GoalPhase) -> GoalStoredRun {
        let run = GoalRun(
            id: UUID(),
            objective: "Hedef",
            criteria: [AcceptanceCriterion(id: UUID(), text: "ölçüt", isMet: false)],
            phase: phase,
            iteration: 2,
            startedAt: Date(timeIntervalSince1970: 2_000_000),
            toolCallCount: 7,
            log: [GoalLogEntry(date: Date(timeIntervalSince1970: 2_000_000), phase: .building, message: "x")],
            failureReason: nil
        )
        return GoalStoredRun(
            run: run,
            budget: GoalBudget(maxIterations: 5, maxDurationSeconds: 3_600, maxToolCalls: 300),
            sessionID: UUID(),
            speedMode: .normal,
            mode: .build,
            workingDirectoryPath: "/tmp",
            updatedAt: Date(timeIntervalSince1970: 2_000_001)
        )
    }

    func testRoundTripPreservesRun() throws {
        let url = temporaryURL()
        let stored = makeStored(phase: .building)
        try GoalStore.save(stored, to: url)
        XCTAssertEqual(GoalStore.load(from: url), stored)
    }

    func testMissingFileLoadsNil() {
        XCTAssertNil(GoalStore.load(from: temporaryURL()))
    }

    func testCorruptFileLoadsNil() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "bozuk-json{{{".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(GoalStore.load(from: url))
    }

    func testCorruptRunIsPreservedWhenAReplacementIsSaved() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("broken-goal-run{{{".utf8)
        try original.write(to: url)

        XCTAssertNil(GoalStore.load(from: url))
        try GoalStore.save(makeStored(phase: .building), to: url)

        let directory = url.deletingLastPathComponent()
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("goal-run.corrupt-") }
        XCTAssertEqual(quarantined.count, 1, "The replaced goal must retain one recoverable copy")
        guard let copy = quarantined.first else {
            return
        }
        XCTAssertEqual(try Data(contentsOf: copy), original)
        XCTAssertNotNil(GoalStore.load(from: url))
    }

    func testClearRemovesFile() throws {
        let url = temporaryURL()
        try GoalStore.save(makeStored(phase: .building), to: url)
        GoalStore.clear(url)
        XCTAssertNil(GoalStore.load(from: url))
    }

    func testResumableDemotesVerifyingToBuilding() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let resumed = GoalStore.resumableRun(from: makeStored(phase: .verifying), now: now)
        XCTAssertEqual(resumed?.run.phase, .building)
        XCTAssertEqual(resumed?.run.iteration, 2)
        XCTAssertEqual(resumed?.run.toolCallCount, 7)
        XCTAssertTrue(resumed?.run.log.last?.message.contains("re-verifying") ?? false)
    }

    func testResumableDemotesReviewingAndFixing() {
        let now = Date()
        XCTAssertEqual(
            GoalStore.resumableRun(from: makeStored(phase: .reviewing), now: now)?.run.phase,
            .building
        )
        XCTAssertEqual(
            GoalStore.resumableRun(from: makeStored(phase: .fixing), now: now)?.run.phase,
            .building
        )
    }

    func testResumableKeepsPausedAndPlanning() {
        let now = Date()
        XCTAssertEqual(
            GoalStore.resumableRun(from: makeStored(phase: .paused), now: now)?.run.phase,
            .paused
        )
        XCTAssertEqual(
            GoalStore.resumableRun(from: makeStored(phase: .planning), now: now)?.run.phase,
            .planning
        )
    }

    func testResumableRejectsTerminalRuns() {
        let now = Date()
        XCTAssertNil(GoalStore.resumableRun(from: makeStored(phase: .done), now: now))
        XCTAssertNil(GoalStore.resumableRun(from: makeStored(phase: .failed), now: now))
    }

    /// Paket dizini tercihi: kayıtlı yol aynen döner, boş/kayıtsız `nil`.
    func testPreferredPackageDirectoryRoundTrip() {
        let suiteName = "GoalStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        XCTAssertNil(GoalStore.preferredPackageDirectory(defaults: defaults))
        GoalStore.savePreferredPackageDirectory("/tmp/pkg", defaults: defaults)
        XCTAssertEqual(GoalStore.preferredPackageDirectory(defaults: defaults), "/tmp/pkg")
    }

    func testPreferredPackageDirectoryRejectsBlank() {
        let suiteName = "GoalStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        GoalStore.savePreferredPackageDirectory("   ", defaults: defaults)
        XCTAssertNil(GoalStore.preferredPackageDirectory(defaults: defaults))
    }
}
