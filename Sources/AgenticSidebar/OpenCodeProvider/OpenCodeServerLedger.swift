import Foundation

/// One server this app started.
struct OpenCodeServerLease: Codable, Equatable, Sendable {
    let pid: Int32
    let port: UInt16
    let executablePath: String
    let startedAt: Date
}

/// What the sweep knows about a process before it decides anything.
struct OpenCodeProcessFacts: Equatable, Sendable {
    /// `nil` when nothing is running under this pid any more.
    var parent: Int32?
    var arguments: [String]?
    /// The launch environment, which carries the `OPENCODE_CONFIG` that proves
    /// the process is one of ours. `nil` is unreadable, and unreadable is a
    /// reason to leave a process alone.
    var environment: [String: String]?

    /// A process the kernel has re-parented to `launchd` belongs to no running
    /// app, which is what makes it a leftover rather than somebody's server.
    var isOrphaned: Bool {
        parent == 1
    }
}

/// The servers this app has started, written down so a launch that did not get
/// to clean up can be cleaned up by the next one.
///
/// A lease is recorded when a server starts and removed when it stops. What
/// makes this worth a file: the app is regularly killed with a signal AppKit
/// never delivers (`pkill` in the development script, a crash, a forced system
/// shutdown), and in those cases the server and its whole MCP tree outlive it.
/// Without a record, the next launch could only guess which `opencode` processes
/// were its own.
enum OpenCodeServerLedger {
    /// Where the leases live, inside the app's own managed directory.
    static func directoryURL(in workingDirectoryURL: URL) -> URL {
        workingDirectoryURL.appendingPathComponent("servers", isDirectory: true)
    }

