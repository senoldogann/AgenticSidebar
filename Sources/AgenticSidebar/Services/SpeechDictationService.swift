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
    private var inputTapInstalled = false
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var merger = DictationSegmentMerger()
    private var generation = 0
    /// Devam eden tanımanın nesli: iptal edilmiş eski bir görevin geç gelen
    /// geri çağrısı yeni kaydın göstergesini söndüremesin diye her `start`
    /// ve `stop` artırır, geri çağrı yalnız güncel nesilde çalışır.
    /// Test dikişi için `internal`: geri çağrı yönlendirmesi (`handleRecognitionResult`)
    /// ile birlikte test edilir.
    var partialHandler: (@MainActor (String) -> Void)?
    var endedHandler: (@MainActor () -> Void)?

    /// Üretimde `nil` (sistem dili); testte enjekte edilebilir.
    init(recognizer: SFSpeechRecognizer? = SFSpeechRecognizer()) {
        self.recognizer = recognizer
    }

    var isRecording: Bool {
        audioEngine.isRunning
    }

    /// Mikrofon + konuşma tanıma izinlerini ister.
    ///
    /// `nonisolated`: sistem izin geri çağrıları (TCC/XPC) kendi iş parçacığında
    /// koşar; `@MainActor` kapalı bir kapanış orada çalışınca Swift çalışma-anı
    /// tuzağı atıp uygulamayı kapatıyordu (01:18 SIGTRAP). Örnek durumuna
    /// dokunulmadığı için izolasyona gerek yoktur.
    nonisolated func requestAuthorization() async -> Authorization {
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
    /// - Parameter onEnded: Tanıma kendiliğinden bittiğinde (nihai sonuç ya da
    ///   hata) çağrılır; çağıran kayıt göstergesini kapatır. Yalnız bu başlatma
    ///   için çağrılır; eski bir görevin geç geri çağrısı yok sayılır.
    func start(
        baseText: String,
        onPartial: @escaping @MainActor (String) -> Void,
        onEnded: @escaping @MainActor () -> Void
    ) throws {
        guard let recognizer, recognizer.isAvailable else {
            throw DictationError.recognizerUnavailable
        }
        stopEngine()
        merger = DictationSegmentMerger(baseText: baseText)
        generation += 1
        let currentGeneration = generation
        partialHandler = onPartial
        endedHandler = onEnded

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Cihaz-içi tanıma mümkünse buluta ses gitmez; yoksa varsayılan akar.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        Self.installTap(on: audioEngine.inputNode, request: request)
        inputTapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            stopEngine()
            throw DictationError.audioEngineFailure(error.localizedDescription)
        }

        recognitionTask = Self.recognitionTask(
            with: recognizer,
            request: request,
            generation: currentGeneration,
            service: DictationServiceWeakBox(service: self)
        )
    }

    /// Konuşma çerçevesinden gelen sonucu güncel nesilde uygular.
    ///
    /// Çerçevenin verdiği blok izolasyonsuzdur (`recognitionTask`), bu yüzden
    /// karar mantığı burada, `@MainActor` tarafında durur. Test dikişi için
    /// `internal`: donanımsız, doğrudan çağrılarak test edilir.
    func handleRecognitionResult(text: String?, finished: Bool, generation: Int) {
        guard generation == self.generation else {
            return
        }
        if let text, let partialHandler {
            partialHandler(merger.merged(with: text))
        }
        if finished {
            let endedHandler = self.endedHandler
            self.partialHandler = nil
            self.endedHandler = nil
            stopEngine()
            endedHandler?()
        }
    }

    /// Ses tap bloğu ses motorunun gerçek zamanlı iş parçacığında koşar
    /// (`RealtimeMessenger.mServiceQueue`). `@MainActor` bağlamında kurulan
    /// kapanış bu izolasyonu miras alıp orada çalışınca Swift çalışma-anı
    /// tuzağı atıp uygulamayı kapatıyordu (15:55 EXC_BREAKPOINT/SIGTRAP). Bu
    /// yüzden tap `nonisolated` yardımcıda kurulur: blok izolasyonsuzdur,
    /// tuzak kurulmaz. Yerel yakalama aynı zamanda `stopEngine` ile
    /// `nil`leme yarışını da önler.
    nonisolated private static func installTap(
        on inputNode: AVAudioInputNode,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    /// Tanıma geri çağrısı Konuşma çerçevesinin kendi kuyruğunda koşar;
    /// gerekçe tap ile aynıdır (aynı tuzak, ikinci kapanış). Blok `self`'i ya
    /// da `@MainActor` geri çağrıları yakalayamaz (yakalarsa izolasyonu
    /// miras alır); yalnız `Sendable` veri taşıyıp `Task` ile `@MainActor`
    /// tarafa zıplar, karar `handleRecognitionResult` içindedir.
    nonisolated private static func recognitionTask(
        with recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        generation: Int,
        service: DictationServiceWeakBox
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let finished = error != nil || result?.isFinal == true
            Task { @MainActor in
                service.service?.handleRecognitionResult(
                    text: text,
                    finished: finished,
                    generation: generation
                )
            }
        }
    }

    /// Tanımayı durdurur; birleşmiş nihai metni döndürür. Bekleyen geri
    /// çağrıları da geçersiz kılar.
    @discardableResult
    func stop() -> String {
        generation += 1
        partialHandler = nil
        endedHandler = nil
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
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
    }
}

