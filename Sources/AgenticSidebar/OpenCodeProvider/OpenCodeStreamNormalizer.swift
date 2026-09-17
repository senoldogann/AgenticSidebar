import Foundation

/// Alt ajanın çocuk oturumunda çalışan tek bir araç çağrısı.
///
/// OpenCode'un `task` parçası koşu boyunca adım listesi taşımıyor
/// (`metadata.summary` bu sürümde hiç üretilmiyor); adımlar ancak çocuk
/// oturumun kendi `message.part.updated` olaylarından öğrenilebiliyor.
struct OpenCodeSubagentStep: Equatable, Sendable {
    let id: String
    let name: String
    let title: String?
    var status: String
}

struct OpenCodeStreamNormalizer: Sendable {
    private let sessionID: String
    private let onPermissionRequest: (@Sendable (OpenCodePermissionRequest) -> Void)?
    private var partTypes: [String: String] = [:]
    private var bufferedTextDeltas: [String: String] = [:]
    private var bufferedPartOrder: [String] = []
    private var runningToolDescriptors: [String: ProviderActivityDescriptor] = [:]
    private var finishedToolPartIDs: Set<String> = []

    /// Çocuk oturum kimliğinden üstteki `task` aktivitesine eşleme.
    private var subagentOwnerByChildSession: [String: ProviderActivityID] = [:]
    /// Üst aktivitenin başlığı ve ajan adı; canlı güncellemeler descriptor'ı
    /// adım listesinden sıfırdan kurarken bu bilgileri korur.
    private var subagentTitles: [ProviderActivityID: String] = [:]
    private var subagentAgents: [ProviderActivityID: String] = [:]
    private var subagentSteps: [ProviderActivityID: [OpenCodeSubagentStep]] = [:]
    private var subagentStepIndexes: [ProviderActivityID: [String: Int]] = [:]
    /// Eşlemesi öğrenilmeden önce görülen çocuk adımları. Sahiplenilmezse tur
    /// sonunda düşer; başka bir sohbetin olayı olabilir.
    private var bufferedChildSteps: [String: [OpenCodeSubagentStep]] = [:]
    /// Global SSE may expose foreign permissions before a child's ownership is
    /// known. Never dispatch them until the parent task identifies the child.
    private var bufferedChildPermissions: [String: [OpenCodePermissionRequest]] = [:]

    /// Tek bir alt ajan için tutulan en fazla adım; taşan en eskiden düşer.
    private static let maximumSubagentSteps = 64
    /// Eşlemesi bilinmeyen çocuk oturumlar için tampon sınırı.
    private static let maximumBufferedChildSessions = 8
    private static let maximumBufferedPermissionsPerSession = 16

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
        guard line.hasPrefix("data:") else {
            return []
        }