    @discardableResult
    static func record(
        _ lease: OpenCodeServerLease,
        in workingDirectoryURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let directory = directoryURL(in: workingDirectoryURL)

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(lease)
            let leaseURL = fileURL(for: lease.pid, in: directory)
            try data.write(to: leaseURL, options: .atomic)
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: leaseURL.path
            )
            return true
        } catch {
            AppLog.openCode.error(
                "Could not record the OpenCode server lease: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    static func release(
        pid: Int32,
        in workingDirectoryURL: URL,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: fileURL(for: pid, in: directoryURL(in: workingDirectoryURL)))
    }

    static func leases(
        in workingDirectoryURL: URL,
        fileManager: FileManager = .default
    ) -> [OpenCodeServerLease] {
        let directory = directoryURL(in: workingDirectoryURL)
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        else {
            return []
        }

        return
            entries
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else {
                    return nil
                }
                return try? JSONDecoder().decode(OpenCodeServerLease.self, from: data)
            }
    }

    /// Ends every server this app started that no running app owns any more, and
    /// forgets the leases that no longer describe anything.
    ///
    /// Two sources, because one is not enough. The leases cover the ordinary case
    /// — the app was killed before it could stop its server, so the record is
    /// still on disk. The scan covers the case where the record was never written
    /// or has already been consumed: it looks for `opencode serve` processes
    /// running with this app's exact argument shape whose parent is `launchd`,
    /// which means no app can be their owner.
    ///
    /// A lease is only acted on when its process has been **orphaned** — its
    /// parent is `launchd`, which is what a process looks like after the app that
    /// started it died. A lease whose process still has a live parent belongs to
    /// an app that is running right now (a second copy, the development script),
    /// and ending it would break that copy: this sweep is for leftovers, not for
    /// whichever instance happens to launch second.
    ///
    /// The process facts are a parameter rather than a call: what a test cannot
    /// arrange is a real orphan of its own, and everything below the observation —
    /// the decision and the signal — is then exercised for real.
    ///
    /// The ledger pass is scoped to this app's own records and can be exercised in
    /// isolation; the scan looks at the whole process table. They are separable on
    /// purpose — a test may run the first and must not run the second, or the suite
    /// would clean up the machine it is running on. (It did: the orphaned servers
    /// were ended by a test run rather than by a launch, which is exactly the kind
    /// of side effect a test must not have.)
    ///
    /// - Returns: how many processes were signalled.
    @discardableResult
    static func reapOrphans(
        in workingDirectoryURL: URL,
        includeUnownedScan: Bool = true,
        fileManager: FileManager = .default,
        factsProvider: ([Int32]) -> [Int32: OpenCodeProcessFacts] = systemFacts(for:)
    ) -> Int {
        var killed = 0
        let recorded = leases(in: workingDirectoryURL, fileManager: fileManager)
        let facts = factsProvider(recorded.map(\.pid))

        for lease in recorded {
            defer {
                release(pid: lease.pid, in: workingDirectoryURL, fileManager: fileManager)
            }

            guard
                shouldReap(
                    lease,
                    facts: facts[lease.pid],
                    configurationPath:
                        ManagedOpenCodeConfiguration
                        .fileURL(in: workingDirectoryURL).path
                )
            else {
                continue
            }

            AppLog.openCode.info(
                "Stopping an OpenCode server left behind by an earlier launch (pid \(lease.pid, privacy: .public), port \(lease.port, privacy: .public))"
            )
            OpenCodeProcessTree.signalTree(
                rootedAt: lease.pid,
                signal: SIGKILL,
                includeRoot: true
            )
            killed += 1
        }

        if includeUnownedScan {
            killed += reapUnownedServers(
                excluding: [],
                configurationPath:
                    ManagedOpenCodeConfiguration
                    .fileURL(in: workingDirectoryURL).path
            )
        }

        return killed
    }

    /// Servers matching this app's launch fingerprint that are owned by nobody.
    ///
    /// A process whose parent is `launchd` has been orphaned: it cannot belong to
    /// a running app, because a running app is its parent. That is the whole
    /// reason this is safe to do at launch, and why the fingerprint requires the
    /// app's own `OPENCODE_CONFIG` — a server the user started in a terminal is
    /// not ours to kill.
    static func reapUnownedServers(
        excluding pids: Set<Int32>,
        configurationPath: String
    ) -> Int {
        let ownPid = getpid()
        var killed = 0

        for process in OpenCodeProcessTree.snapshot() {
            guard
                process.parent == 1,
                process.pid != ownPid,
                !pids.contains(process.pid),
                let invocation = OpenCodeProcessTree.invocation(of: process.pid),
                OpenCodeProcessTree.isManagedServer(
                    arguments: invocation.arguments,
                    environment: invocation.environment,
                    configurationPath: configurationPath
                )
            else {
                continue
            }

            AppLog.openCode.info(
                "Stopping an orphaned OpenCode server (pid \(process.pid, privacy: .public))"
            )
            OpenCodeProcessTree.signalTree(
                rootedAt: process.pid,
                signal: SIGKILL,
                includeRoot: true
            )
            killed += 1
        }

        return killed
    }

    /// Whether one lease describes a leftover server this launch should end.
    ///
    /// Pure, and that is the point: this is the rule the app's safety argument
    /// rests on, and it is checkable without a process table.
    static func shouldReap(
        _ lease: OpenCodeServerLease,
        facts: OpenCodeProcessFacts?,
        configurationPath: String
    ) -> Bool {
        // A pid is reused. "The pid in the file is alive" is not evidence that
        // the process is our server, and not even the lease is: the command line,
        // the launch environment and the parent are what answer.
        guard
            let facts,
            facts.isOrphaned,
            let arguments = facts.arguments,
            let environment = facts.environment
        else {
            return false
        }

        return OpenCodeProcessTree.isManagedServer(
            arguments: arguments,
            environment: environment,
            configurationPath: configurationPath
        ) && arguments.contains(String(lease.port))
    }

    /// The process facts the app uses, read in one pass over the process table.
    static func systemFacts(for pids: [Int32]) -> [Int32: OpenCodeProcessFacts] {
        guard !pids.isEmpty else {
            return [:]
        }

        let processes = OpenCodeProcessTree.snapshot()
        let parentByPid = Dictionary(
            processes.map { ($0.pid, $0.parent) },
            uniquingKeysWith: { first, _ in first }
        )

        var facts: [Int32: OpenCodeProcessFacts] = [:]
        for pid in pids {
            guard let parent = parentByPid[pid] else {
                facts[pid] = OpenCodeProcessFacts(
                    parent: nil,
                    arguments: nil,
                    environment: nil
                )
                continue
            }

            let invocation = OpenCodeProcessTree.invocation(of: pid)
            facts[pid] = OpenCodeProcessFacts(
                parent: parent,
                arguments: invocation?.arguments,
                environment: invocation?.environment
            )
        }

        return facts
    }

    private static func fileURL(for pid: Int32, in directory: URL) -> URL {
        directory.appendingPathComponent("\(pid).json")
    }
}