// MARK: - Oturum koruması

/// Konuşma çerçevesine verilen izolasyonsuz blok `self`'i yakalayamaz
/// (yakalarsa `@MainActor` izolasyonunu miras alıp çerçeve kuyruğunda
/// tuzağa düşer); bu zayıf kutu köprüdür. Okuma yalnız `@MainActor` tarafta
/// (`Task` zıplaması içinde) yapılır, o yüzden denetimsiz gönderilebilirlik
/// güvenlidir.
struct DictationServiceWeakBox: @unchecked Sendable {
    weak var service: SpeechDictationService?
}

/// Kayıt sürerken oturum değişirse kısmi sonuçların yanlış taslağa akmasını
/// önleyen koruma: başlayan oturum hâlâ odaktaysa sonuç uygulanır, yoksa
/// kayıt durdurulur.
enum DictationSessionGuard {
    static func shouldApplyPartial(startedSessionID: UUID, currentSessionID: UUID) -> Bool {
        startedSessionID == currentSessionID
    }
}

// MARK: - Saf birleştirme

/// Taban taslak + kısmi tanıma → görünen metin.
///
/// Kural revizyonu yeni cümleden ayırır, çünkü tanıma aynı cümlenin
/// revizyonunu da ("merhaba dün" → "merhaba dünya") yeni cümlenin ilk
/// kısmi sonucunu da ("…cümle bitti" → "ikinci…") aynı kanaldan gönderir.
/// İkisini karıştırmak konuşulan bölümün besteciden silinmesi demekti:
/// yeni cümle, önceki cümlenin üstüne yazılıyordu.
///
/// Değişmez: `dictated` her zaman `lastRaw` ile biter; `HEAD + lastRaw`
/// biçimindedir. Büyüme ve ortadan düzeltme `HEAD + yeniHam` olur, yeni
/// cümle `dictated + " " + yeniHam` diye eklenir.
struct DictationSegmentMerger: Equatable, Sendable {
    private let baseText: String
    private var dictated: String = ""
    private var lastRaw: String = ""
    private(set) var current: String

    init(baseText: String = "") {
        self.baseText = baseText
        self.current = baseText
    }

    @discardableResult
    mutating func merged(with partial: String) -> String {
        let raw = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return current
        }
        if lastRaw.isEmpty {
            dictated = raw
        } else if raw != lastRaw {
            let common = Self.commonPrefixCount(raw, previous: lastRaw)
            if Self.isContinuation(common: common, raw: raw, previous: lastRaw) {
                // Aynı cümlenin revizyonu: örtüşen pencere yenisiyle değişir.
                dictated = String(dictated.dropLast(lastRaw.count)) + raw
            } else {
                // Sıfırlanmış yeni cümle: öncekiler korunur, yenisi eklenir.
                dictated += " " + raw
            }
        }
        lastRaw = raw
        refreshCurrent()
        return current
    }

    private mutating func refreshCurrent() {
        let trimmedBase = baseText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (trimmedBase.isEmpty, dictated.isEmpty) {
        case (true, _):
            current = dictated
        case (false, true):
            current = trimmedBase
        case (false, false):
            current = trimmedBase + " " + dictated
        }
    }

    /// Aynı cümlenin devamı mı, sıfırlanmış yeni cümle mi?
    ///
    /// Kural tutucudur: kısaltan her değişim yeni cümle sayılır. Gerekçe:
    /// yanlışlıkla eklemek (tekrar) zararsızdır, yanlışlıkla silmek
    /// (konuşulan bölümün uçması) veri kaybıdır. Büyük/küçük harf ve
    /// noktalama revizyonları ("güzel" → "Güzel.") yeni cümle değildir:
    /// karşılaştırma katlanır, ekleme özgün metinle yapılır.
    private static func isContinuation(common: Int, raw: String, previous: String) -> Bool {
        guard common * 2 > min(raw.count, previous.count) else {
            return false
        }
        return raw.count >= previous.count - maximumRevisionShrink
    }

    /// Bir-iki kelimelik düzeltme payı: daha büyük kısalma yeni cümledir.
    private static let maximumRevisionShrink = 4

    private static func commonPrefixCount(_ raw: String, previous: String) -> Int {
        raw.commonPrefix(with: previous, options: [.caseInsensitive, .diacriticInsensitive]).count
    }
}