        // The single space after an SSE field colon is optional.
        let value = line.dropFirst(5)
        let payload = String(value.first == " " ? value.dropFirst() : value[...])
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
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
            if let request = OpenCodePermissionRequest.make(from: properties) {
                if request.remoteSessionID == sessionID
                    || subagentOwnerByChildSession[request.remoteSessionID] != nil
                {
                    onPermissionRequest?(request.marked(ownedBy: sessionID))
                } else {
                    // /event covers every conversation. Do not assign a foreign
                    // permission to this turn merely because it was observed.
                    bufferChildPermission(request)
                }
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
            let partID = part["id"] as? String,
            let partType = part["type"] as? String
        else {
            return []
        }

        // Yabancı oturumlar kendi başına olay üretmez; yalnız eşlemesi
        // öğrenilmiş alt oturumların araç adımları üstteki karta yazılır.
        guard eventSessionID == sessionID else {
            return consumeChildPartUpdated(
                part: part,
                childSessionID: eventSessionID,
                partID: partID,
                partType: partType
            )
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

            let activityID = ProviderActivityID(partID)
            let kind = ProviderActivityDescriptor.sanitizedTool(
                id: activityID,
                toolName: tool
            ).kind
            let input = state["input"] as? [String: Any] ?? [:]
            let (toolTitle, toolDetail) = Self.extractToolTitleAndDetail(
                tool: tool,
                input: input,
                status: status,
                state: state
            )
            // `task` parçası çocuk oturumun kimliğini metadata'da taşır; çocuğun
            // araç olayları bu eşleme üzerinden üstteki karta yazılır.
            let learningEvents: [ProviderEvent]
            if kind == .subagent, let childSessionID = Self.childSessionID(in: state) {
                learningEvents = learnSubagentChild(
                    childSessionID,
                    at: activityID,
                    title: toolTitle,
                    agent: Self.subagentAgent(input: input)
                )
            } else {
                learningEvents = []
            }

            // Only the final part update carries a result, so the output and the
            // change preview travel with the terminal event.
            let output = state["output"] as? String ?? state["error"] as? String
            let diff = Self.fileChangePreview(tool: tool, input: input)

            switch status {
            case "running":
                let isNew = runningToolDescriptors[partID] == nil
                let runningOutput: String?
                let runningDetail: String?
                if kind == .subagent {
                    runningOutput = subagentStepsOutput(for: activityID, finished: false)
                    runningDetail = subagentStepsDetail(for: activityID) ?? toolDetail
                } else {
                    runningOutput = output
                    runningDetail = toolDetail
                }
                let descriptor = ProviderActivityDescriptor.sanitizedTool(
                    id: activityID,
                    toolName: tool,
                    title: toolTitle,
                    detail: runningDetail,
                    output: runningOutput
                )
                if isNew {
                    runningToolDescriptors[partID] = descriptor
                    return learningEvents + [.activityStarted(descriptor)]
                } else if runningToolDescriptors[partID] != descriptor {
                    runningToolDescriptors[partID] = descriptor
                    // Tampon boşaltımı zaten adımların güncel hâlini yayınladı.
                    return learningEvents.isEmpty ? [.activityUpdated(descriptor)] : learningEvents
                } else {
                    return learningEvents
                }
            case "completed", "error":
                let outcome: ProviderActivityOutcome = status == "completed" ? .completed : .failed
                // `task` çıktısı `<task>`/`<task_result>` sarmalayıcısıyla gelir;
                // panel ve geçmiş yalnız rapor içeriğini görsün.
                let terminalOutput = kind == .subagent ? output.map(Self.strippedTaskWrapper) : output
                if runningToolDescriptors.removeValue(forKey: partID) != nil {
                    finishedToolPartIDs.insert(partID)
                    var events = learningEvents
                    // Bitince kart adım listesini bırakır: `output` nihai rapordur
                    // ve sağ panelde okunur, kartta değil.
                    if kind == .subagent,
                       let finalOutput = subagentStepsOutput(for: activityID, finished: true)
                    {
                        events.append(.activityUpdated(ProviderActivityDescriptor.sanitizedTool(
                            id: activityID,
                            toolName: tool,
                            title: toolTitle,
                            detail: subagentStepsDetail(for: activityID),
                            output: finalOutput
                        )))
                    }
                    events.append(.activityFinished(activityID, outcome: outcome, output: terminalOutput, diff: diff))
                    return events
                } else if !finishedToolPartIDs.contains(partID) {
                    finishedToolPartIDs.insert(partID)
                    let descriptor = ProviderActivityDescriptor.sanitizedTool(
                        id: activityID,
                        toolName: tool,
                        title: toolTitle,
                        detail: toolDetail,
                        output: terminalOutput
                    )
                    var events: [ProviderEvent] = [.activityStarted(descriptor)]
                    events.append(contentsOf: learningEvents)
                    events.append(.activityFinished(activityID, outcome: outcome, output: terminalOutput, diff: diff))
                    return events
                } else {
                    return []
                }
            default:
                return []
            }

        default:
            removeBufferedText(for: partID)
            return []
        }
    }

