import AVFoundation
import Foundation
import Speech

/// Besteciye sesle yazma (Faz 0: tıklayarak aç/kapa, Apple Konuşma Tanıma).
///
/// Akış: `requestAuthorization()` (mikrofon + tanıma) → `start(onPartial:)`
/// (kısmi sonuçlar besteciye akar) → `stop()` (nihai metin). Doğrudan
/// `send()` yok; metin yalnızca taslak alanında birikir.
///
/// Kalıcı bas-konuş (hold-Fn/Option) Faz 1'dir: `NativeComposerTextView`
/// yalnızca `keyDown` görür, Fn `flagsChanged` ister ve Option yazmayı bozar.
/// Bu servis o katmandan bağımsızdır.
///
/// Test edilebilirlik: birleştirme mantığı saf `DictationSegmentMerger`
/// içindedir; donanım tarafı (`AVAudioEngine`, `SFSpeechRecognizer`) ince tutulur.
@MainActor
final class SpeechDictationService {
    enum Authorization: Equatable, Sendable {
        case notDetermined
        case denied
        case authorized
    }

    enum DictationError: Error, Equatable {
        case unauthorized
        case recognizerUnavailable
        case audioEngineFailure(String)
        case recognitionFailed(String)
    }

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var merger = DictationSegmentMerger()

    /// Üretimde `nil` (sistem dili); testte enjekte edilebilir.
    init(recognizer: SFSpeechRecognizer? = SFSpeechRecognizer()) {
        self.recognizer = recognizer
    }

    var isRecording: Bool {
        audioEngine.isRunning
    }

    /// Mikrofon + konuşma tanıma izinlerini ister.
    func requestAuthorization() async -> Authorization {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            return speechStatus == .notDetermined ? .notDetermined : .denied
        }
        let micGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        return micGranted ? .authorized : .denied
    }

    /// Tanımayı başlatır; `baseText` imleç öncesi mevcut taslaktır.
    ///
    /// - Parameter onPartial: Her kısmi/nihai sonuçta birleşmiş görünen metin.
    func start(baseText: String, onPartial: @escaping @MainActor (String) -> Void) throws {
        guard recognizer?.isAvailable == true else {
            throw DictationError.recognizerUnavailable
        }
        stopEngine()
        merger = DictationSegmentMerger(baseText: baseText)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Cihaz-içi tanıma mümkünse buluta ses gitmez; yoksa varsayılan akar.
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            stopEngine()
            throw DictationError.audioEngineFailure(error.localizedDescription)
        }

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else {
                return
            }
            Task { @MainActor in
                if let result {
                    onPartial(self.merger.merged(with: result.bestTranscription.formattedString))
                }
                if error != nil || result?.isFinal == true {
                    self.stopEngine()
                }
            }
        }
    }

    /// Tanımayı durdurur; birleşmiş nihai metni döndürür.
    @discardableResult
    func stop() -> String {
        let final = merger.current
        stopEngine()
        return final
    }

    private func stopEngine() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }
}

// MARK: - Saf birleştirme

/// Taban taslak + kısmi tanıma → görünen metin. Kural: taban boş değilse ve
/// kısmi sonuç boş değilse araya tek boşluk konur; kısmi sonuç her seferinde
/// baştan yazılır (artımlı eklenmez), çünkü tanıma aynı cümlenin revizyonunu
/// gönderir.
struct DictationSegmentMerger: Equatable, Sendable {
    private let baseText: String
    private(set) var current: String

    init(baseText: String = "") {
        self.baseText = baseText
        self.current = baseText
    }

    @discardableResult
    mutating func merged(with partial: String) -> String {
        let trimmedBase = baseText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPartial = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (trimmedBase.isEmpty, trimmedPartial.isEmpty) {
        case (true, _):
            current = trimmedPartial
        case (false, true):
            current = trimmedBase
        case (false, false):
            current = trimmedBase + " " + trimmedPartial
        }
        return current
    }
}
