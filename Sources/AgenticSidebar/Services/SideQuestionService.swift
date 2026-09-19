import Foundation
import Observation

/// Yan soru (`/btw`) orkestratörü: soruyu runtime'a taşır, akan yanıtı
/// panele verir. Transkripte yazmaz, turn makinesine girmez, kuyruğa
/// dokunmaz; meşgul oturumdan da sorulabilir. Tek uçuşludur: yeni soru
/// eskinin akışını iptal eder.
@MainActor
@Observable
final class SideQuestionService {
    private static let answerFlushInterval: Duration = .milliseconds(50)

    enum Phase: Equatable, Sendable {
        case streaming
        case done
        case cancelled
        case failed
    }

    struct ActiveSideQuestion: Identifiable, Equatable, Sendable {
        let id: UUID
        let sessionID: UUID
        let question: String
        var answer: String
        var phase: Phase
        var errorText: String?
    }

    private(set) var active: ActiveSideQuestion?
    private var memory = SideQuestionMemory()
    private var streamTask: Task<Void, Never>?
    private var activeStream: ProviderStream?
    private var askGeneration = 0
    @ObservationIgnored private var answerAccumulator = StreamingTextAccumulator.empty
    @ObservationIgnored private var answerFlushTask: Task<Void, Never>?

    /// Panelin göstereceği tamamlanmış değişimler (yeniden eskiye değil,
    /// sorulma sırasıyla).
    func exchanges(for sessionID: UUID) -> [SideExchange] {
        memory.exchanges(for: sessionID)
    }

    /// Yeni yan soru başlatır. Geçmiş bütçeyle kırpılır, takip-bağlam
    /// bellekten eklenir.
    func ask(
        context: SideQuestionContext,
        sessionID: UUID,
        question: String,
        speedMode: ResponseSpeedMode,
        mode: AgentMode
    ) {
        cancelStreaming()
        askGeneration &+= 1
        let token = askGeneration
        let trimmed = TranscriptBudget().select(from: context.messages).messages
        let query = SideQuestionQuery(
            configuration: context.configuration,
            historyMessages: trimmed,
            activityGroups: context.activityGroups,
            followups: memory.exchanges(for: sessionID),
            question: question,
            speedMode: speedMode,
            mode: mode,
            contextSummary: context.contextSummary
        )
        active = ActiveSideQuestion(
            id: UUID(),
            sessionID: sessionID,
            question: question,
            answer: "",
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
                        self.enqueueAnswer(text, token: token)
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
                self.flushPendingAnswer(token: token)
                if self.active?.phase == .streaming {
                    self.active?.phase = .cancelled
                }
            } catch {
                guard token == self.askGeneration else { return }
                self.activeStream = nil
                self.flushPendingAnswer(token: token)
                self.active?.phase = .failed
                self.active?.errorText = Self.message(for: error)
            }
        }
    }

    /// Akan soruyu durdurur (uzak taraf da kapatılır).
    func cancelStreaming() {
        streamTask?.cancel()
        streamTask = nil
        flushPendingAnswer(token: askGeneration)
        if let stream = activeStream {
            activeStream = nil
            Task { await stream.cancel() }
        }
        if active?.phase == .streaming {
            active?.phase = .cancelled
        }
    }

    /// Paneli kapatır: akış durur, görünür soru düşer. Bellek korunur,
    /// takip sorular bağlamı kaybetmez.
    func dismiss() {
        cancelStreaming()
        askGeneration &+= 1
        active = nil
    }

    /// Bağlam kurulamayan soru (sağlayıcısız oturum gibi) panele hata
    /// olarak taşınır; sessizce yutulmaz.
    func fail(sessionID: UUID, question: String, message: String) {
        cancelStreaming()
        askGeneration &+= 1
        active = ActiveSideQuestion(
            id: UUID(),
            sessionID: sessionID,
            question: question,
            answer: "",
            phase: .failed,
            errorText: message
        )
    }

    /// Oturum silindiğinde belleği düşürür.
    func dropHistory(for sessionID: UUID) {
        memory.drop(sessionID: sessionID)
    }

    // MARK: - Özel

    private func finishStreaming(token: Int) {
        guard token == askGeneration, active?.phase == .streaming else {
            return
        }
        flushPendingAnswer(token: token)
        guard let current = active else {
            return
        }
        if current.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            active?.phase = .failed
            active?.errorText = "The side question came back empty."
        } else {
            memory.append(
                sessionID: current.sessionID,
                exchange: SideExchange(question: current.question, answer: current.answer)
            )
            active?.phase = .done
        }
    }

    /// Sağlayıcı çok küçük deltalar yayınlasa bile SwiftUI durumu en fazla
    /// 20 Hz güncellenir. Metin kaybolmaz; akış bitişi ve iptal son tamponu
    /// eşzamanlı boşaltır.
    private func enqueueAnswer(_ delta: String, token: Int) {
        guard token == askGeneration, active?.phase == .streaming else {
            return
        }
        let result = answerAccumulator.appending(delta)
        answerAccumulator = result.accumulator
        guard result.shouldScheduleFlush else {
            return
        }
        answerFlushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.answerFlushInterval)
            } catch is CancellationError {
                return
            } catch {
                assertionFailure("Yan soru tampon beklemesi başarısız: \(error)")
                return
            }
            self?.flushPendingAnswer(token: token)
        }
    }

    private func flushPendingAnswer(token: Int) {
        guard token == askGeneration else {
            return
        }
        answerFlushTask?.cancel()
        answerFlushTask = nil
        let result = answerAccumulator.draining()
        answerAccumulator = result.accumulator
        guard let text = result.text else {
            return
        }
        active?.answer += text
    }

    /// Sağlayıcı hatası panele taşınır; ana oturuma hiçbir şey olmaz.
    nonisolated static func message(for error: Error) -> String {
        guard let runtimeError = error as? ProviderRuntimeError else {
            return "The side question could not be answered."
        }
        switch runtimeError {
        case .missingCredential:
            return "API anahtarı eksik; Settings'ten ekleyin."
        case .contextLimitExceeded:
            return "Bağlam penceresine sığmadı; daha kısa bir geçmişle deneyin."
        case .unsupported:
            return "Bu sağlayıcı yan soruyu desteklemiyor."
        case .rateLimited:
            return "Sağlayıcı hız sınırı koydu; birazdan deneyin."
        case .unavailable, .executableUnavailable, .startupFailure, .authenticationFailure:
            return "Sağlayıcıya ulaşılamadı."
        case .transport, .unexpectedResponse:
            return "The side question could not be answered."
        }
    }
}