    /// Çocuk oturumdan gelen parça güncellemesi.
    ///
    /// Yalnız araç parçaları işlenir: metin ve akıl yürütme başka bir oturumun
    /// cevabıdır ve üstteki transkripte asla karışmaz. Eşlemesi henüz
    /// öğrenilmemiş oturumlar sınırlı bir tampona yazılır; tur boyunca
    /// sahiplenilmezlerse sessizce düşerler.
    private mutating func consumeChildPartUpdated(
        part: [String: Any],
        childSessionID: String,
        partID: String,
        partType: String
    ) -> [ProviderEvent] {
        guard
            partType == "tool",
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
        let step = OpenCodeSubagentStep(
            id: partID,
            name: Self.stepName(for: tool),
            title: Self.boundedStepTitle(toolTitle ?? toolDetail),
            status: status
        )

        guard let owner = subagentOwnerByChildSession[childSessionID] else {
            bufferChildStep(step, for: childSessionID)
            return []
        }

        guard storeChildStep(step, for: owner) else {
            return []
        }

        return stepsUpdateEvents(for: owner)
    }

    /// Adımı saklar; durum ve başlık değişmediyse `false` döner.
    private mutating func storeChildStep(
        _ step: OpenCodeSubagentStep,
        for owner: ProviderActivityID
    ) -> Bool {
        var steps = subagentSteps[owner] ?? []
        var indexes = subagentStepIndexes[owner] ?? [:]

        if let index = indexes[step.id] {
            guard steps[index] != step else {
                return false
            }
            steps[index] = step
        } else {
            indexes[step.id] = steps.count
            steps.append(step)
            if steps.count > Self.maximumSubagentSteps {
                steps.removeFirst(steps.count - Self.maximumSubagentSteps)
                indexes = Dictionary(
                    uniqueKeysWithValues: steps.enumerated().map { ($1.id, $0) }
                )
            }
        }

        subagentSteps[owner] = steps
        subagentStepIndexes[owner] = indexes
        return true
    }

    /// Eşlemesi bilinmeyen çocuk adımlarını sınırlı tampona yazar.
    private mutating func bufferChildStep(
        _ step: OpenCodeSubagentStep,
        for childSessionID: String
    ) {
        var steps = bufferedChildSteps[childSessionID] ?? []
        if let index = steps.firstIndex(where: { $0.id == step.id }) {
            steps[index] = step
        } else {
            steps.append(step)
        }
        if steps.count > Self.maximumSubagentSteps {
            steps.removeFirst(steps.count - Self.maximumSubagentSteps)
        }
        bufferedChildSteps[childSessionID] = steps

        if bufferedChildSteps.count > Self.maximumBufferedChildSessions {
            // Hangi oturumun düşeceği önemsiz: sahiplenilmeyenler zaten yalnız
            // bu turda yaşar. Sıralama deterministik olsun diye ilk anahtar.
            if let oldest = bufferedChildSteps.keys.sorted().first {
                bufferedChildSteps.removeValue(forKey: oldest)
            }
        }
    }

    /// Unknown sessions are held briefly and never replied to by this turn.
    /// A verified parent task will flush its child's requests in arrival order.
    private mutating func bufferChildPermission(_ request: OpenCodePermissionRequest) {
        var pending = bufferedChildPermissions[request.remoteSessionID] ?? []
        guard !pending.contains(where: { $0.id == request.id }) else {
            return
        }
        pending.append(request)
        if pending.count > Self.maximumBufferedPermissionsPerSession {
            pending.removeFirst(pending.count - Self.maximumBufferedPermissionsPerSession)
        }
        bufferedChildPermissions[request.remoteSessionID] = pending
        if bufferedChildPermissions.count > Self.maximumBufferedChildSessions,
           let evicted = bufferedChildPermissions.keys.sorted().first
        {
            bufferedChildPermissions.removeValue(forKey: evicted)
        }
    }

