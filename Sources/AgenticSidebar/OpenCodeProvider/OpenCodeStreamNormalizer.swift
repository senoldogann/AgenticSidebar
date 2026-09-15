import Foundation

struct OpenCodeStreamNormalizer: Sendable {
    private let sessionID: String
    private var partTypes: [String: String] = [:]
    private var bufferedTextDeltas: [String: String] = [:]
    private var runningToolParts: Set<String> = []

    init(sessionID: String) {
        self.sessionID = sessionID
    }

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
            return targetSession(in: properties) ? [.completed] : []
        case "session.error":
            if let eventSessionID = properties["sessionID"] as? String,
               eventSessionID != sessionID
            {
                return []
            }
            throw ProviderRuntimeError.unexpectedResponse
        default:
            return []
        }
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
            guard let buffered = bufferedTextDeltas.removeValue(forKey: partID),
                  !buffered.isEmpty
            else {
                return []
            }
            return [.assistantTextDelta(buffered)]

        case "reasoning":
            bufferedTextDeltas.removeValue(forKey: partID)
            return []

        case "tool":
            bufferedTextDeltas.removeValue(forKey: partID)
            guard
                let tool = part["tool"] as? String,
                let state = part["state"] as? [String: Any],
                let status = state["status"] as? String
            else {
                return []
            }

            switch status {
            case "running":
                if runningToolParts.insert(partID).inserted {
                    return [
                        .activityStarted(
                            ProviderActivityDescriptor.sanitizedTool(
                                id: ProviderActivityID(partID),
                                toolName: tool
                            )
                        )
                    ]
                }
                return []
            case "completed":
                if runningToolParts.remove(partID) != nil {
                    return [
                        .activityFinished(
                            ProviderActivityID(partID),
                            outcome: .completed
                        )
                    ]
                }
                return []
            case "error":
                if runningToolParts.remove(partID) != nil {
                    return [
                        .activityFinished(
                            ProviderActivityID(partID),
                            outcome: .failed
                        )
                    ]
                }
                return []
            default:
                return []
            }

        default:
            bufferedTextDeltas.removeValue(forKey: partID)
            return []
        }
    }

    private func consumeSessionStatus(
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
            return [.completed]
        case "retry":
            return [.waiting]
        default:
            return []
        }
    }

    private func targetSession(in properties: [String: Any]) -> Bool {
        properties["sessionID"] as? String == sessionID
    }
}
