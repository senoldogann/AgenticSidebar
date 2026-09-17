import Darwin
import Foundation
import XCTest
@testable import AgenticSidebar

/// The backend spawns a process per MCP server, and the app is routinely killed
/// with a signal AppKit never sees. These tests cover the two halves of not
/// leaving that tree behind: recognising a server this app started, and killing
/// the whole tree rather than just the process it launched.
final class OpenCodeProcessTreeTests: XCTestCase {
    func testOnlyThisAppsLaunchShapeCountsAsAManagedServer() {
        XCTAssertTrue(
            OpenCodeProcessTree.isManagedServerCommand([
                "serve", "--hostname", "127.0.0.1", "--port", "59021", "--pure"
            ])
        )

        XCTAssertFalse(
            OpenCodeProcessTree.isManagedServerCommand(["serve", "--port", "41231"]),
            "A server started by hand in a terminal is not the app's to kill"
        )

        XCTAssertFalse(
            OpenCodeProcessTree.isManagedServerCommand([
                "serve", "--hostname=127.0.0.1", "--port=60848"
            ]),
            "The flag order and syntax the app writes are part of the fingerprint"
        )

        XCTAssertFalse(OpenCodeProcessTree.isManagedServerCommand(["serve"]))
        XCTAssertFalse(OpenCodeProcessTree.isManagedServerCommand([]))
        XCTAssertFalse(
            OpenCodeProcessTree.isManagedServerCommand([
                "auth", "login", "--hostname", "127.0.0.1", "--port", "1", "--pure"
            ]),
            "Only a server is ever signalled"
        )
    }

    func testItReadsTheArgumentsOfARunningProcess() throws {
        let arguments = try XCTUnwrap(
            OpenCodeProcessTree.arguments(of: getpid()),
            "A process must be able to inspect itself"
        )

        XCTAssertFalse(arguments.isEmpty)
        XCTAssertTrue(
            arguments.contains { $0.contains("AgenticSidebar") },
            "Expected the test runner's own path in \(arguments.prefix(3))"
        )
    }

    func testItFindsTheChildrenOfAProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let childPID = process.processIdentifier
        XCTAssertTrue(
            OpenCodeProcessTree.descendants(of: getpid()).contains(childPID),
            "A child that cannot be found cannot be stopped with the app"
        )

        OpenCodeProcessTree.signalTree(rootedAt: childPID, signal: SIGKILL, includeRoot: true)
        process.waitUntilExit()
        XCTAssertFalse(OpenCodeProcessTree.isAlive(childPID))
    }
}

final class OpenCodeServerLedgerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgenticSidebarLedgerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testALeaseIsRecordedAndForgotten() {
        let lease = OpenCodeServerLease(
            pid: 4242,
            port: 59021,
            executablePath: "/opt/homebrew/bin/opencode",
            startedAt: Date()
        )

        XCTAssertTrue(OpenCodeServerLedger.record(lease, in: directory))
        XCTAssertEqual(OpenCodeServerLedger.leases(in: directory), [lease])