    /// `task` parçasının metadata'sındaki çocuk oturum kimliği.
    private static func childSessionID(in state: [String: Any]) -> String? {
        guard
            let metadata = state["metadata"] as? [String: Any],
            let childSessionID = metadata["sessionId"] as? String,
            !childSessionID.isEmpty
        else {
            return nil
        }

        return childSessionID
    }

    /// Eşlemeyi öğrenir; tamponda bekleyen adım varsa tek güncellemeyle yayınlar.
    private mutating func learnSubagentChild(
        _ childSessionID: String,
        at activityID: ProviderActivityID,
        title: String?,
        agent: String?
    ) -> [ProviderEvent] {
        subagentOwnerByChildSession[childSessionID] = activityID
        if let requests = bufferedChildPermissions.removeValue(forKey: childSessionID) {
            for request in requests {
                onPermissionRequest?(request.marked(ownedBy: sessionID))
            }
        }
        if subagentTitles[activityID] == nil, let title, !title.isEmpty {
            subagentTitles[activityID] = title
        }
        if subagentAgents[activityID] == nil, let agent, !agent.isEmpty {
            subagentAgents[activityID] = agent
        }

        guard let buffered = bufferedChildSteps.removeValue(forKey: childSessionID) else {
            return []
        }

        var changed = false
        for step in buffered {
            changed = storeChildStep(step, for: activityID) || changed
        }

        guard changed else {
            return []
        }

        return stepsUpdateEvents(for: activityID)
    }

    /// Adım listesinin güncel hâlini `.activityUpdated` olarak paketler.
    private func stepsUpdateEvents(for activityID: ProviderActivityID) -> [ProviderEvent] {
        guard let output = subagentStepsOutput(for: activityID, finished: false) else {
            return []
        }

        return [
            .activityUpdated(
                ProviderActivityDescriptor(
                    id: activityID,
                    kind: .subagent,
                    title: subagentTitles[activityID],
                    detail: subagentStepsDetail(for: activityID),
                    output: output
                )
            )
        ]
    }

    /// Canlı adım listesini kartın gövdesine çevirir.
    private func subagentStepsOutput(
        for activityID: ProviderActivityID,
        finished: Bool
    ) -> String? {
        guard let steps = subagentSteps[activityID], !steps.isEmpty else {
            return nil
        }

        return Self.subagentStepsOutput(
            agent: subagentAgents[activityID],
            steps: steps,
            finished: finished
        )
    }

    /// Kart başlığındaki canlı özet: "3 tool calls · last: Bash".
    private func subagentStepsDetail(for activityID: ProviderActivityID) -> String? {
        guard let steps = subagentSteps[activityID], !steps.isEmpty else {
            return nil
        }

        let noun = steps.count == 1 ? "tool call" : "tool calls"
        return "\(steps.count) \(noun) · last: \(steps[steps.count - 1].name)"
    }

    static func subagentStepsOutput(
        agent: String?,
        steps: [OpenCodeSubagentStep],
        finished: Bool
    ) -> String {
        let count = steps.count
        let heading: String
        if let agent, !agent.isEmpty {
            heading = "Subagent \(agent) \(finished ? "ran" : "working") (\(count) step\(count == 1 ? "" : "s")):"
        } else {
            heading = "Subagent \(finished ? "ran" : "working") (\(count) step\(count == 1 ? "" : "s")):"
        }

        let shown = steps.suffix(maximumSubagentSummarySteps)
        var lines: [String] = [heading]
        let omitted = count - shown.count
        if omitted > 0 {
            lines.append("… \(omitted) earlier step\(omitted == 1 ? "" : "s")")
        }
        lines.append(contentsOf: shown.map(stepLine))

        return lines.joined(separator: "\n")
    }

