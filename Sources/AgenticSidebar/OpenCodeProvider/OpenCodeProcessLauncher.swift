import Darwin
import Foundation

struct OpenCodeProcessLaunchRequest: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryURL: URL
    /// Sunucu günlüğünün yazılacağı dizin. Sohbet sunucusunda çalışma diziniyle
    /// aynıdır; çalışma alanına köklenmiş sunucularda çalışma dizini sahipli
    /// çalışma kopyasıdır ve günlük durum ad alanına düşer — çalışma kopyasına
    /// `opencode-server.log` yazmak izlenmeyen dosya olarak parmak izini bozar.
    let logDirectoryURL: URL
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
            "/usr/local/bin/opencode",
        ]

        if let path = environment["PATH"] {
            candidates.append(
                contentsOf:
                    path
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

    /// Tek seferlik sahiplik denetimi: parola taşıyan her istekten önce
    /// portun hâlâ çocuğa ait olduğu doğrulanır. Varsayılan `true` döner;
    /// gerçek denetim `LibprocListenerVerifier` içindedir.
    func processOwnsListeningPort(
        _ port: UInt16,
        processIdentifier: Int32?
    ) -> Bool
}

extension OpenCodeListenerVerifying {
    func processOwnsListeningPort(
        _ port: UInt16,
        processIdentifier: Int32?
    ) -> Bool {
        true
    }
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

    func processOwnsListeningPort(
        _ port: UInt16,
        processIdentifier: Int32?
    ) -> Bool {
        guard let processIdentifier, processIdentifier > 0 else {
            return false
        }
        return Self.listeningPorts(of: processIdentifier).contains(port)
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
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME",
    ]

    static func childEnvironment(overrides: [String: String]) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]

        for key in inheritedEnvironmentKeys {
            environment[key] = parent[key]
        }

        let home = parent["HOME"] ?? ("~" as NSString).expandingTildeInPath
        var paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidateDirectories = [
            home + "/.volta/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            home + "/.bun/bin",
            home + "/.cargo/bin",
            home + "/.local/bin",
            home + "/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        for dir in candidateDirectories {
            if FileManager.default.fileExists(atPath: dir) && !paths.contains(dir) {
                paths.append(dir)
            }
        }
        environment["PATH"] = paths.joined(separator: ":")

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
        // Its own log is truncated on every start and capped at shutdown
        // (`capServerLogIfNeeded`), so it cannot grow without bound.
        // Günlük çalışma dizinine değil isteğin günlük dizinine düşer: kök
        // çalışma alanındayken çalışma kopyası sahiplidir ve kirletilemez.
        let logURL = FileHandle.serverLogURL(in: request.logDirectoryURL)
        let logHandle = FileHandle.openTruncatedLog(at: request.logDirectoryURL)
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw ProviderRuntimeError.startupFailure
        }

        return FoundationOpenCodeProcessHandle(
            process: process,
            logHandle: logHandle === FileHandle.nullDevice ? nil : logHandle,
            logURL: logURL
        )
    }
}

extension FileHandle {
    /// Sunucu günlüğünün tavanı: 5 MB üstünde kuyruk tutulur (son yarısı),
    /// başına kesme notu yazılır.
    static let maximumServerLogBytes = 5 * 1024 * 1024

    static func serverLogURL(in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent("opencode-server.log")
    }

    /// Günlük tavanını uygular: dosya 5 MB'ı aştıysa son yarısı tutulur.
    /// Çocuk öldükten sonra çağrılmalıdır; yazma ucu kapalıdır, atomik
    /// yeniden yazım güvenlidir.
    static func capServerLogIfNeeded(
        at logURL: URL,
        maximumBytes: Int = maximumServerLogBytes
    ) {
        guard
            let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber)?.intValue,
            size > maximumBytes
        else {
            return
        }
        guard let readHandle = try? FileHandle(forReadingFrom: logURL) else {
            return
        }
        defer { try? readHandle.close() }
        do {
            let keepBytes = max(1, maximumBytes / 2)
            try readHandle.seek(toOffset: UInt64(max(0, size - keepBytes)))
            var tail = try readHandle.readToEnd() ?? Data()
            // Kuyruk satır ortasından kesilmesin: ilk satır sonuna kadar atlanır.
            if let newline = tail.firstIndex(of: 0x0A) {
                tail = tail[tail.index(after: newline)...]
            }
            var capped = Data("... [truncated: log exceeded 5MB, kept the tail]\n".utf8)
            capped.append(tail)
            try capped.write(to: logURL, options: .atomic)
        } catch {
            AppLog.openCode.error(
                "Could not cap the OpenCode server log: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Opens the backend's log inside the managed directory, truncated, falling
    /// back to the null device when the file cannot be created.
    static func openTruncatedLog(at directoryURL: URL) -> FileHandle {
        let logURL = serverLogURL(in: directoryURL)
        let header = Data("OpenCode server log; truncated on every start\n".utf8)

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try header.write(to: logURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: logURL.path
            )
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
    private var logHandle: FileHandle?
    private let logURL: URL?

    init(process: Process, logHandle: FileHandle? = nil, logURL: URL? = nil) {
        self.process = process
        self.logHandle = logHandle
        self.logURL = logURL
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

    /// Ends the child **and everything it started**.
    ///
    /// The child is a backend that spawns a process per configured MCP server, so
    /// stopping it used to leave a node/python tree behind — invisible, holding
    /// memory, and (after a crash or a signal the app never saw) adding a second
    /// copy of itself on the next launch.
    func terminate() async {
        let pid = process.processIdentifier
        guard pid > 0 else {
            return
        }

        // Collected before anything is signalled: once the child exits, its
        // children are re-parented to `launchd` and can no longer be found by
        // walking down from it. So the tree is asked to stop *first*, while it can
        // still be enumerated, and the list is refreshed once more before the root
        // goes — a child that is shutting down can spawn on its way out.
        var knownDescendants = OpenCodeProcessTree.descendants(of: pid)
        for descendant in knownDescendants {
            kill(descendant, SIGTERM)
        }

        try? await Task.sleep(for: .milliseconds(100))
        knownDescendants.append(contentsOf: OpenCodeProcessTree.descendants(of: pid))

        if process.isRunning {
            process.terminate()
        }

        for _ in 0..<20 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }

        if process.isRunning {
            AppLog.openCode.error(
                "OpenCode child did not exit after SIGTERM; sending SIGKILL"
            )
            kill(pid, SIGKILL)
        }

        for descendant in Set(knownDescendants) where OpenCodeProcessTree.isAlive(descendant) {
            kill(descendant, SIGKILL)
        }

        // Ebeveyndeki yazma ucu kapatılmazsa sunucu yeniden başlatma başına
        // bir fd sızardı; çocuk zaten öldü, log burada kapanır ve tavan
        // uygulanır (yazma ucu kapalı, yeniden yazım güvenli).
        try? logHandle?.close()
        logHandle = nil
        if let logURL {
            FileHandle.capServerLogIfNeeded(at: logURL)
        }
    }
}
