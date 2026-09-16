import Darwin
import Foundation

struct OpenCodeProcessLaunchRequest: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryURL: URL
}

protocol OpenCodeProcessHandling: Sendable {
    /// Whether the managed child process is still alive. Used to detect a crashed
    /// server instead of trusting the last known connection state.
    func isRunning() async -> Bool
    /// The child's pid, or `nil` when it is no longer running. Used to prove that
    /// the loopback port belongs to this child before the server password is sent
    /// to it (see ``OpenCodeListenerVerifying``).
    func processIdentifier() async -> Int32?
    func terminate() async
}

protocol OpenCodeProcessLaunching: Sendable {
    func launch(_ request: OpenCodeProcessLaunchRequest) async throws -> any OpenCodeProcessHandling
}

struct SystemOpenCodeExecutableLocator: OpenCodeExecutableLocating {
    private let environment: [String: String]

    init(environment: [String: String]) {
        self.environment = environment
    }

    static func current() -> Self {
        Self(environment: ProcessInfo.processInfo.environment)
    }

    func resolution() -> OpenCodeExecutableResolution {
        var candidates = [
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode"
        ]

        if let path = environment["PATH"] {
            candidates.append(
                contentsOf: path
                    .split(separator: ":")
                    .map { String($0) + "/opencode" }
            )
        }

        let fileManager = FileManager.default
        guard
            let candidate = candidates.first(where: {
                fileManager.isExecutableFile(atPath: $0)
            })
        else {
            return .notFound
        }

        return Self.trust(of: URL(fileURLWithPath: candidate))
    }

    /// Whether the binary about to be launched with the server password in its
    /// environment is one the user actually controls.
    ///
    /// Nothing verified this before: the search puts `/usr/local/bin` ahead of the
    /// user's own `PATH`, and a world-writable file dropped there would be executed
    /// with the app's privileges and its whole (then inherited) environment. The
    /// check is on the file that will really run — Homebrew's `opencode` is a
    /// symlink into the Cellar — and a refusal is reported rather than silently
    /// falling through to a different binary.
    static func trust(of url: URL) -> OpenCodeExecutableResolution {
        let resolved = url.resolvingSymlinksInPath()
        let attributes: [FileAttributeKey: Any]

        do {
            attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        } catch {
            return .untrusted(
                path: resolved.path,
                reason: "its permissions could not be read"
            )
        }

        if let type = attributes[.type] as? FileAttributeType, type != .typeRegular {
            return .untrusted(path: resolved.path, reason: "it is not a regular file")
        }

        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        if permissions & 0o022 != 0 {
            return .untrusted(
                path: resolved.path,
                reason: "it is writable by other users, so another account could replace it"
            )
        }

        if let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
           ownerID != 0,
           ownerID != getuid()
        {
            return .untrusted(
                path: resolved.path,
                reason: "it is owned by another user"
            )
        }

        return .found(resolved)
    }
}

struct SystemOpenCodePortAllocator: OpenCodePortAllocating {
    func allocate() throws -> UInt16 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ProviderRuntimeError.startupFailure
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else {
            throw ProviderRuntimeError.startupFailure
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.getsockname(descriptor, socketAddress, &boundLength)
            }
        }
        guard nameResult == 0 else {
            throw ProviderRuntimeError.startupFailure
        }

        return UInt16(bigEndian: boundAddress.sin_port)
    }
}

/// Proves that the process listening on the loopback port is the child we spawned.
///
/// The port is discovered by binding port 0 and reading the number, then the
/// socket is closed so the child can bind it. In the window between those two
/// events any local process can take the port, and the app's next request carries
/// `Basic` credentials the child was given. The health check only asks for
/// `{"healthy":true}`, so an impostor answering plausibly would receive the
/// password and could then drive the OpenCode HTTP API — with the app's own
/// transcript attributing whatever it ran to the user's agent.
///
/// Checking the child's own file descriptors closes that window without changing
/// the protocol: the server password is only ever sent after this returns `true`.
protocol OpenCodeListenerVerifying: Sendable {
    func waitUntilProcessOwnsListeningPort(
        _ port: UInt16,
        processIdentifier: Int32?
    ) async -> Bool
}

struct LibprocListenerVerifier: OpenCodeListenerVerifying {
    private let attempts: Int
    private let delay: Duration

    init(attempts: Int = 40, delay: Duration = .milliseconds(100)) {
        self.attempts = attempts
        self.delay = delay
    }

    func waitUntilProcessOwnsListeningPort(
        _ port: UInt16,
        processIdentifier: Int32?
    ) async -> Bool {
        guard let processIdentifier, processIdentifier > 0 else {
            return false
        }

        for attempt in 0..<attempts {
            if Self.listeningPorts(of: processIdentifier).contains(port) {
                return true
            }

            if attempt + 1 < attempts {
                try? await Task.sleep(for: delay)
            }
        }

        return false
    }