    /// `task` aracının ham çıktısındaki `<task …>`/`<task_result>` sarmalayıcısını
    /// soyar. Panel ve arşiv yalnız rapor içeriğini taşır.
    static func strippedTaskWrapper(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("<task"), let openingEnd = text.firstIndex(of: ">") {
            text = String(text[text.index(after: openingEnd)...])
        }
        if let resultStart = text.range(of: "<task_result>") {
            text = String(text[resultStart.upperBound...])
        }
        if let resultEnd = text.range(of: "</task_result>", options: .backwards) {
            text = String(text[..<resultEnd.lowerBound])
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("</task>") {
            text = String(text.dropLast("</task>".count))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `✓ Read — Analyzed Session.swift` biçiminde tek adım satırı.
    static func stepLine(for step: OpenCodeSubagentStep) -> String {
        let mark = switch step.status {
        case "completed": "✓"
        case "error", "failed": "✗"
        default: "…"
        }

        if let title = step.title, !title.isEmpty {
            return "\(mark) \(step.name) — \(title)"
        }
        return "\(mark) \(step.name)"
    }

    /// Adım satırında görünen araç adı; MCP ve iç içe alt ajan okunur kalsın.
    static func stepName(for tool: String) -> String {
        let kind = ProviderActivityDescriptor.sanitizedTool(
            id: ProviderActivityID(""),
            toolName: tool
        ).kind

        if kind == .subagent {
            return "Subagent"
        }

        if kind == .mcp {
            let (server, innerTool) = ProviderActivityDescriptor.mcpServerAndTool(from: tool)
            let humanized = ProviderActivityDescriptor.humanizedToolName(innerTool)
            return server.map { "\(humanized) (MCP \($0))" } ?? humanized
        }

        return ProviderActivityDescriptor.humanizedToolName(tool)
    }

    /// Adım başlığını tek satıra indirir ve sınırlar.
    private static func boundedStepTitle(_ text: String?) -> String? {
        guard let text else {
            return nil
        }

        let singleLine = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let singleLine, !singleLine.isEmpty else {
            return nil
        }

        return singleLine.count > maximumSubagentStepTitleLength
            ? String(singleLine.prefix(maximumSubagentStepTitleLength)) + "…"
            : singleLine
    }

    private static let maximumSubagentStepTitleLength = 120

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
        runningToolDescriptors.removeAll()
        finishedToolPartIDs.removeAll()
        subagentOwnerByChildSession.removeAll()
        subagentTitles.removeAll()
        subagentAgents.removeAll()
        subagentSteps.removeAll()
        subagentStepIndexes.removeAll()
        bufferedChildSteps.removeAll()
        bufferedChildPermissions.removeAll()

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
            let content = (input["content"] as? String)
                ?? (input["CodeContent"] as? String)
                ?? (input["code"] as? String)
                ?? ""
            guard !content.isEmpty else {
                return nil
            }

            return previewLines(content, prefix: "+ ")
        }

        if let diff = (input["diff"] as? String) ?? (input["patch"] as? String), !diff.isEmpty {
            return diff
        }

        let oldValue = (input["oldString"] as? String)
            ?? (input["old_str"] as? String)
            ?? (input["targetContent"] as? String)
            ?? (input["target_content"] as? String)
        let newValue = (input["newString"] as? String)
            ?? (input["new_str"] as? String)
            ?? (input["replacementContent"] as? String)
            ?? (input["replacement_content"] as? String)

        guard let oldValue, let newValue else {
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

    /// Subagent task title and detail.
    ///
    /// Input contains the delegation arguments: `description`, `subagent_type`,
    /// and `prompt`. For other subagent tools, alternative keys (`TaskName`, `Task`,
    /// etc.) are inspected as well.
    static func subagentTitleAndDetail(
        tool: String,
        input: [String: Any]
    ) -> (String?, String?) {
        let description = ((input["description"] as? String)
            ?? (input["TaskName"] as? String)
            ?? (input["task_name"] as? String)
            ?? (input["title"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var agent = Self.subagentAgent(input: input)

        if (agent == nil || agent?.isEmpty == true) && tool.lowercased() != "task" {
            let normalized = tool.lowercased()
            if normalized.hasSuffix("_subagent") {
                agent = String(normalized.dropLast("_subagent".count))
            } else if normalized.hasPrefix("subagent_") {
                agent = String(normalized.dropFirst("subagent_".count))
            } else if normalized != "subagent" {
                agent = normalized
            }
        }

        let title: String?
        switch (agent, description) {
        case let (agent?, description?) where !agent.isEmpty && !description.isEmpty:
            title = "Delegated to \(agent): \(description)"
        case let (_, description?) where !description.isEmpty:
            title = "Delegated subagent: \(description)"
        case let (agent?, _) where !agent.isEmpty:
            title = "Delegated to \(agent)"
        default:
            title = nil
        }

        let promptFirstLine = ((input["prompt"] as? String)
            ?? (input["Task"] as? String)
            ?? (input["task"] as? String)
            ?? (input["instructions"] as? String))?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let detail: String?
        if let promptFirstLine, !promptFirstLine.isEmpty {
            detail = promptFirstLine.count > maximumSubagentDetailLength
                ? String(promptFirstLine.prefix(maximumSubagentDetailLength)) + "…"
                : promptFirstLine
        } else {
            detail = agent?.isEmpty == false ? agent : nil
        }

        return (title, detail)
    }

    private static let maximumSubagentDetailLength = 160

    /// Delegasyon girdisindeki ajan adı (`subagent_type` ya da eşanlamlıları).
    static func subagentAgent(input: [String: Any]) -> String? {
        ((input["subagent_type"] as? String)
            ?? (input["agent"] as? String)
            ?? (input["agent_type"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// MCP title and detail with tool and input explicitly provided.
    static func mcpTitleAndDetail(
        tool: String,
        input: [String: Any]
    ) -> (String?, String?) {
        let (server, rawTool) = ProviderActivityDescriptor.mcpServerAndTool(from: tool, input: input)
        let humanized = ProviderActivityDescriptor.humanizedToolName(rawTool)

        let serverLabel = server.map { "MCP · \($0)" } ?? "MCP"

        guard !humanized.isEmpty else {
            return (nil, serverLabel)
        }

        if let server, !server.isEmpty {
            return ("\(humanized) via \(server)", serverLabel)
        }
        return (humanized, serverLabel)
    }

    /// MCP title and detail without input dictionary.
    static func mcpTitleAndDetail(tool: String) -> (String?, String?) {
        mcpTitleAndDetail(tool: tool, input: [:])
    }

    /// Maximum inner summary steps shown in the subagent card.
    private static let maximumSubagentSummarySteps = 20

    private static func extractToolTitleAndDetail(
        tool: String,
        input: [String: Any],
        status: String,
        state: [String: Any]
    ) -> (String?, String?) {
        let kind = ProviderActivityDescriptor.sanitizedTool(
            id: ProviderActivityID(""),
            toolName: tool
        ).kind

        // The subagent delegation call: shown like other tools, not as a todo item.
        if kind == .subagent {
            return subagentTitleAndDetail(tool: tool, input: input)
        }

        // MCP tools arrive namespaced or via wrappers like `call_mcp_tool`.
        if kind == .mcp {
            return mcpTitleAndDetail(tool: tool, input: input)
        }

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
            let lineSuffix: String
            if let startLine, let endLine {
                lineSuffix = " #L\(startLine)-\(endLine)"
            } else {
                lineSuffix = ""
            }

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

        if normalizedTool.contains("edit") || normalizedTool.contains("write") || normalizedTool.contains("patch") || normalizedTool.contains("replace") || normalizedTool.contains("create") {
            let path = (input["targetFile"] as? String)
                ?? (input["TargetFile"] as? String)
                ?? (input["filePath"] as? String)
                ?? (input["path"] as? String)
                ?? (input["file"] as? String)
                ?? ""

            guard !path.isEmpty else {
                return (nil, nil)
            }

            let filename = URL(fileURLWithPath: path).lastPathComponent
            guard !filename.isEmpty else {
                return (nil, nil)
            }

            let action = (normalizedTool.contains("create") || normalizedTool.contains("write")) ? "Created" : "Edited"
            return ("\(action) \(filename)", path)
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
