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
    nonisolated static let heartbeatInterval: Duration = .seconds(1)
    nonisolated static let hangThresholdSeconds = 5.0

    /// Nabız ile izleme arasındaki paylaşılan durum. Aktör olduğu için iki
    /// görev de kilitsiz ve yarışsız okur/yazar.
    private actor State {
        private var lastPingCompletedAt = Date()
        private var hangActive = false

        func notePingCompleted() {
            lastPingCompletedAt = Date()
            hangActive = false
        }

        /// Eşik aşıldıysa geçen süreyi döndürür ve olayı "bildirildi" işaretler;
        /// aynı donma için ikinci kez rapor yazılmaz.
        func noteUnresponsive(now: Date, threshold: TimeInterval) -> TimeInterval? {
            let elapsed = now.timeIntervalSince(lastPingCompletedAt)
            guard elapsed >= threshold, !hangActive else {
                return nil
            }
            hangActive = true
            return elapsed
        }
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
                    now: Date(),
                    threshold: hangThresholdSeconds
                )
            else {
                continue
            }
            writeHangReport(elapsed: elapsed, in: directory)
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
            "note: main-thread stack requires `sample`; this file proves the hang episode.",
        ].joined(separator: "\n") + "\n"
    }
}
