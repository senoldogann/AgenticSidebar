import Foundation
import Observation

/// Tek-tık prompt iyileştirme orkestratörü: taslağı sağlayıcıdaki modelle
/// düzelttirir, akan yanıtı biriktirir, bitince tüketilmeyi bekler.
///
/// Yan soru (`SideQuestionService`) ile aynı sözleşme: transkripte yazmaz,
/// turn makinesine girmez, kuyruğa dokunmaz; meşgul oturumdan da çalışır.
/// Tek uçuşludur: yeni istek eskinin akışını iptal eder. Sonuç besteciye
/// `consumeDone()` ile alınır ve taslağın yerine geçer; hata ana oturuma
/// dokunmaz, çağıran bildirimi gösterir.
@MainActor
@Observable
final class PromptEnhanceService {
    private static let textFlushInterval: Duration = .milliseconds(50)

    enum Phase: Equatable, Sendable {
        case streaming
        case done
        case cancelled
        case failed
    }

    struct ActiveEnhancement: Identifiable, Equatable, Sendable {
        let id: UUID
        let sessionID: UUID
        /// İsteğin açıldığı andaki taslak: bitince üzerine yazma yalnız taslak
        /// hâlâ buysa yapılır (kullanıcının akış sırasındaki yazısı korunur) ve
        /// geri alma (undo) bu metne döner.
        let originalDraft: String
        var enhancedText: String
        var phase: Phase
        var errorText: String?
    }

    private(set) var active: ActiveEnhancement?
    private var streamTask: Task<Void, Never>?
    private var activeStream: ProviderStream?
    private var askGeneration = 0
    @ObservationIgnored private var textAccumulator = StreamingTextAccumulator.empty
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    var isEnhancing: Bool {
        active?.phase == .streaming
    }

    /// Yeni iyileştirme başlatır. Taslak `PromptEnhancer` süzgecinden
    /// geçmediyse çağrı reddedilir (düğme zaten kapalıdır, bu son savunmadır).
    func enhance(
        context: SideQuestionContext,
        sessionID: UUID,
        draft: String,
        speedMode: ResponseSpeedMode,
        mode: AgentMode,
        tagNames: [String] = [],
        attachmentNames: [String] = []
    ) {
        guard PromptEnhancer.isEnhanceable(draft) else {
            return
        }
        cancelStreaming()
        askGeneration &+= 1
        let token = askGeneration
        let trimmedHistory = TranscriptBudget().select(from: context.messages).messages
        let instruction = PromptEnhancer.enhanceInstruction(
            draft: draft,
            mode: mode,
            tagNames: tagNames,
            attachmentNames: attachmentNames
        )
        let query = SideQuestionQuery(
            configuration: context.configuration,
            historyMessages: trimmedHistory,
            activityGroups: context.activityGroups,
            followups: [],
            question: instruction,
            speedMode: speedMode,
            mode: mode,
            contextSummary: context.contextSummary
        )
        active = ActiveEnhancement(
            id: UUID(),
            sessionID: sessionID,
            originalDraft: draft,
            enhancedText: "",
            phase: .streaming
        )
        let runtime = context.runtime
        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if token == self.askGeneration {
                    self.streamTask = nil
                }
            }
            do {
                let stream = try await runtime.answerSideQuestion(query)
                guard token == self.askGeneration else {
                    await stream.cancel()
                    return
                }
                self.activeStream = stream
                for try await event in stream.events {
                    guard !Task.isCancelled, token == self.askGeneration else { break }
                    if case .assistantTextDelta(let text) = event {
                        self.enqueueText(text, token: token)
                    }
                }
                guard token == self.askGeneration else {
                    await stream.cancel()
                    return
                }
                self.activeStream = nil
                self.finishStreaming(token: token)
            } catch is CancellationError {
                guard token == self.askGeneration else { return }
                self.activeStream = nil
                self.flushPendingText(token: token)
                if self.active?.phase == .streaming {
                    self.active?.phase = .cancelled
                }
            } catch {
                guard token == self.askGeneration else { return }
                self.activeStream = nil
                self.flushPendingText(token: token)
                self.active?.phase = .failed
                self.active?.errorText = SideQuestionService.message(for: error)
            }
        }
    }

    /// Bitmiş iyileştirmeyi bir kez verir ve görünür durumu düşürür.
    /// Boş metin tüketilmez (hata sayılır, çağıran bildirir).
    func consumeDone() -> String? {
        guard let current = active, current.phase == .done else {
            return nil
        }
        let text = current.enhancedText.trimmingCharacters(in: .whitespacesAndNewlines)
        active = nil
        return text.isEmpty ? nil : text
    }

    /// Akan isteği durdurur (uzak taraf da kapatılır).
    func cancelStreaming() {
        streamTask?.cancel()
        streamTask = nil
        flushPendingText(token: askGeneration)
        if let stream = activeStream {
            activeStream = nil
            Task { await stream.cancel() }
        }
        if active?.phase == .streaming {
            active?.phase = .cancelled
        }
    }

    /// Görünür durumu düşürür; yeni istek eskisini zaten iptal eder.
    func dismiss() {
        cancelStreaming()
        askGeneration &+= 1
        active = nil
    }

    // MARK: - Özel

    private func finishStreaming(token: Int) {
        guard token == askGeneration, active?.phase == .streaming else {
            return
        }
        flushPendingText(token: token)
        guard active != nil else {
            return
        }
        if (active?.enhancedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) == true {
            active?.phase = .failed
            active?.errorText = "İyileştirme boş döndü; taslak aynen duruyor."
        } else {
            active?.phase = .done
        }
    }

    /// Sağlayıcı çok küçük deltalar yayınlasa bile SwiftUI durumu en fazla
    /// 20 Hz güncellenir. Metin kaybolmaz; akış bitişi ve iptal son tamponu
    /// eşzamanlı boşaltır.
    private func enqueueText(_ delta: String, token: Int) {
        guard token == askGeneration, active?.phase == .streaming else {
            return
        }
        let result = textAccumulator.appending(delta)
        textAccumulator = result.accumulator
        guard result.shouldScheduleFlush else {
            return
        }
        flushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.textFlushInterval)
            } catch is CancellationError {
                return
            } catch {
                assertionFailure("Prompt iyileştirme tampon beklemesi başarısız: \(error)")
                return
            }
            self?.flushPendingText(token: token)
        }
    }

    private func flushPendingText(token: Int) {
        guard token == askGeneration else {
            return
        }
        flushTask?.cancel()
        flushTask = nil
        let result = textAccumulator.draining()
        textAccumulator = result.accumulator
        guard let text = result.text else {
            return
        }
        active?.enhancedText += text
    }
}
