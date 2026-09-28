import Foundation

/// Ana iş parçacığı takılma bekçisi: çökmeden bitmeyen donmaları görünür kılar.
///
/// `CrashReporter` yakalanmamış istisna ve ölümcül sinyali yakalar, ama ana
/// iş parçacığı yanıt vermezken süreç yaşadığı için dosya yazılmaz — donma
/// tanı sisteminde görünmezdi. Bekçi iki bağımsız görevden oluşur: nabız
/// görevi 1 sn'de bir ana iş parçacığına dokunur, izleme görevi son nabzın
/// üzerinden eşik kadar süre geçtiyse raporu YAZAR.
///
/// Eski tek döngülü sürüm raporu ancak `await MainActor.run {}` döndükten
/// sonra yazabiliyordu; yani donma sürerken hiçbir kanıt üretemiyor, uygulama
/// donmuş hâlde sonlandırıldığında geriye hiçbir iz kalmıyordu. Ölçüm artık
/// iki göreve ayrıldı: nabzın ilerleyip ilerlemediği aktördeki zaman
/// damgasından okunur, rapor ana iş parçacığını beklemeden yazılır.
enum MainThreadHangWatchdog {
    nonisolated static let hangPrefix = "hang-"
    nonisolated static let hangExtension = "log"
    nonisolated static let samplePrefix = "sample-"
    nonisolated static let heartbeatInterval: Duration = .seconds(1)
    nonisolated static let hangThresholdSeconds = 5.0
    /// `sample` çıktısının üst sınırı (sn): simgeleme takılırsa bekçi
    /// görevini hapsetmez, süreç sonlandırılır.
    nonisolated static let sampleTimeoutSeconds = 30.0

    /// Eşzamanlı tek `sample` koşar: üst üste donma bölümleri örnekleyiciyi
    /// üst üste yığmaz. Kilit yalnız bayrak içindir, `sample` kilitsiz koşar.
    private static let sampleLock = NSLock()
    nonisolated(unsafe) private static var sampleInFlight = false

    /// Nabız ile izleme arasındaki paylaşılan durum. Aktör olduğu için iki
    /// görev de kilitsiz ve yarışsız okur/yazar.
    ///
    /// Geçen süre monoton saatle (`SuspendingClock`) ölçülür, duvar saatiyle
    /// (`Date`) değil: Mac uyuyup uyanınca duvar saati ileri fırlar, uyku
    /// süresi "999 sn donma" diye raporlanırdı. `SuspendingClock` uykuda
    /// ilerlemez (`ContinuousClock` ilerler — sahte 999/1973 sn raporları
    /// oradan geliyordu), o yüzden rapor yalnız gerçekten yanıt vermeyen ana
    /// iş parçacığı için yazılır. Raporun tarih damgası duvar saatiyle kalır.
    private actor State {
        private var lastPingCompleted: SuspendingClock.Instant
        private var hangActive = false

        init() {
            lastPingCompleted = SuspendingClock().now
        }

        func notePingCompleted() {
            lastPingCompleted = SuspendingClock().now
            hangActive = false
        }

        /// Eşik aşıldıysa geçen süreyi döndürür ve olayı "bildirildi" işaretler;
        /// aynı donma için ikinci kez rapor yazılmaz.
        func noteUnresponsive(now: SuspendingClock.Instant, threshold: TimeInterval) -> TimeInterval? {
            let elapsed = MainThreadHangWatchdog.monotonicSeconds(since: lastPingCompleted, until: now)
            guard elapsed >= threshold, !hangActive else {
                return nil
            }
            hangActive = true
            return elapsed
        }
    }

    /// İki monoton an arasındaki saniye: uyku şişirmez, geriye kaymaz
    /// (negatif fark sıfıra kırpılır). Saf tutulur, doğrudan test edilir.
    nonisolated static func monotonicSeconds(
        since start: SuspendingClock.Instant,
        until end: SuspendingClock.Instant
    ) -> Double {
        let duration = end - start
        guard duration >= .zero else {
            return 0
        }
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// Üretimde `AgenticSidebarApp` açılışında bir kez çağrılır; testler
    /// çağırmaz (arka plan görevi üretir).
    static func start(
        in directory: URL = CrashReporter.crashesDirectory()
    ) -> Task<Void, Never> {
        Task.detached(priority: .background) {
            let state = State()
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await pingLoop(state: state)
                }
                group.addTask {
                    await monitorLoop(state: state, directory: directory)
                }
            }
        }
    }

    /// Ana iş parçacığı yaşıyorsa hemen döner; takılıysa burada bekler ve
    /// `lastPingCompletedAt` ilerlemez — izleme gecikmeyi buradan ölçer.
    private static func pingLoop(state: State) async {
        while !Task.isCancelled {
            await MainActor.run {}
            await state.notePingCompleted()
            try? await Task.sleep(for: heartbeatInterval)
        }
    }

    /// Nabzın gecikmesini ölçer ve eşik aşılır aşılmaz raporu yazar; ana iş
    /// parçacığının açılmasını beklemez.
    private static func monitorLoop(state: State, directory: URL) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: heartbeatInterval)
            guard
                let elapsed = await state.noteUnresponsive(
                    now: SuspendingClock().now,
                    threshold: hangThresholdSeconds
                )
            else {
                continue
            }
            writeHangReport(elapsed: elapsed, in: directory)
            // Donma anındaki ana iş parçacığı yığını `sample` ile alınır:
            // kendi sürecini örneklemek ayrıcalık istemez. Raporun yanına
            // düşer, bir sonraki donmada tıkanıklığın adı dosyadan okunur.
            captureSample(into: directory)
        }
    }

    /// Donma anında ana iş parçacığının yığınını yakalar. Eşzamanlı tek
    /// örnek koşar; `sample` yoksa ya da zaman aşımına uğrarsa sessizce düşer
    /// (donma raporu zaten yazılmıştır).
    private static func captureSample(into directory: URL) {
        let claimed: Bool = sampleLock.withLock {
            guard !sampleInFlight else {
                return false
            }
            sampleInFlight = true
            return true
        }
        guard claimed else {
            return
        }
        Task.detached(priority: .background) {
            defer {
                sampleLock.withLock { sampleInFlight = false }
            }
            let stamp = CrashReporter.filenameStamp(for: Date())
            let pid = ProcessInfo.processInfo.processIdentifier
            let url = directory.appendingPathComponent(
                "\(samplePrefix)\(stamp)-\(pid).txt"
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [String(pid), "1", "-file", url.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else {
                return
            }
            let deadline = Date().addingTimeInterval(sampleTimeoutSeconds)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private static func writeHangReport(elapsed: TimeInterval, in directory: URL) {
        let now = Date()
        let text = formatHangReport(
            unresponsiveSeconds: elapsed,
            appVersion: AppVersionInfo.current,
            date: now
        )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent(
            reportFilename(for: now, processID: ProcessInfo.processInfo.processIdentifier)
        )
        try? text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func reportFilename(for date: Date, processID: Int32) -> String {
        "\(hangPrefix)\(CrashReporter.filenameStamp(for: date))-\(processID).\(hangExtension)"
    }

    static func formatHangReport(
        unresponsiveSeconds: TimeInterval,
        appVersion: String,
        date: Date
    ) -> String {
        [
            "AgenticSidebar hang report",
            "date: \(ISO8601DateFormatter().string(from: date))",
            "app: \(appVersion)",
            String(format: "main-thread unresponsive for: %.1fs", unresponsiveSeconds),
            "note: the matching sample-<stamp>-<pid>.txt (if present) holds the main-thread stack.",
        ].joined(separator: "\n") + "\n"
    }
}
