import Foundation

struct CodingAgentCapabilities: OptionSet, Sendable, Codable, Equatable, Hashable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let textAnalysis = CodingAgentCapabilities(rawValue: 1 << 0)
    static let workspaceRead = CodingAgentCapabilities(rawValue: 1 << 1)
    static let workspaceWrite = CodingAgentCapabilities(rawValue: 1 << 2)
    static let tools = CodingAgentCapabilities(rawValue: 1 << 3)
    static let interactiveApproval = CodingAgentCapabilities(rawValue: 1 << 4)
    static let sessionResume = CodingAgentCapabilities(rawValue: 1 << 5)
    static let cancellable = CodingAgentCapabilities(rawValue: 1 << 6)
    static let structuredEvents = CodingAgentCapabilities(rawValue: 1 << 7)
    static let usageReporting = CodingAgentCapabilities(rawValue: 1 << 8)

    static let all: CodingAgentCapabilities = [
        .textAnalysis,
        .workspaceRead,
        .workspaceWrite,
        .tools,
        .interactiveApproval,
        .sessionResume,
        .cancellable,
        .structuredEvents,
        .usageReporting,
    ]

    var missingDescriptions: [String] {
        var descriptions: [String] = []
        if !contains(.textAnalysis) { descriptions.append("textAnalysis") }
        if !contains(.workspaceRead) { descriptions.append("workspaceRead") }
        if !contains(.workspaceWrite) { descriptions.append("workspaceWrite") }
        if !contains(.tools) { descriptions.append("tools") }
        if !contains(.interactiveApproval) { descriptions.append("interactiveApproval") }
        if !contains(.sessionResume) { descriptions.append("sessionResume") }
        if !contains(.cancellable) { descriptions.append("cancellable") }
        if !contains(.structuredEvents) { descriptions.append("structuredEvents") }
        if !contains(.usageReporting) { descriptions.append("usageReporting") }
        return descriptions
    }

    func missing(from required: CodingAgentCapabilities) -> [String] {
        var missingNames: [String] = []
        let flagMap: [(CodingAgentCapabilities, String)] = [
            (.textAnalysis, "textAnalysis"),
            (.workspaceRead, "workspaceRead"),
            (.workspaceWrite, "workspaceWrite"),
            (.tools, "tools"),
            (.interactiveApproval, "interactiveApproval"),
            (.sessionResume, "sessionResume"),
            (.cancellable, "cancellable"),
            (.structuredEvents, "structuredEvents"),
            (.usageReporting, "usageReporting"),
        ]

        for (flag, name) in flagMap {
            if required.contains(flag) && !self.contains(flag) {
                missingNames.append(name)
            }
        }
        return missingNames
    }
}
