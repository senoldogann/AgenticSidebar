import Darwin
import Foundation
import Observation

/// Sağ panelde açılan gömülü kabuk: dış süreçle konuşan bağlantı.
///
/// `script -q /dev/null /bin/zsh -il` bir pty ayırır ve borular üzerinden
/// konuşur; böylece süreç içinde `forkpty` yapmadan etkileşimli bir kabuk
/// olur. Çıktıdaki SGR renk/biçim dizileri `styledOutput` hattında korunur
/// (`ls --color`, `git diff` gerçek Terminal'deki gibi görünür); SGR dışı
/// kaçışlar atılır. `vim` gibi tam ekran uygulamalar desteklenmez.
@MainActor
@Observable
final class LocalTerminalService {
    /// Ekranda tutulan karakter üst sınırı (histerezisli budama).
    ///
    /// Her eklemede O(n) kopyadan kaçınmak için üst sınıra (220K) varınca
    /// alt hedefe (150K) inilir, arada budama yapılmaz.
    private nonisolated static let trimHighWaterMark = 220_000
    private nonisolated static let trimTargetLength = 150_000
    /// Geçersiz bayt sayılmasın diye UTF-8 kuyruğu en fazla bu kadar tutulur.
    private nonisolated static let maximumIncompleteTail = 3
    /// Çözülmeyi bekleyen ham çıktı tavanı: tek drain dilimi en fazla bu
    /// kadar bayt çözer; taşan en eski bayt düşer ve not düşülür. MB'lık tek
    /// patlama (`cat` büyük dosya) yoksa tek MainActor diliminde çözülürdü.
    private nonisolated static let maximumBufferedOutputBytes = 1_048_576

    private(set) var output = ""
    /// Renkli/biçimli çıktı: `output` ile aynı metin, SGR koşularıyla.
    /// Düz metin testler ve kopyalama için korunur; yüzey bunu gösterir.
    private(set) var styledOutput = NSAttributedString(string: "")
    private var accumulatedStyledOutput = NSMutableAttributedString()
    private(set) var isRunning = false

    let workingDirectory: URL

    /// Ham dizge değil: `\u{1B}` burada gerçek ESC karakterine çözülür, ICU
    /// deseni gerçek karakterle eşleşir.
    private static nonisolated let ansiPatternSource =
        "\u{1B}\\[[0-9;:?]*[A-Za-z]|\u{1B}\\][^\u{07}]*\u{07}|\u{1B}[()][0-9A-B]|\u{1B}[=>M78]|\u{0F}"

    /// Ham süreç çıktısının çözülme kadansı.
    ///
    /// `readabilityHandler` boru doldukça çağrılır ve her çağrı bir `emitText`
    /// turu — dolayısıyla `styledOutput` için tam bir kopya — üretiyordu. Uzun
    /// bir komutta (220K karaktere kadar biriktiren tamponla) bu quadratic bir
    /// maliyetti. Ham baytlar burada birikir, çözme 40 ms'de bir koşar.
    /// Doğrudan `emitText` çağrıları (bildirimler, testler) senkron kalır.
    private static let drainInterval = Duration.milliseconds(40)