    /// The TCP ports this pid is listening on, read from its own descriptors.
    ///
    /// `libproc` rather than a shelled-out `lsof`: no subprocess, no parsing of
    /// text another process could influence, and it is the same information the
    /// kernel has about the socket.
    static func listeningPorts(of processIdentifier: Int32) -> [UInt16] {
        let bufferSize = proc_pidinfo(processIdentifier, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else {
            return []
        }

        let capacity = Int(bufferSize) / MemoryLayout<proc_fdinfo>.size
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let written = proc_pidinfo(
            processIdentifier,
            PROC_PIDLISTFDS,
            0,
            &descriptors,
            bufferSize
        )
        guard written > 0 else {
            return []
        }

        var ports: [UInt16] = []
        for descriptor in descriptors.prefix(Int(written) / MemoryLayout<proc_fdinfo>.size) {
            guard descriptor.proc_fdtype == PROX_FDTYPE_SOCKET else {
                continue
            }

            var socket = socket_fdinfo()
            let size = MemoryLayout<socket_fdinfo>.size
            let result = withUnsafeMutablePointer(to: &socket) { pointer in
                proc_pidfdinfo(
                    processIdentifier,
                    descriptor.proc_fd,
                    PROC_PIDFDSOCKETINFO,
                    pointer,
                    Int32(size)
                )
            }
            guard result == size else {
                continue
            }
            guard
                socket.psi.soi_family == AF_INET,
                socket.psi.soi_kind == SOCKINFO_TCP,
                socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
            else {
                continue
            }

            // `libproc` reports the port in network byte order.
            ports.append(
                UInt16(
                    bigEndian: UInt16(
                        truncatingIfNeeded: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport
                    )
                )
            )
        }

        return ports
    }
}

struct FoundationOpenCodeProcessLauncher: OpenCodeProcessLaunching {
    /// The variables the backend genuinely needs.
    ///
    /// Everything else the app's process holds — API tokens the user exported for
    /// their shell, proxy or cloud credentials — used to be inherited by the child
    /// and therefore readable by every plugin and MCP server it spawns. Provider
    /// credentials do not travel this way: the app forwards those through
    /// OpenCode's own auth API.
    static let inheritedEnvironmentKeys = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL",
        "TMPDIR", "TMP", "LANG", "LC_ALL",
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"
    ]

    static func childEnvironment(overrides: [String: String]) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]

        for key in inheritedEnvironmentKeys {
            environment[key] = parent[key]
        }

        environment.merge(overrides, uniquingKeysWith: { _, new in new })
        return environment
    }

    func launch(_ request: OpenCodeProcessLaunchRequest) async throws -> any OpenCodeProcessHandling {
        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = Self.childEnvironment(overrides: request.environment)

        do {
            try FileManager.default.createDirectory(
                at: request.workingDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw ProviderRuntimeError.startupFailure
        }
        process.currentDirectoryURL = request.workingDirectoryURL
        // `/dev/null` meant a child that died on startup left nothing to read.
        // Its own log is truncated on every start, so it cannot grow without bound.
        let logHandle = FileHandle.openTruncatedLog(at: request.workingDirectoryURL)
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            throw ProviderRuntimeError.startupFailure
        }

        return FoundationOpenCodeProcessHandle(process: process)
    }
}

extension FileHandle {
    /// Opens the backend's log inside the managed directory, truncated, falling
    /// back to the null device when the file cannot be created.
    static func openTruncatedLog(at directoryURL: URL) -> FileHandle {
        let logURL = directoryURL.appendingPathComponent("opencode-server.log")
        let header = Data("OpenCode server log; truncated on every start\n".utf8)

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try header.write(to: logURL, options: .atomic)
        } catch {
            AppLog.openCode.error(
                "Could not open the OpenCode server log: \(error.localizedDescription, privacy: .public)"
            )
            return .nullDevice
        }

        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            return .nullDevice
        }

        handle.seekToEndOfFile()
        return handle
    }
}

private actor FoundationOpenCodeProcessHandle: OpenCodeProcessHandling {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    func isRunning() -> Bool {
        process.isRunning
    }

    func processIdentifier() -> Int32? {
        guard process.isRunning else {
            return nil
        }

        return process.processIdentifier
    }

    func terminate() async {
        guard process.isRunning else {
            return
        }

        process.terminate()
        for _ in 0..<20 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }

        if process.isRunning {
            AppLog.openCode.error(
                "OpenCode child did not exit after SIGTERM; sending SIGKILL"
            )
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