        let leaseURL = OpenCodeServerLedger.directoryURL(in: directory)
            .appendingPathComponent("\(lease.pid).json")
        let permissions = (try? FileManager.default.attributesOfItem(atPath: leaseURL.path)[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertEqual(permissions, 0o600, "kira dosyası yalnız sahibine okunur olmalı")

        OpenCodeServerLedger.release(pid: lease.pid, in: directory)
        XCTAssertTrue(OpenCodeServerLedger.leases(in: directory).isEmpty)
    }

    /// A lease is not a licence to kill: the recorded process also has to look
    /// like our server. Here the recorded pid is this very test — alive,
    /// definitely not an OpenCode server, and with a live parent on top.
    func testReapingNeverKillsAProcessThatIsNotAServerWeStarted() {
        let lease = OpenCodeServerLease(
            pid: getpid(),
            port: 59021,
            executablePath: "/bin/true",
            startedAt: Date()
        )
        XCTAssertTrue(OpenCodeServerLedger.record(lease, in: directory))

        OpenCodeServerLedger.reapOrphans(
            in: directory,
            // The whole-process-table scan is the app's job at launch. A test that
            // ran it would clean up the machine it is running on.
            includeUnownedScan: false
        )

        XCTAssertTrue(
            OpenCodeProcessTree.isAlive(getpid()),
            "The app must not kill by pid alone"
        )
        XCTAssertTrue(
            OpenCodeServerLedger.leases(in: directory).isEmpty,
            "A lease that no longer describes a server is forgotten, not retried"
        )
    }

    /// The decision table. This is the rule the app's safety argument rests on, and
    /// every branch of it is checkable without a process table.
    func testTheReapDecision() {
        let lease = OpenCodeServerLease(
            pid: 9001,
            port: 59021,
            executablePath: "/opt/homebrew/bin/opencode",
            startedAt: Date()
        )
        let serverArguments = ["serve", "--hostname", "127.0.0.1", "--port", "59021", "--pure"]

        XCTAssertTrue(
            OpenCodeServerLedger.shouldReap(
                lease,
                facts: OpenCodeProcessFacts(parent: 1, arguments: serverArguments)
            ),
            "An orphaned server this app started is exactly a leftover"
        )

        XCTAssertFalse(
            OpenCodeServerLedger.shouldReap(
                lease,
                facts: OpenCodeProcessFacts(parent: 4242, arguments: serverArguments)
            ),
            "A server a running app still owns must survive a launch's leftover sweep"
        )

        XCTAssertFalse(
            OpenCodeServerLedger.shouldReap(
                lease,
                facts: OpenCodeProcessFacts(
                    parent: 1,
                    arguments: ["serve", "--hostname", "127.0.0.1", "--port", "59022", "--pure"]
                )
            ),
            "A different port is a different server"
        )

        XCTAssertFalse(
            OpenCodeServerLedger.shouldReap(
                lease,
                facts: OpenCodeProcessFacts(parent: 1, arguments: ["serve", "--port", "59021"])
            ),
            "A server the user started by hand is not the app's to kill"
        )

        XCTAssertFalse(
            OpenCodeServerLedger.shouldReap(
                lease,
                facts: OpenCodeProcessFacts(parent: 1, arguments: nil)
            ),
            "An unreadable command line is a reason to leave the process alone"
        )

        XCTAssertFalse(
            OpenCodeServerLedger.shouldReap(lease, facts: nil),
            "A pid that is gone is not a server"
        )
    }

    /// The observation is injected because a test cannot arrange a real orphan of
    /// its own; everything below it is real, including the signal.
    func testAReapEndsAServerRecordedInALease() async throws {
        // A real process whose arguments have the app's launch shape. What the
        // reaper decides on is the command line and the parent, so that is what the
        // fixture has to reproduce; `yes` simply stays alive and ignores its
        // arguments.
        let process = try launchManagedLookingProcess()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let pid = process.processIdentifier
        let lease = OpenCodeServerLease(
            pid: pid,
            port: 59021,
            executablePath: "/opt/homebrew/bin/opencode",
            startedAt: Date()
        )
        XCTAssertTrue(OpenCodeServerLedger.record(lease, in: directory))
        XCTAssertTrue(OpenCodeProcessTree.isAlive(pid))

        OpenCodeServerLedger.reapOrphans(
            in: directory,
            // The whole-process-table scan is the app's job at launch. A test that
            // ran it would clean up the machine it is running on.
            includeUnownedScan: false,
            factsProvider: { _ in
                [pid: OpenCodeProcessFacts(parent: 1, arguments: OpenCodeProcessTree.arguments(of: pid))]
            }
        )

        // The signal is `SIGKILL`, so the child is dead by the time `reapOrphans`
        // returns — but it stays a zombie until its parent reaps it, and `kill(pid,
        // 0)` answers for a zombie too. `Process.isRunning` is the honest signal; it
        // is polled rather than awaited so a reaper that stopped doing its job
        // fails this test in seconds instead of hanging it.
        let exited = await waitUntil(timeout: .seconds(3)) { !process.isRunning }
        defer { process.waitUntilExit() }

        XCTAssertTrue(exited, "A recorded server without an owner has to be stopped")
        XCTAssertTrue(OpenCodeServerLedger.leases(in: directory).isEmpty)
    }

    /// The same fixture with an honest parent: this is what the app sees for a
    /// server a second copy of itself is still using, and it must survive.
    func testAReapLeavesAServerThatStillHasALiveParentAlone() throws {
        let process = try launchManagedLookingProcess()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let pid = process.processIdentifier
        let lease = OpenCodeServerLease(
            pid: pid,
            port: 59021,
            executablePath: "/opt/homebrew/bin/opencode",
            startedAt: Date()
        )
        XCTAssertTrue(OpenCodeServerLedger.record(lease, in: directory))

        // The real lookup, so the guard is the one the app runs.
        let facts = OpenCodeServerLedger.systemFacts(for: [pid])
        XCTAssertEqual(facts[pid]?.parent, getpid(), "The fixture is a child of this test")
        XCTAssertNotEqual(facts[pid]?.parent, 1)

        OpenCodeServerLedger.reapOrphans(in: directory, includeUnownedScan: false)

        XCTAssertTrue(
            process.isRunning,
            "A server a running app still owns must survive a launch's leftover sweep"
        )
        XCTAssertTrue(
            OpenCodeServerLedger.leases(in: directory).isEmpty,
            "The record is still forgotten once the pass has looked at it"
        )
    }

    private func waitUntil(
        timeout: Duration,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)

        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        return condition()
    }

    private func launchManagedLookingProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        process.arguments = ["serve", "--hostname", "127.0.0.1", "--port", "59021", "--pure"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}
