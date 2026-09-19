import Foundation

enum CapabilityEligibilityResult: Sendable, Equatable {
    case supported(CodingAgentCapabilities)
    case runtimeNotFound(String)
    case missingCapabilities(missing: [String], available: CodingAgentCapabilities)

    var isSupported: Bool {
        if case .supported = self {
            return true
        }
        return false
    }
}

final class CodingAgentRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var runtimes: [String: CodingAgentRuntime] = [:]

    init() {}

    func register(runtime: CodingAgentRuntime) {
        lock.lock()
        defer { lock.unlock() }
        runtimes[runtime.runtimeID] = runtime
    }

    func unregister(runtimeID: String) {
        lock.lock()
        defer { lock.unlock() }
        runtimes.removeValue(forKey: runtimeID)
    }

    func runtime(for id: String) -> CodingAgentRuntime? {
        lock.lock()
        defer { lock.unlock() }
        return runtimes[id]
    }

    func checkEligibility(
        runtimeID: String,
        configuration: SessionConfiguration,
        required: CodingAgentCapabilities
    ) async -> CapabilityEligibilityResult {
        let candidate = {
            lock.lock()
            defer { lock.unlock() }
            return runtimes[runtimeID]
        }()

        guard let candidate else {
            return .runtimeNotFound(runtimeID)
        }

        let available = await candidate.capabilities(configuration: configuration)
        let missing = available.missing(from: required)

        if missing.isEmpty {
            return .supported(available)
        } else {
            return .missingCapabilities(missing: missing, available: available)
        }
    }

    func eligible(
        runtimeID: String,
        configuration: SessionConfiguration,
        required: CodingAgentCapabilities
    ) async -> CapabilityEligibilityResult {
        await checkEligibility(
            runtimeID: runtimeID,
            configuration: configuration,
            required: required
        )
    }
}
