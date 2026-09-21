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
    private var finishedToolPartOrder: [String] = []
    /// Text parts whose content already reached the transcript — via streamed
    /// deltas or one full-text fallback — so a later update carrying the same
    /// text is not emitted a second time.
    private var emittedTextPartIDs: Set<String> = []
    private var emittedTextPartOrder: [String] = []
    /// Thinking içeriği yüzeye çıkan reasoning parçaları; sıra, en eskiyi
    /// düşürmek için. Asistan metninden ayrı kümedir: aynı partID iki kanalda
    /// da geçebilir, biri diğerini susturmamalı.
    private var emittedReasoningPartIDs: Set<String> = []
    private var emittedReasoningPartOrder: [String] = []

    /// Hedef oturumda görülen KULLANICI mesajı kimlikleri.
    ///
    /// OpenCode kullanıcının kendi mesajını da parça olarak yayar ve o parçanın
    /// metni, gönderilen çerçeveli prompt'un aynısıdır (`<user_turn>…`). Rol
    /// ayrımı olmadan bu parça asistan metni sayılıyordu: sohbete kullanıcının
    /// kendi mesajı asistan yanıtı olarak düşüyor ve ekranda gerçek bir yanıt
    /// yerine `<user_turn>` gövdesi görünüyordu.
    ///
    /// Filtre, `message.updated`'in parça olaylarından ÖNCE gelmesine dayanır:
    /// bir parça, ait olduğu mesaj yaratılmadan var olamaz.
    private var userMessageIDs: Set<String> = []
    private var userMessageOrder: [String] = []

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
    /// Tura ait metin tamponu: kısmi `text` parçaları için en eski düşer.
    private static let maximumBufferedTextParts = 128
    /// Tek bir parça için bayt bütçesi: tipi geç öğrenilen dev bir parça
    /// tamponu sınırsız şişiriyordu (parça sayısı sınırlıydı ama parça
    /// büyüklüğü değildi). Aşımda metin kesilir ve kesildiği işaretlenir.
    private static let maximumBufferedTextBytesPerPart = 256 * 1024
    /// Yinelenen bitiş olaylarını eleyen küme; sıra, en eskiyi düşürmek için.
    private static let maximumFinishedToolParts = 256
    /// Yüzeye çıkan metin parçaları; sıra, en eskiyi düşürmek için.
    private static let maximumEmittedTextParts = 256
    /// Yüzeye çıkan reasoning parçaları; sıra, en eskiyi düşürmek için.
    private static let maximumEmittedReasoningParts = 256
    /// Rolü öğrenilen kullanıcı mesajları; sıra, en eskiyi düşürmek için.
    private static let maximumTrackedUserMessages = 256

    init(sessionID: String) {
        self.sessionID = sessionID
        self.onPermissionRequest = nil
    }

    init(sessionID: String, onPermissionRequest: (@Sendable (OpenCodePermissionRequest) -> Void)?) {
        self.sessionID = sessionID
        self.onPermissionRequest = onPermissionRequest
    }

    /// Akış gürültüsü turu öldürmez: JSON olmayan `data:` satırı (sentinel,
    /// nabız, sağlayıcı geçiş gürültüsü) atlanır. Tek bir bozuk satır 46
    /// saniyelik gerçek işi (düşünme + araç sonuçları) çöpe atıyordu; tur
    /// yine de `session.idle`/`session.error` ile kapanır ve gerçekten boş
    /// kalan tur alt katmandaki boş-tur denetimine takılır. Bilinen sentinel
    /// (`[DONE]`) OpenAI yoluyla aynı şekilde atlanır. İyi biçimli ama
    /// oturuma ait `session.error` hâlâ fırlatılır: gerçek arka uç hatası
    /// sessizce yutulmaz. Bilinmeyen olay türleri ve SSE denetim satırları
    /// zaten yok sayılır, bu da ek protokol değişikliklerini kapsar.
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
        // Akış sonu sentineli: OpenAI yolundaki korumanın aynısı.
        guard payload != "[DONE]" else {
            return []
        }
        guard let data = payload.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data),
            let object = decoded as? [String: Any],
            let type = object["type"] as? String
        else {
            return []
        }
        let properties = object["properties"] as? [String: Any] ?? [:]

        switch type {
        case "message.part.delta":
            return consumePartDelta(properties)
        case "message.part.updated":
            return consumePartUpdated(properties)
        case "message.updated":
            // Rol kimliği ve asistan jeton sayımı burada okunur; başka
            // yüzeye olay üretilmez.
            return consumeMessageUpdated(properties)
        case "session.status":
            return consumeSessionStatus(properties)
        case "session.idle":
            guard targetSession(in: properties) else {
                return []
            }
            return finishTurn()
        case "session.error":
            // An error that names no session — or another turn's session — is
            // not this turn's failure. Throwing here killed an unrelated turn
            // for a problem it never caused.
            guard let eventSessionID = properties["sessionID"] as? String,
                eventSessionID == sessionID
            else {
                return []
            }
            let failure = Self.error(fromSessionError: properties)
            if failure == .unexpectedResponse {
                // Without this the turn ended on "The provider returned a response
                // this app could not interpret." and nothing else — the same
                // sentence for a rejected model, an unsupported attachment and a
                // backend bug. The backend's own words are the only thing that
                // tells them apart, so they travel the same bounded, truncated
                // channel an unreadable HTTP body already uses.
                ProviderResponseDiagnostics.shared.record(
                    provider: "OpenCode",
                    statusCode: nil,
                    body: Self.summary(ofSessionError: properties)
                )
            }
            throw failure
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
    /// shorter conversation, not a retry. Only the error envelope is inspected.
    ///
    /// Pure on purpose: the caller decides what to do with the answer, including
    /// whether to record the backend's wording for the error banner.
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
            "too many tokens",
        ]

        return markers.contains { serialized.contains($0) }
            ? .contextLimitExceeded
            : .unexpectedResponse
    }

    /// What the backend said went wrong, as one line.
    ///
    /// `session.error` carries `{name, data: {message}}`; both are kept because
    /// the name alone ("UnknownError") explains nothing and the message alone can
    /// be missing. An envelope with neither yields an empty string, which
    /// ``ProviderResponseDiagnostics`` drops rather than showing.
    static func summary(ofSessionError properties: [String: Any]) -> String {
        guard let error = properties["error"] as? [String: Any] else {
            return ""
        }

        let name = error["name"] as? String
        let message = (error["data"] as? [String: Any])?["message"] as? String

        return [name, message]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ": ")
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

        // Kullanıcının kendi mesajının parçası asistan metni değildir.
        if let messageID = properties["messageID"] as? String, userMessageIDs.contains(messageID) {
            return []
        }

        switch partTypes[partID] {
        case "text":
            markTextPartEmitted(partID)
            return [.assistantTextDelta(delta)]
        case "reasoning":
            // Akıl yürütme asistan metni değildir ama çöp de değildir: ayrı
            // thinking kanalına akar, turdaki düşünme kartını doldurur.
            markReasoningPartEmitted(partID)
            return [.thinkingDelta(delta)]
        case .some:
            return []
        case .none:
            if bufferedTextDeltas[partID] == nil {
                if bufferedPartOrder.count >= Self.maximumBufferedTextParts,
                    let oldest = bufferedPartOrder.first
                {
                    bufferedPartOrder.removeFirst()
                    bufferedTextDeltas.removeValue(forKey: oldest)
                }
                bufferedPartOrder.append(partID)
            }
            bufferedTextDeltas[partID, default: ""] = Self.appendingBufferedDelta(
                delta,
                to: bufferedTextDeltas[partID, default: ""]
            )
            return []
        }
    }

    private mutating func consumePartUpdated(
        _ properties: [String: Any]
    ) -> [ProviderEvent] {
        guard
            let part = properties["part"] as? [String: Any],
            let eventSessionID =
                (properties["sessionID"] as? String
                    ?? part["sessionID"] as? String),
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

        // Kullanıcı mesajının parçaları (metin ve ekler) asistan içeriği değildir:
        // burada düşmezlerse sohbete kullanıcının kendi prompt'u yazılır.
        if let messageID = part["messageID"] as? String, userMessageIDs.contains(messageID) {
            return []
        }

        partTypes[partID] = partType

        switch partType {
        case "text":
            if let buffered = removeBufferedText(for: partID) {
                markTextPartEmitted(partID)
                return [.assistantTextDelta(buffered)]
            }
            // No streamed delta arrived for this part: the update itself
            // carries the text (a complete part, not a streamed one). Dropping
            // it here would silently lose the model's words. Once per part:
            // text that already streamed stays a single emission.
            if !emittedTextPartIDs.contains(partID),
                let text = part["text"] as? String, !text.isEmpty
            {
                markTextPartEmitted(partID)
                return [.assistantTextDelta(text)]
            }
            return []

        case "reasoning":
            // Tipi geç öğrenilen parçanın deltası tamponda bekliyordu:
            // asistan metni değil, thinking içeriğidir.
            if let buffered = removeBufferedText(for: partID) {
                markReasoningPartEmitted(partID)
                return [.thinkingDelta(buffered)]
            }
            // Akışsız gelen bütün parça (delta'sız reasoning): metin kanalına
            // düşmeden thinking'e tek seferlik taşınır.
            if !emittedReasoningPartIDs.contains(partID),
                let text = part["text"] as? String, !text.isEmpty
            {
                markReasoningPartEmitted(partID)
                return [.thinkingDelta(text)]
            }
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
            // araç olayları bu eşleme üzerinden üstteki karta yazılır. Hangi
            // aracın delege ettiği tek yüklemden okunur
            // (`ProviderActivityDescriptor.isSubagentTool`): soru yönlendirici
            // de aynısını kullanır, yoksa delege sorular panele hiç çıkmaz.
            let learningEvents: [ProviderEvent]
            if ProviderActivityDescriptor.isSubagentTool(tool),
                let childSessionID = Self.childSessionID(in: state)
            {
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
            let output = Self.toolOutput(from: state)
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
                    markToolPartFinished(partID)
                    var events = learningEvents
                    // Bitince kart adım listesini bırakır: `output` nihai rapordur
                    // ve sağ panelde okunur, kartta değil.
                    if kind == .subagent,
                        let finalOutput = subagentStepsOutput(for: activityID, finished: true)
                    {
                        events.append(
                            .activityUpdated(
                                ProviderActivityDescriptor.sanitizedTool(
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
                    markToolPartFinished(partID)
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
            if let mediaEvents = mediaAttachmentEvents(partType: partType, part: part) {
                return mediaEvents
            }
            return []
        }
    }

    /// `file`/`image` parçası: ekran görüntüsü gibi araç ürünleri ayrı parça
    /// olarak gelebilir. Tek bir computer aracı koşuyorsa başvuru onun
    /// kartına işlenir; kime ait olduğu belli değilse düşer (yanlış karta
    /// yazmaktansa göstermemek yeğdir).
    private mutating func mediaAttachmentEvents(
        partType: String,
        part: [String: Any]
    ) -> [ProviderEvent]? {
        guard partType == "file" || partType == "image" else {
            return nil
        }
        guard let reference = Self.mediaReference(in: part) else {
            return nil
        }
        guard runningToolDescriptors.count == 1,
            let (key, running) = runningToolDescriptors.first,
            running.kind == .computer
        else {
            return nil
        }
        let merged = Self.appendingMediaReference(reference, to: running.output)
        guard merged != running.output else {
            return nil
        }
        let updated = ProviderActivityDescriptor(
            id: running.id,
            kind: running.kind,
            title: running.title,
            detail: running.detail,
            output: merged,
            diff: running.diff
        )
        guard updated != running else {
            return nil
        }
        runningToolDescriptors[key] = updated
        return [.activityUpdated(updated)]
    }

    /// Dosya/görsel parçasındaki başvuru: yol ya da adres, ilk dolu olan.
    static func mediaReference(in part: [String: Any]) -> String? {
        for key in ["url", "path", "filePath", "filename", "name"] {
            if let ref = part[key] as? String,
                !ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return ref
            }
        }
        if let file = part["file"] as? [String: Any] {
            for key in ["url", "path", "filePath", "filename", "name"] {
                if let ref = file[key] as? String,
                    !ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return ref
                }
            }
        }
        return nil
    }

    /// Başvuru zaten çıktıda varsa aynen bırakır (yinelenen parça
    /// güncellemesi kartı şişirmez), yoksa yeni satır olarak ekler.
    static func appendingMediaReference(_ reference: String, to output: String?) -> String? {
        guard let output, !output.isEmpty else {
            return reference
        }
        guard !output.contains(reference) else {
            return output
        }
        return output + "\n" + reference
    }

    /// Araç çıktısı her zaman düz metin gelmez: `computer_screenshot` gibi
    /// araçlar sözlük ya da içerik bloğu döndürebilir. Bilinen şekiller
    /// okunur metne indirgenir; hiçbiri uymazsa `nil` döner.
    static func toolOutput(from state: [String: Any]) -> String? {
        if let output = state["output"], let text = readableToolOutput(output) {
            return text
        }
        if let error = state["error"], let text = readableToolOutput(error) {
            return text
        }
        return nil
    }

    /// Tek bir `output`/`error` değerini okunur metne indirir: düz metin
    /// aynen, sözlükte `text`/`output`/`content` alanı, dizide metin
    /// blokları, dosya başvurusunda (`path`/`url`) başvuru yolu.
    static func readableToolOutput(_ value: Any) -> String? {
        if let text = value as? String {
            return text.isEmpty ? nil : text
        }
        if let dict = value as? [String: Any] {
            for key in ["text", "output", "content", "result"] {
                if let text = dict[key] as? String, !text.isEmpty {
                    return text
                }
            }
            for key in ["path", "filePath", "file", "url", "filename"] {
                if let ref = dict[key] as? String, !ref.isEmpty {
                    return ref
                }
            }
            return nil
        }
        if let items = value as? [Any] {
            let texts = items.compactMap { item -> String? in
                if let text = item as? String, !text.isEmpty {
                    return text
                }
                guard let block = item as? [String: Any] else {
                    return nil
                }
                return readableToolOutput(block)
            }
            guard !texts.isEmpty else {
                return nil
            }
            return texts.joined(separator: "\n")
        }
        return nil
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
        let mark =
            switch step.status {
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

        let singleLine =
            text
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
        finishedToolPartOrder.removeAll()
        emittedTextPartIDs.removeAll()
        emittedTextPartOrder.removeAll()
        emittedReasoningPartIDs.removeAll()
        emittedReasoningPartOrder.removeAll()
        userMessageIDs.removeAll()
        userMessageOrder.removeAll()
        subagentOwnerByChildSession.removeAll()
        subagentTitles.removeAll()
        subagentAgents.removeAll()
        subagentSteps.removeAll()
        subagentStepIndexes.removeAll()
        bufferedChildSteps.removeAll()
        bufferedChildPermissions.removeAll()

        return pendingText + [.completed]
    }

    /// Biten araç parçasını kayda geçirir; kapak aşılırsa en eski düşer.
    private mutating func markToolPartFinished(_ partID: String) {
        guard finishedToolPartIDs.insert(partID).inserted else {
            return
        }
        finishedToolPartOrder.append(partID)
        if finishedToolPartOrder.count > Self.maximumFinishedToolParts {
            finishedToolPartIDs.remove(finishedToolPartOrder.removeFirst())
        }
    }

    /// Yüzeye çıkan metin parçasını kayda geçirir; kapak aşılırsa en eski düşer.
    private mutating func markTextPartEmitted(_ partID: String) {
        guard emittedTextPartIDs.insert(partID).inserted else {
            return
        }
        emittedTextPartOrder.append(partID)
        if emittedTextPartOrder.count > Self.maximumEmittedTextParts {
            emittedTextPartIDs.remove(emittedTextPartOrder.removeFirst())
        }
    }

    /// Yüzeye çıkan reasoning parçasını kayda geçirir; kapak aşılırsa en eski
    /// düşer. Akışlı reasoning hem delta hem bütün-metin güncellemesi taşır;
    /// küme, bütün-metnin akmış içeriği ikinci kez yayınlamasını engeller.
    private mutating func markReasoningPartEmitted(_ partID: String) {
        guard emittedReasoningPartIDs.insert(partID).inserted else {
            return
        }
        emittedReasoningPartOrder.append(partID)
        if emittedReasoningPartOrder.count > Self.maximumEmittedReasoningParts {
            emittedReasoningPartIDs.remove(emittedReasoningPartOrder.removeFirst())
        }
    }

    /// Mesaj kimliğinin rolünü öğrenir; yalnız kullanıcı mesajları işaretlenir.
    ///
    /// Asistan mesajlarını işaretlemeye gerek yok: parçalar zaten varsayılan
    /// olarak asistanındır ve filtrenin fail-open olması, `message.updated`
    /// taşımayan bir akışta modelin kelimelerinin düşmesini engeller.
    ///
    /// Asistan mesajı bitince `info.tokens` (`{input, output, …}`) okunur:
    /// sunucu tarafı oturumun o adımdaki girdi sayımı, bağlam boyutunun
    /// gerçek karşılığıdır. Alan yoksa sessizce boş dönülür.
    private mutating func consumeMessageUpdated(_ properties: [String: Any]) -> [ProviderEvent] {
        guard
            let info = properties["info"] as? [String: Any],
            let messageID = info["id"] as? String,
            let eventSessionID = info["sessionID"] as? String,
            eventSessionID == sessionID,
            let role = info["role"] as? String
        else {
            return []
        }

        guard role == "user" else {
            // Sunucu bilinmeyeni sıfır yazar: girdisi sıfır bildirilen tur
            // "bildirilmedi" demektir, `%0` değil. Sıfırı geçerli saymak
            // halkayı kalıcı `0%`'a kilitliyordu.
            guard
                role == "assistant",
                let tokens = info["tokens"] as? [String: Any],
                let input = Self.tokenCount(tokens["input"]),
                let output = Self.tokenCount(tokens["output"]),
                input > 0
            else {
                return []
            }
            return [.turnUsage(TurnTokenUsage(inputTokens: input, outputTokens: output))]
        }

        guard userMessageIDs.insert(messageID).inserted else {
            return []
        }
        userMessageOrder.append(messageID)
        if userMessageOrder.count > Self.maximumTrackedUserMessages {
            userMessageIDs.remove(userMessageOrder.removeFirst())
        }
        return []
    }

    /// SSE gövdesi `JSONSerialization` ile açılır: sayılar `NSNumber`
    /// (`Int`/`Double`) gelir. Üç hâl de toleranslı okunur.
    private static func tokenCount(_ value: Any?) -> Int? {
        if let number = value as? Int {
            return number >= 0 ? number : nil
        }
        if let number = value as? Double, number.isFinite, number >= 0 {
            return Int(number)
        }
        if let number = value as? NSNumber {
            let int = number.intValue
            return int >= 0 ? int : nil
        }
        return nil
    }

    @discardableResult
    private mutating func removeBufferedText(for partID: String) -> String? {

        bufferedPartOrder.removeAll { $0 == partID }

        guard let text = bufferedTextDeltas.removeValue(forKey: partID) else {
            return nil
        }

        return text.isEmpty ? nil : text
    }

    /// Bayt bütçeli tampon ekleme: bütçe dolunca delta kesilir ve tek
    /// seferlik kesilme işareti konur; sonraki deltalar düşer.
    static func appendingBufferedDelta(_ delta: String, to buffered: String) -> String {
        let marker = "\n… (buffered text truncated)"
        guard !buffered.hasSuffix(marker) else {
            return buffered
        }
        let remaining = maximumBufferedTextBytesPerPart - buffered.utf8.count
        guard remaining > 0 else {
            return buffered + marker
        }
        let deltaBytes = delta.utf8.count
        guard deltaBytes > remaining else {
            return buffered + delta
        }
        let fittingPrefix = String(decoding: delta.utf8.prefix(remaining), as: UTF8.self)
        return buffered + fittingPrefix + marker
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
            let content =
                (input["content"] as? String)
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

        let oldValue =
            (input["oldString"] as? String)
            ?? (input["old_str"] as? String)
            ?? (input["targetContent"] as? String)
            ?? (input["target_content"] as? String)
        let newValue =
            (input["newString"] as? String)
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

        var preview =
            lines
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
        // Ara değişken bilinçli: `??` zincirinin sonucuna doğrudan `?.`
        // eklemek `swift-format` 604'ü `?` ile `.` arasında satır kırmaya
        // itiyor ve ortaya çıkan kod derlenmiyor.
        let rawDescription =
            (input["description"] as? String)
            ?? (input["TaskName"] as? String)
            ?? (input["task_name"] as? String)
            ?? (input["title"] as? String)
        let description = rawDescription?.trimmingCharacters(in: .whitespacesAndNewlines)

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
        case (let agent?, let description?) where !agent.isEmpty && !description.isEmpty:
            title = "Delegated to \(agent): \(description)"
        case (_, let description?) where !description.isEmpty:
            title = "Delegated subagent: \(description)"
        case (let agent?, _) where !agent.isEmpty:
            title = "Delegated to \(agent)"
        default:
            title = nil
        }

        let rawPrompt =
            (input["prompt"] as? String)
            ?? (input["Task"] as? String)
            ?? (input["task"] as? String)
            ?? (input["instructions"] as? String)
        let promptFirstLine =
            rawPrompt
            .flatMap { $0.split(separator: "\n", omittingEmptySubsequences: true).first }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        let detail: String?
        if let promptFirstLine, !promptFirstLine.isEmpty {
            detail =
                promptFirstLine.count > maximumSubagentDetailLength
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
        let rawAgent =
            (input["subagent_type"] as? String)
            ?? (input["agent"] as? String)
            ?? (input["agent_type"] as? String)
        return rawAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Computer-use title and detail with tool and input explicitly provided.
    static func computerTitleAndDetail(
        tool: String,
        input: [String: Any]
    ) -> (String?, String?) {
        ComputerActivityTitle.titleAndDetail(tool: tool, input: input)
    }

    /// Computer-use title and detail without input dictionary.
    static func computerTitleAndDetail(tool: String) -> (String?, String?) {
        computerTitleAndDetail(tool: tool, input: [:])
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

        // Computer-use pointer/keyboard steps: coordinates and key combos.
        if kind == .computer {
            return computerTitleAndDetail(tool: tool, input: input)
        }

        let normalizedTool = tool.lowercased()

        if normalizedTool.contains("bash") || normalizedTool.contains("command") || normalizedTool.contains("exec")
            || normalizedTool.contains("terminal")
        {
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

        if normalizedTool.contains("edit") || normalizedTool.contains("write") || normalizedTool.contains("patch")
            || normalizedTool.contains("replace") || normalizedTool.contains("create")
        {
            let path =
                (input["targetFile"] as? String)
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