    private var process: Process?
    private var inputPipe: Pipe?
    private var inputWriter: TerminalQueuedInput?
    private var outputHandle: FileHandle?
    /// Henüz çözülmemiş ham çıktı; `drainTask` boşaltır.
    private var pendingRawOutput = Data()
    /// Tavan aşımında düşen bayt olduysa bir sonraki drain'de not düşülür.
    private var didTruncateBufferedOutput = false
    private var drainTask: Task<Void, Never>?
    private var pendingBytes = Data()
    /// Arkada çözülen tek uçuş: iki Task.detached çıktıyı yarışıp sırayı bozmaz.
    private var isDecoding = false
    /// Ekran temizleme/yeniden başlatma arkadan gelen çözümü hükümsüz kılar.
    private var outputGeneration = 0
    /// Süreç biterken çözüm uçuşuyorsa çıkış notu sona kalır, çıktıdan öne geçmez.
    private var pendingExitNotice = false
    private var cachedAnsiPattern: NSRegularExpression?
    /// Biçim durumu parça sınırlarını aşar; SGR kapanışı sonraki parçada
    /// gelebilir, bu yüzden ayrıştırıcı örnek kabuğun ömrü boyunca yaşar.
    private var styleParser = AnsiStyleParser()
    /// Parça sonunda bölünmüş yarım kaçış (`ESC[31` gibi); sonraki parçayla
    /// birleşmeden ayrıştırılmaz, yoksa düz metin olarak sızardı.
    private var styleTail = ""
    /// Boru yazımları buradan geçer: büyük yapıştırma ana iş parçacığını
    /// bloklamasın diye seri kuyrukta yazılır, sıra korunur.
    private let writeQueue = DispatchQueue(label: "AgenticSidebar.terminal.write")

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    /// Var olmayan bir dizinde kabuk başlatılamaz: `Process` o zaman sessizce
    /// ölür ve yüzey boş kalır. Yoklukta geçici dizine düşülür (`/tmp` her
    /// zaman vardır), böylece terminal her zaman görünür bir karşılamayla açılır.
    static nonisolated func effectiveWorkingDirectory(for url: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return url
        }
        return FileManager.default.temporaryDirectory
    }

    /// Kabuk çalışmıyorsa başlatır; çalışıyorsa dokunmaz.
    ///
    /// Tek oturum tek kabuk: aynı sekme aynı pty'yi kullanır, komut başına
    /// süreç doğmaz. Dizin değişince merkez eski kabuğu kapatır, yenisi kurulur.
    func start() {
        guard !isRunning else {
            return
        }
        let directory = Self.effectiveWorkingDirectory(for: workingDirectory)
        let scriptURL = URL(fileURLWithPath: "/usr/bin/script")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            appendNotice("Terminal is not available: /usr/bin/script is missing.\n")
            return
        }
        let process = Process()
        process.executableURL = scriptURL
        process.arguments = ["-q", "/dev/null", "/bin/zsh", "-il"]
        process.currentDirectoryURL = directory
        // Pty çocuğu tüm süreci değil izin listesini alır: kabuktan doğan
        // her süreç anahtarları okuyabilir, o yüzden `GITHUB_TOKEN` gibi
        // sırlar taşınmaz. Boyut yalnız ilk pty boyutudur.
        process.environment = FoundationOpenCodeProcessLauncher.childEnvironment(overrides: [
            "TERM": "xterm-256color",
            "COLUMNS": "120",
            "LINES": "40",
        ])
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        // Hata akışı da aynı boruya gider: gerçek Terminal'de `ls yoklasor`
        // gibi bir hata ekranda görünür; çöpe atılırsa komut sessizce
        // başarısız olmuş gibi durur.
        process.standardError = outputPipe
        process.terminationHandler = { [weak self, weak process] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, let process, self.process === process else {
                    return
                }
                self.handleTermination()
            }
        }
        do {
            try process.run()
        } catch {
            appendNotice("Terminal could not start: \(error.localizedDescription)\n")
            return
        }
        self.process = process
        self.inputPipe = inputPipe
        self.inputWriter = TerminalQueuedInput(handle: inputPipe.fileHandleForWriting, queue: writeQueue)
        isRunning = true
        styleParser = AnsiStyleParser()
        styleTail = ""
        // Eski kabuğun artığı varsa başlıktan önce düşer; uçuşan zincir varsa
        // sırayı bozmamak için dokunulmaz, zincir bitirir.
        flushRawOutput()
        appendNotice("Terminal ready · \(directory.path)\n")
        let outputHandle = outputPipe.fileHandleForReading
        self.outputHandle = outputHandle
        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.enqueueOutput(data)
            }
        }
    }

    /// Ham çıktıyı tampona alır ve çözmeyi kadanslar.
    ///
    /// Tek kabuk oturum boyu yaşar: komut başına süreç doğmaz, yazılar aynı
    /// pty borusuna kuyruklanır (`TerminalQueuedInput`). Dış dizine yazışlarda
    /// onay kartı akışı bu katmanın dışındadır, burada baypas yoktur.
    private func enqueueOutput(_ data: Data) {
        pendingRawOutput.append(data)
        if pendingRawOutput.count > Self.maximumBufferedOutputBytes {
            let overflow = pendingRawOutput.count - Self.maximumBufferedOutputBytes
            pendingRawOutput.removeSubrange(..<overflow)
            didTruncateBufferedOutput = true
        }
        scheduleDrain()
    }

    /// Çözme kadansını kurar: 40 ms'de bir drain koşar.
    private func scheduleDrain() {
        guard drainTask == nil else {
            return
        }
        drainTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.drainInterval)
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            self?.drainOutput()
        }
    }

    /// Ham baytı MainActor dışında yazıya çevirir: pahalı UTF-8 taraması burada,
    /// yalnız ekleme+budama MainActor'da kalır.
    ///
    /// Saf fonksiyondur; durum tutmaz, Task.detached içinden çağrılır. Dönen
    /// `leftover` tamamlanmamış kuyruktur (en fazla 3 bayt), sonraki parçayla
    /// birleşmeyi bekler.
    nonisolated static func decodeBytes(_ combined: Data) -> (text: String, leftover: Data) {
        var buffer = combined
        var out = ""
        out.reserveCapacity(min(buffer.count, maximumBufferedOutputBytes))
        while !buffer.isEmpty {
            let split = UTF8Chunker.longestValidPrefix(in: buffer)
            if split == 0 {
                guard buffer.count > maximumIncompleteTail else {
                    break
                }
                buffer.removeFirst(buffer.count - maximumIncompleteTail)
                continue
            }
            out += String(decoding: buffer.prefix(split), as: UTF8.self)
            buffer.removeSubrange(..<split)
        }
        return (out, buffer)
    }

    private func drainOutput() {
        drainTask?.cancel()
        drainTask = nil
        guard !pendingRawOutput.isEmpty else {
            return
        }
        // Tek uçuş: çözme sürerken yeni veri birikir, bitince yeniden kadanslanır.
        // Yoksa iki Task.detached çıktıyı yarışıp sırayı bozardı.
        guard !isDecoding else {
            scheduleDrain()
            return
        }
        let raw = pendingRawOutput
        pendingRawOutput.removeAll(keepingCapacity: true)
        let showTruncated = didTruncateBufferedOutput
        didTruncateBufferedOutput = false
        // Yarım UTF-8 kuyruğu çözüme katılır: sahiplik göreve geçer.
        let tail = pendingBytes
        pendingBytes.removeAll()
        let generation = outputGeneration
        isDecoding = true
        Task.detached(priority: .utility) { [weak self, tail, raw] in
            let decoded = Self.decodeBytes(tail + raw)
            await MainActor.run { [weak self] in
                self?.applyDecoded(
                    text: decoded.text,
                    leftover: decoded.leftover,
                    showTruncated: showTruncated,
                    generation: generation
                )
            }
        }
    }

    /// Arkada çözülen yazıyı ekrana işler: yalnız ekleme+budama.
    ///
    /// Temizlikten sonra dönen eski çözüm hükümsüzdür, atılır; yoksa temizlenen
    /// ekran dirilirdi. Kuyruk boşalınca bekleyen kapanış artıkları ve çıkış
    /// notu sona düşer.
    private func applyDecoded(text: String, leftover: Data, showTruncated: Bool, generation: Int) {
        isDecoding = false
        guard generation == outputGeneration else {
            if !pendingRawOutput.isEmpty {
                scheduleDrain()
            }
            return
        }
        pendingBytes = leftover
        if showTruncated {
            appendNotice("[…earlier output truncated: burst exceeded 1 MB buffer…]\n")
        }
        if !text.isEmpty {
            emitText(text)
            trimOutput()
        }
        if !pendingRawOutput.isEmpty {
            scheduleDrain()
            return
        }
        if pendingExitNotice {
            pendingExitNotice = false
            flushPendingBytes()
            appendNotice("\n[process exited]\n")
        }
    }

    /// Bekleyen ham çıktıyı hemen çözer: son satırlar kaybolmasın diye süreç
    /// biterken ve kabuk durdurulurken çağrılır.
    ///
    /// Kapanış yolu eşzamanlı kalır; çözüm saf fonksiyondadır, sıcak yol yine
    /// Task.detached içinden aynı işlevi çağırır. Uçuşan çözüm varsa ham veri
    /// zincire kalır, sıra bozulmaz.
    private func flushRawOutput() {
        guard !isDecoding else {
            return
        }
        drainTask?.cancel()
        drainTask = nil
        guard !pendingRawOutput.isEmpty else {
            return
        }
        let raw = pendingRawOutput
        pendingRawOutput.removeAll(keepingCapacity: true)
        let showTruncated = didTruncateBufferedOutput
        didTruncateBufferedOutput = false
        let combined = pendingBytes + raw
        pendingBytes.removeAll()
        let decoded = Self.decodeBytes(combined)
        pendingBytes = decoded.leftover
        if showTruncated {
            appendNotice("[…earlier output truncated: burst exceeded 1 MB buffer…]\n")
        }
        if !decoded.text.isEmpty {
            emitText(decoded.text)
            trimOutput()
        }
    }

    /// Bekleyen ham çıktıyı atar: ekran temizlenirken eski çıktı yazılmaz.
    private func discardRawOutput() {
        drainTask?.cancel()
        drainTask = nil
        pendingRawOutput.removeAll()
        // Atılan verinin tavan notu yeni çıktıya sızmaz.
        didTruncateBufferedOutput = false
    }

    /// Satırı kabuğa gönderir; sonuna yeni satır eklenir.
    func send(_ line: String) {
        let text = line.hasSuffix("\n") ? line : line + "\n"
        if let data = text.data(using: .utf8) {
            enqueueWrite(data)
        }
    }

    /// Ham baytları kabuğa gönderir (tuş vuruşları, kontrol karakterleri).
    func sendData(_ data: Data) {
        enqueueWrite(data)
    }

    /// Ham yazıyı kabuğa aynen yazar; satır sonu eklenmez.
    func sendRaw(_ text: String) {
        sendData(Data(text.utf8))
    }

    /// Ön plandaki komuta Ctrl-C gönderir.
    func interrupt() {
        enqueueWrite(Data([0x03]))
    }

    private func enqueueWrite(_ data: Data) {
        inputWriter?.write(data)
    }

    /// Ekranı temizler; kabuk çalışmaya devam eder.
    ///
    /// Kuşak artar: arkadan dönen eski çözüm hükümsüz kalır, temizlenen ekrana
    /// dirilmez.
    func clear() {
        outputGeneration += 1
        pendingExitNotice = false
        discardRawOutput()
        output = ""
        accumulatedStyledOutput = NSMutableAttributedString()
        styledOutput = NSAttributedString(string: "")
        styleParser = AnsiStyleParser()
        styleTail = ""
        pendingBytes.removeAll()
    }

    /// Kabuğu kapatıp aynı dizinde yeniden başlatır; eski çıktı silinir,
    /// çünkü yeni kabuğun ekranı boş başlar.
    ///
    /// Eski kabuğun uçuşan çözümü kuşağa takılır, yeni kabuğun ekranına sızmaz.
    func restart() {
        stop()
        outputGeneration += 1
        pendingExitNotice = false
        discardRawOutput()
        output = ""
        accumulatedStyledOutput = NSMutableAttributedString()
        styledOutput = NSAttributedString(string: "")
        pendingBytes.removeAll()
        start()
    }

    /// SIGTERM'i yoksayan eski kabuklar; `waitUntilExit` ana iş parçacığını
    /// bloklayamayacağı için ayrı iş parçacığında beklenir.
    private var retiringProcesses: [Process] = []

    /// Kabuğu durdurur; `exit` yazılmışsa süreç zaten bitmiştir.
    ///
    /// Tek oturum tek kabuk: durdurma boruları kapatır, biriken ham veri zincirle
    /// ekrana düşer; komut başına süreç doğmaz. Uçuşan çözüm varsa kuyruk
    /// sahipliği görevdedir, burada temizlenmez.
    func stop() {
        // Kabuk kapanmadan önce üretilmiş son satırlar ekranda kalmalı.
        flushRawOutput()
        outputHandle?.readabilityHandler = nil
        // Okuma ucu kapatılmazsa fd sızar; yeniden başlatmalarda birikir.
        try? outputHandle?.close()
        outputHandle = nil
        inputWriter?.close()
        inputWriter = nil
        if let currentProcess = process, currentProcess.isRunning {
            currentProcess.terminationHandler = nil
            currentProcess.terminate()
            // Beklemeden bırakmak zombi + üst üste binen kabuk demekti.
            // Emekli kümesi referansı tutar, arka plan basamağı SIGKILL
            // sınırıyla biçer; `restart` penceresi artık sınırlıdır.
            retiringProcesses.append(currentProcess)
            Task.detached(priority: .utility) { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                if currentProcess.isRunning {
                    kill(currentProcess.processIdentifier, SIGKILL)
                }
                currentProcess.waitUntilExit()
                await MainActor.run { [weak self] in
                    self?.retiringProcesses.removeAll { $0 === currentProcess }
                }
            }
        }
        process = nil
        inputPipe = nil
        // Uçuşan çözüm kuyruğu sahiplendi: temizlemek sırayı bozar, zincir bitirir.
        if !isDecoding {
            pendingBytes.removeAll()
        }
        isRunning = false
    }

    /// Kabuk kendiliğinden bitti: borular kapanır, kalan çıktı zincirle düşer.
    ///
    /// Çözüm uçuşuyorsa çıkış notu kuyruklanır; yoksa ham veri eşzamanlı çözülür.
    /// Çıkış notu her zaman en sonda, tek parça düşer.
    private func handleTermination() {
        if isDecoding {
            pendingExitNotice = isRunning
            outputHandle?.readabilityHandler = nil
            try? outputHandle?.close()
            outputHandle = nil
            inputWriter?.close()
            inputWriter = nil
            process = nil
            inputPipe = nil
            isRunning = false
            return
        }
        flushRawOutput()
        outputHandle?.readabilityHandler = nil
        try? outputHandle?.close()
        outputHandle = nil
        inputWriter?.close()
        inputWriter = nil
        process = nil
        inputPipe = nil
        flushPendingBytes()
        if isRunning {
            appendNotice("\n[process exited]\n")
        }
        isRunning = false
    }

    /// Kullanıcının görmesi gereken her satır iki hatta da düşer: görünüm
    /// yalnız biçimli hattı gösterir, düz hata yolu (`output` artı `return`)
    /// boş ekran + gri nokta olarak görünürdü.
    private func appendNotice(_ text: String) {
        emitText(text)
    }

    /// Ham yazıyı iki hatta da işler; satır-düzenleme baytları uçbirim
    /// davranışıyla çözülür.
    ///
    /// Kabuk yazdıklarını ham yankılamaz: `zsh` satır düzenleyici her tuşta
    /// satırı baştan çizer (`\r` + yeni içerik, `\x08` + yeniden yazım). Yalın
    /// `\r` satır sonu sayılıp `\n` yapılınca her tuş yeni satır demekti,
    /// `\x08` metinde kalıp görünmez olunca `cd` yazımı `ccd` görünüyordu. Bu
    /// yüzden yalnız `\r\n` ve `\n` satır sonudur; yalın `\r` o anki satırı
    /// baştan yazar, `\x08` satırdaki son karakteri siler, `\x07` düşer. ANSI
    /// SGR durumu parça sınırlarını aşar (`styleParser` + `styleTail` korunur,
    /// yarım kalan dizi iki hatta da sızmaz).
    func emitText(_ text: String) {
        let combined = styleTail + text
        let split = AnsiStyleParser.splitTrailingPartialEscape(combined)
        styleTail = split.pending
        let complete = split.complete
        guard !complete.isEmpty else {
            return
        }
        let fullRange = NSRange(complete.startIndex..., in: complete)
        let matches = compiledAnsiPattern()?.matches(in: complete, range: fullRange) ?? []
        var cursor = complete.startIndex
        for match in matches {
            guard let range = Range(match.range, in: complete) else {
                continue
            }
            if cursor < range.lowerBound {
                processLiteral(String(complete[cursor..<range.lowerBound]))
            }
            styleParser.consumeEscapeSequence(String(complete[range]))
            cursor = range.upperBound
        }
        if cursor < complete.endIndex {
            processLiteral(String(complete[cursor...]))
        }
        trimStyledOutput()
        styledOutput = accumulatedStyledOutput.copy() as? NSAttributedString ?? accumulatedStyledOutput
    }

    /// Kaçışsız yazıyı satır-düzenleme baytlarıyla iki tampona da işler.
    ///
    /// `\r\n`/`\n` satır sonu, yalın `\r` satırı baştan yazma, `\x08` satırın
    /// son karakterini silme, `\x07` zil (çöpe), `\x0B`/`\x0C` satır sonudur.
    /// Yineleme küme (grapheme) üzerinden yapılır: Unicode'a göre `\r\n` tek
    /// kümedir, bu yüzden pty satır sonu ek bakış olmadan tek yakalanır;
    /// buraya düşen `\r` her zaman yalın satırbaşıdır. Düz ve biçimli hat aynı
    /// op'ları aynı sırada görür, ikisi de aynı yerde budanır; bu yüzden iki
    /// hattın metni birebir aynı kalır.
    private func processLiteral(_ literal: String) {
        var run = ""
        func flushRun() {
            guard !run.isEmpty else {
                return
            }
            output += run
            styleParser.append(run, to: accumulatedStyledOutput)
            run = ""
        }
        for character in literal {
            switch character {
            case "\r\n", "\n", "\u{0B}", "\u{0C}":
                flushRun()
                appendNewline()
            case "\r":
                flushRun()
                truncateCurrentLine()
            case "\u{08}":
                flushRun()
                backspaceOnce()
            case "\u{07}":
                break
            default:
                run.append(character)
            }
        }
        flushRun()
    }

    /// İki hattın da o anki satırını baştan yazar: satır içeriği atılır.
    ///
    /// Yalın `\r` böyledir (imleç satır başına döner, devamı üzerine yazılır;
    /// kayan günlükte imleç sütunu tutulmadığı için satır toptan yenilenir).
    /// pty satır sonları her zaman `\r\n` geldiği için gerçek satır sonu
    /// kaybolmaz.
    private func truncateCurrentLine() {
        if let newline = output.lastIndex(of: "\n") {
            output = String(output[...newline])
        } else {
            output = ""
        }
        let styled = accumulatedStyledOutput.string
        if let newline = styled.lastIndex(of: "\n") {
            let keep = NSRange(styled.startIndex...newline, in: styled)
            accumulatedStyledOutput.deleteCharacters(
                in: NSRange(location: keep.length, length: accumulatedStyledOutput.length - keep.length)
            )
        } else {
            accumulatedStyledOutput.deleteCharacters(
                in: NSRange(location: 0, length: accumulatedStyledOutput.length)
            )
        }
    }

    /// Satırın son karakterini siler; satır boşsa dokunmaz.
    ///
    /// `\x08` (geri-al) böyledir: `zsh` satırı yeniden çizerken imleci geri
    /// alıp üzerine yazar. Kayan günlükte üzerine-yazma, sil-ardından-ekle ile
    /// aynı görünür sonucu verir.
    private func backspaceOnce() {
        guard let last = output.last, last != "\n" else {
            return
        }
        output.removeLast()
        let styled = accumulatedStyledOutput.string
        guard !styled.isEmpty, styled.last != "\n" else {
            return
        }
        let keepEnd = styled.index(before: styled.endIndex)
        let keep = NSRange(styled.startIndex..<keepEnd, in: styled)
        accumulatedStyledOutput.deleteCharacters(
            in: NSRange(location: keep.length, length: accumulatedStyledOutput.length - keep.length)
        )
    }

    private func appendNewline() {
        output += "\n"
        styleParser.append("\n", to: accumulatedStyledOutput)
    }

    private func trimStyledOutput() {
        guard accumulatedStyledOutput.length > Self.trimHighWaterMark else {
            return
        }
        let drop = accumulatedStyledOutput.length - Self.trimTargetLength
        accumulatedStyledOutput.deleteCharacters(in: NSRange(location: 0, length: drop))
    }

    private func flushPendingBytes() {
        guard !pendingBytes.isEmpty || !styleTail.isEmpty else {
            return
        }
        // Bekleyen yarım kaçış son parçayla birleşir: tamamlanırsa iki hatta
        // da doğru işlenir (düz hatta atılır, biçimli hatta uygulanır).
        let remainder = styleTail + String(decoding: pendingBytes, as: UTF8.self)
        pendingBytes.removeAll()
        styleTail = ""
        emitText(remainder)
        trimOutput()
    }

    private func trimOutput() {
        let nsString = output as NSString
        guard nsString.length > Self.trimHighWaterMark else {
            return
        }
        let drop = nsString.length - Self.trimTargetLength
        output = nsString.substring(from: drop)
    }

    private func compiledAnsiPattern() -> NSRegularExpression? {
        if let cachedAnsiPattern {
            return cachedAnsiPattern
        }
        let compiled = try? NSRegularExpression(pattern: Self.ansiPatternSource)
        cachedAnsiPattern = compiled
        return compiled
    }

    /// ANSI kaçışlarını atar, satır sonlarını normalize eder.
    nonisolated static func plainText(
        from text: String,
        pattern: NSRegularExpression? = nil
    ) -> String {
        let compiled: NSRegularExpression?
        if let pattern {
            compiled = pattern
        } else {
            compiled = try? NSRegularExpression(pattern: Self.ansiPatternSource)
        }
        var plain = text
        if let compiled {
            let range = NSRange(plain.startIndex..., in: plain)
            plain = compiled.stringByReplacingMatches(
                in: plain,
                range: range,
                withTemplate: ""
            )
        }
        plain = plain.replacingOccurrences(of: "\r\n", with: "\n")
        plain = plain.replacingOccurrences(of: "\r", with: "\n")
        return plain
    }
}

