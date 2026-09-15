import Darwin
import Foundation

struct OpenCodeProcessLaunchRequest: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryURL: URL
}

protocol OpenCodeProcessHandling: Sendable {
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

    func locate() -> URL? {
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
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
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

struct FoundationOpenCodeProcessLauncher: OpenCodeProcessLaunching {
    func launch(_ request: OpenCodeProcessLaunchRequest) async throws -> any OpenCodeProcessHandling {
        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            request.environment,
            uniquingKeysWith: { _, new in new }
        )

        do {
            try FileManager.default.createDirectory(
                at: request.workingDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw ProviderRuntimeError.startupFailure
        }
        process.currentDirectoryURL = request.workingDirectoryURL
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProviderRuntimeError.startupFailure
        }

        return FoundationOpenCodeProcessHandle(process: process)
    }
}

private actor FoundationOpenCodeProcessHandle: OpenCodeProcessHandling {
    private let process: Process

    init(process: Process) {
        self.process = process
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
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
