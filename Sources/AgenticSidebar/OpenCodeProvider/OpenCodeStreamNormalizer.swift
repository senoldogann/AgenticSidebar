import Foundation

struct OpenCodeStreamNormalizer: Sendable {
    private let sessionID: String
    private let onPermissionRequest: (@Sendable (OpenCodePermissionRequest) -> Void)?
    private var partTypes: [String: String] = [:]
    private var bufferedTextDeltas: [String: String] = [:]
    private var bufferedPartOrder: [String] = []
    private var runningToolParts: Set<String> = []

    init(sessionID: String) {
        self.sessionID = sessionID
        self.onPermissionRequest = nil
    }

    init(sessionID: String, onPermissionRequest: (@Sendable (OpenCodePermissionRequest) -> Void)?) {
        self.sessionID = sessionID
        self.onPermissionRequest = onPermissionRequest
    }

    /// Malformed payloads fail the turn on purpose: silently dropping bytes would
    /// present a truncated answer as a complete one. Unknown event types and SSE
    /// control lines are ignored, which covers additive protocol changes.
    mutating func consume(line: String) throws -> [ProviderEvent] {
        guard line.hasPrefix("data: ") else {
            return []
        }

        let payload = String(line.dropFirst(6))
        guard let data = payload.data(using: .utf8) else {
            throw ProviderRuntimeError.unexpectedResponse
        }

        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ProviderRuntimeError.unexpectedResponse
            }
            object = decoded
        } catch let error as ProviderRuntimeError {
            throw error
        } catch {
            throw ProviderRuntimeError.unexpectedResponse
        }

        guard let type = object["type"] as? String else {
            throw ProviderRuntimeError.unexpectedResponse
        }
        let properties = object["properties"] as? [String: Any] ?? [:]

        switch type {
        case "message.part.delta":
            return consumePartDelta(properties)
        case "message.part.updated":
            return consumePartUpdated(properties)
        case "session.status":
            return consumeSessionStatus(properties)
        case "session.idle":
            guard targetSession(in: properties) else {
                return []
            }
            return finishTurn()
        case "session.error":
            if let eventSessionID = properties["sessionID"] as? String,
               eventSessionID != sessionID
            {
                return []
            }
            throw Self.error(fromSessionError: properties)
        case "permission.asked":
            if targetSession(in: properties),
               let request = OpenCodePermissionRequest.make(from: properties) {
                onPermissionRequest?(request)
            }
            return []
        default:
            return []
        }
    }

    /// OpenCode reports backend failures through `session.error`. A context
    /// overflow is worth telling apart from a generic failure: the fix is a
    /// shorter conversation, not a retry. Only the error envelope is inspected,
    /// and its text is never surfaced to the user.
    static func error(fromSessionError properties: [String: Any]) -> ProviderRuntimeError {
        guard
            let data = try? JSONSerialization.data(withJSONObject: properties),
            let serialized = String(data: data, encoding: .utf8)?.lowercased()
        else {
            return .unexpectedResponse
        }

        let markers = [
            "contextoverflow",
            "context_length_exceeded",
            "context length",
            "context window",
            "too many tokens"
        ]

        return markers.contains { serialized.contains($0) }
            ? .contextLimitExceeded
            : .unexpectedResponse
    }

    private mutating func consumePartDelta(
        _ properties: [String: Any]
    ) -> [ProviderEvent] {
        guard
            targetSession(in: properties),
            properties["field"] as? String == "text",
            let partID = properties["partID"] as? String,
            let delta = properties["delta"] as? String
        else {
            return []
        }

        switch partTypes[partID] {
        case "text":
            return [.assistantTextDelta(delta)]
        case "reasoning":
            return []
        case .some:
            return []
        case .none:
            if bufferedTextDeltas[partID] == nil {
                bufferedPartOrder.append(partID)
            }
            bufferedTextDeltas[partID, default: ""] += delta
            return []
        }
    }

    private mutating func consumePartUpdated(
        _ properties: [String: Any]
    ) -> [ProviderEvent] {
        guard
            let part = properties["part"] as? [String: Any],
            let eventSessionID = (
                properties["sessionID"] as? String
                    ?? part["sessionID"] as? String
            ),
            eventSessionID == sessionID,
            let partID = part["id"] as? String,
            let partType = part["type"] as? String
        else {
            return []
        }

        partTypes[partID] = partType

        switch partType {
        case "text":
            guard let buffered = removeBufferedText(for: partID) else {
                return []
            }
            return [.assistantTextDelta(buffered)]

        case "reasoning":
            removeBufferedText(for: partID)
            return []

        case "tool":
            removeBufferedText(for: partID)
            guard
                let tool = part["tool"] as? String,
                let state = part["state"] as? [String: Any],
                let status = state["status"] as? String
            else {
                return []
            }

            let input = state["input"] as? [String: Any] ?? [:]
            let (toolTitle, toolDetail) = Self.extractToolTitleAndDetail(
                tool: tool,
                input: input,
                status: status,
                state: state
            )
            // Only the final part update carries a result, so the output and the
            // change preview travel with the terminal event.
            let output = state["output"] as? String ?? state["error"] as? String
            let diff = Self.fileChangePreview(tool: tool, input: input)

            switch status {
            case "running":
                guard runningToolParts.insert(partID).inserted else {
                    return []
                }
                return [
                    .activityStarted(
                        ProviderActivityDescriptor.sanitizedTool(
                            id: ProviderActivityID(partID),
                            toolName: tool,
                            title: toolTitle,
                            detail: toolDetail,
                            output: output
                        )
                    )
                ]
            case "completed", "error":
                guard runningToolParts.remove(partID) != nil else {
                    return []
                }
                return [
                    .activityFinished(
                        ProviderActivityID(partID),
                        outcome: status == "completed" ? .completed : .failed,
                        output: output,
                        diff: diff
                    )
                ]
            default:
                return []
            }

        default:
            removeBufferedText(for: partID)
            return []
        }
    }

    private mutating func consumeSessionStatus(
        _ properties: [String: Any]
    ) -> [ProviderEvent] {
        guard
            targetSession(in: properties),
            let status = properties["status"] as? [String: Any],
            let statusType = status["type"] as? String
        else {
            return []
        }

        switch statusType {
        case "idle":
            return finishTurn()
        case "retry":
            return [.waiting]
        default:
            return []
        }
    }

    /// Text deltas can arrive before the event that reveals their part type. Any
    /// text still buffered when the turn ends is emitted in arrival order instead
    /// of being silently discarded.
    private mutating func finishTurn() -> [ProviderEvent] {
        let pendingText = bufferedPartOrder.compactMap { partID -> ProviderEvent? in
            guard
                let text = bufferedTextDeltas[partID],
                !text.isEmpty
            else {
                return nil
            }
            return .assistantTextDelta(text)
        }

        partTypes.removeAll()
        bufferedTextDeltas.removeAll()
        bufferedPartOrder.removeAll()
        runningToolParts.removeAll()

        return pendingText + [.completed]
    }

    @discardableResult
    private mutating func removeBufferedText(for partID: String) -> String? {
        bufferedPartOrder.removeAll { $0 == partID }

        guard let text = bufferedTextDeltas.removeValue(forKey: partID) else {
            return nil
        }

        return text.isEmpty ? nil : text
    }

    /// The `+`/`-` preview of a file-changing tool.
    ///
    /// Taken from the tool inputs verified against OpenCode 1.18.31: `edit`
    /// carries `filePath`/`oldString`/`newString`, and `write` carries
    /// `filePath`/`content`. Nothing is invented — a tool whose input has neither
    /// shape produces no preview rather than an empty one.
    static func fileChangePreview(tool: String, input: [String: Any]) -> String? {
        let normalizedTool = tool.lowercased()

        if normalizedTool.contains("write") || normalizedTool.contains("create") {
            guard let content = input["content"] as? String, !content.isEmpty else {
                return nil
            }

            return previewLines(content, prefix: "+ ")
        }

        guard
            let oldValue = input["oldString"] as? String,
            let newValue = input["newString"] as? String
        else {
            return nil
        }

        let removed = oldValue.isEmpty ? nil : previewLines(oldValue, prefix: "- ")
        let added = newValue.isEmpty ? nil : previewLines(newValue, prefix: "+ ")
        let sections = [removed, added].compactMap { $0 }

        guard !sections.isEmpty else {
            return nil
        }

        return sections.joined(separator: "\n")
    }

    /// Previews are for reading, not for archiving: a large rewrite is capped so
    /// one tool call cannot dominate the transcript.
    private static let maximumPreviewLines = 400

    private static func previewLines(_ text: String, prefix: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var omittedCount = 0

        if lines.count > maximumPreviewLines {
            omittedCount = lines.count - maximumPreviewLines
            lines = Array(lines.prefix(maximumPreviewLines))
        }

        var preview = lines
            .map { $0.isEmpty ? prefix.trimmingCharacters(in: .whitespaces) : prefix + $0 }
            .joined(separator: "\n")

        if omittedCount > 0 {
            preview += "\n… \(omittedCount) more line\(omittedCount == 1 ? "" : "s")"
        }

        return preview
    }

    private static func extractToolTitleAndDetail(
        tool: String,
        input: [String: Any],
        status: String,
        state: [String: Any]
    ) -> (String?, String?) {
        let normalizedTool = tool.lowercased()

        if normalizedTool.contains("bash") || normalizedTool.contains("command") || normalizedTool.contains("exec") || normalizedTool.contains("terminal") {
            let cmd = (input["command"] as? String) ?? (input["cmd"] as? String) ?? (input["script"] as? String) ?? ""
            let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return (status == "running" ? "Running \(trimmed)" : "Ran \(trimmed)", trimmed)
            }
            return (status == "running" ? "Running command" : "Ran command", nil)
        }

        if normalizedTool.contains("read") || normalizedTool.contains("view") || normalizedTool.contains("get") {
            let path = (input["filePath"] as? String) ?? (input["path"] as? String) ?? (input["file"] as? String) ?? ""
            let startLine = input["startLine"] as? Int
            let endLine = input["endLine"] as? Int
            let lineSuffix = (startLine != nil && endLine != nil) ? " #L\(startLine!)-\(endLine!)" : ""

            // An empty path must not be resolved against the current directory:
            // that reported the working directory name as if it were the file.
            guard !path.isEmpty else {
                return (nil, nil)
            }

            let filename = URL(fileURLWithPath: path).lastPathComponent
            guard !filename.isEmpty else {
                return (nil, nil)
            }

            return ("Analyzed \(filename)\(lineSuffix)", path)
        }

        if normalizedTool.contains("edit") || normalizedTool.contains("write") || normalizedTool.contains("patch") {
            let path = (input["targetFile"] as? String) ?? (input["filePath"] as? String) ?? (input["path"] as? String) ?? ""

            guard !path.isEmpty else {
                return (nil, nil)
            }

            let filename = URL(fileURLWithPath: path).lastPathComponent
            guard !filename.isEmpty else {
                return (nil, nil)
            }

            return ("Edited \(filename)", path)
        }

        if normalizedTool.contains("search") || normalizedTool.contains("grep") || normalizedTool.contains("glob") {
            let query = (input["query"] as? String) ?? (input["pattern"] as? String) ?? ""
            if !query.isEmpty {
                return ("Searched for \(query)", query)
            }
            return ("Explored files", nil)
        }

        if let stateTitle = state["title"] as? String, !stateTitle.isEmpty {
            return (stateTitle, nil)
        }

        return (nil, nil)
    }

    private func targetSession(in properties: [String: Any]) -> Bool {
        properties["sessionID"] as? String == sessionID
    }
}