/// Bölme başına terminal yaşam döngüsü: sekme kapanınca kabuk da kapanır,
/// sekme değişiminde kabuk yaşamaya devam eder.
@MainActor
@Observable
final class TerminalServiceCenter {
    private var services: [String: LocalTerminalService] = [:]

    /// Sekme kimliğine ait kabuk; yoksa belirtilen dizinde açılır. Dizin
    /// değişmişse eski kabuk kapatılıp yenisi kurulur, yoksa kullanıcı başka
    /// klasörün kabuğunda yazmaya devam ederdi.
    ///
    /// Görünüm gövdesinden çağrılmaz: gövdede çağırmak gözlenen sözlüğü
    /// render sırasında değiştirir ve aynı kimlikte iki ayrı kabuk doğar —
    /// `onAppear` eski örnekte başlar, yüzey yenisini gösterir (boş ekran).
    /// Gövde dışı ısıtma (`ConversationDetailView.openTerminalInInspector`) ve
    /// `TerminalHostView.onAppear` burayı kullanır.
    func service(for id: String, workingDirectory: URL) -> LocalTerminalService {
        if let existing = services[id], existing.workingDirectory != workingDirectory {
            close(id: id)
        }
        if let existing = services[id] {
            return existing
        }
        let created = LocalTerminalService(workingDirectory: workingDirectory)
        services[id] = created
        return created
    }

    /// Gövde-içi kullanım için salt-okunur bakış: varsa kabuğu döndürür,
    /// yoksa `nil`. Sözlüğe dokunmadığı için render sırasında çağrılması güvenlidir.
    func existing(id: String) -> LocalTerminalService? {
        services[id]
    }

    /// Sekme kapandı: kabuğu durdurup kaydı düşürür.
    func close(id: String) {
        services[id]?.stop()
        services.removeValue(forKey: id)
    }

    /// Bölmedeki tüm kabukları durdurur; bölme kapanırken çağrılır, yoksa
    /// merkez görünümle birlikte düşer ve kabuk süreçleri yetim kalır.
    func closeAll() {
        for id in services.keys {
            services[id]?.stop()
        }
        services.removeAll()
    }
}
