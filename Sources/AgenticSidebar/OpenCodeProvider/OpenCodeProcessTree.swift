import Darwin
import Foundation

/// What a running process is, as far as the kernel will tell us.
struct RunningProcess: Equatable, Sendable {
    let pid: Int32
    let parent: Int32
    let executablePath: String?
}

/// Finds and ends the processes the backend spawns.
///
/// The backend is not one process. It starts every configured MCP server as its
/// own child, and those children are node, python and `uv` programs with their
/// own memory and their own connections. Terminating only the direct child left
/// all of them running — and because the app is routinely killed with a signal
/// that AppKit never sees (the development script's `pkill`, a system shutdown, a
/// crash), each relaunch added another whole tree. Thirty-six servers were found
/// alive on this machine, none of them owned by a running app.
///
/// Nothing here trusts a pid on its own: pids are reused, so a process is
/// identified by the arguments it is running with before it is signalled.
enum OpenCodeProcessTree {
    /// Every process on the system, read in two calls.
    static func snapshot() -> [RunningProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else {
            return []
        }

        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let written = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard written > 0 else {
            return []
        }

        let live = pids.prefix(Int(written)).filter { $0 > 0 }
        return live.compactMap { pid in
            var info = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.size
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
            }
            guard result == size else {
                return nil
            }

            return RunningProcess(
                pid: pid,
                parent: Int32(bitPattern: info.pbi_ppid),
                executablePath: executablePath(of: pid)
            )
        }
    }

    /// Every descendant of a process, children before parents.
    static func descendants(of processIdentifier: Int32) -> [Int32] {
        let processes = snapshot()
        var childrenByParent: [Int32: [Int32]] = [:]
        for process in processes {
            childrenByParent[process.parent, default: []].append(process.pid)
        }

        var ordered: [Int32] = []
        var queue: [Int32] = [processIdentifier]

        while let current = queue.first {
            queue.removeFirst()
            for child in childrenByParent[current] ?? [] where !ordered.contains(child) {
                ordered.append(child)
                queue.append(child)
            }
        }

        // Deepest first: a parent that exits can take its own children with it,
        // and signalling the child first makes the order irrelevant.
        return ordered.reversed()
    }

    /// Sends a signal to a process and everything below it.
    ///
    /// The list is built *before* anything is signalled: once the root exits its
    /// children are re-parented to `launchd`, and they can no longer be found by
    /// walking down from it.
    static func signalTree(
        rootedAt processIdentifier: Int32,
        signal signalNumber: Int32,
        includeRoot: Bool
    ) {
        for child in descendants(of: processIdentifier) {
            kill(child, signalNumber)
        }

        if includeRoot {
            kill(processIdentifier, signalNumber)
        }
    }

    static func isAlive(_ processIdentifier: Int32) -> Bool {
        guard processIdentifier > 0 else {
            return false
        }

        return kill(processIdentifier, 0) == 0
    }

    static func executablePath(of processIdentifier: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(processIdentifier, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return nil
        }

        return String(bytes: buffer.prefix(Int(length)), encoding: .utf8)
    }

    /// The arguments a process is running with.
    ///
    /// The kernel hands these over as one buffer: the argument count, the
    /// executable path, then `argc` NUL-terminated arguments.
    static func arguments(of processIdentifier: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, processIdentifier]
        var size = 0

        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        var argumentCount: Int32 = 0
        withUnsafeMutableBytes(of: &argumentCount) { destination in
            buffer.withUnsafeBytes { source in
                destination.copyBytes(from: source.prefix(MemoryLayout<Int32>.size))
            }
        }

        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 {
            index += 1
        }
        while index < size, buffer[index] == 0 {
            index += 1
        }

        var arguments: [String] = []
        while arguments.count < Int(argumentCount), index < size {
            var end = index
            while end < size, buffer[end] != 0 {
                end += 1
            }

            if let argument = String(bytes: buffer[index..<end], encoding: .utf8) {
                arguments.append(argument)
            }
            index = end + 1
        }

        return arguments.isEmpty ? nil : arguments
    }

    /// Whether a command line is one of the servers this app starts.
    ///
    /// The fingerprint is the exact argument shape the app launches with —
    /// including `--pure`, which is the app's own flag — so a server the user
    /// started themselves in a terminal is never mistaken for a leftover of ours.
    static func isManagedServerCommand(_ arguments: [String]) -> Bool {
        guard let serveIndex = arguments.firstIndex(of: "serve") else {
            return false
        }

        let tail = arguments[serveIndex...]
        return tail.contains("--hostname")
            && tail.contains("127.0.0.1")
            && tail.contains("--port")
            && tail.contains("--pure")
    }
}
