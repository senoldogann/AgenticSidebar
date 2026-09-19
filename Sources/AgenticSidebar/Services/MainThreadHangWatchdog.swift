import Foundation

/// Ana iş parçacığı takılma bekçisi: çökmeden bitmeyen donmaları görünür kılar.
///
/// `CrashReporter` yakalanmamış istisna ve ölümcül sinyali yakalar, ama ana
/// iş parçacığı yanıt vermezken süreç yaşadığı için dosya yazılmaz — donma
/// tanı sisteminde görünmezdi. Bu bekçi 1sn'de bir ana iş parçacığına nabız
/// gönderir; nabız 5sn'den geç dönerse `hang-*.log` yazar.
/// `CrashReporter.reports` bu önekleri de listeler, o yüzden donmalar
/// Ayarlar → Diagnostics kartında çökmelerle yan yana görünür.
///
/// Ölçüm yöntemi: `await MainActor.run {}` çağrısının dönüş süresi doğrudan
/// ana iş parçacığının yanıt süresidir. Takılma sırasında `await` bloklanır,
/// açılınca geçen süre bilinir — arka plandan yığın almaya gerek yoktur.
/// (Takılı ana iş parçacığının yığınını arka plandan güvenli almak mümkün
/// değildir; tam yığın gerekiyorsa `sample` alınmalıdır.)
enum MainThreadHangWatchdog {
    nonisolated static let hangPrefix = "hang-"
    nonisolated static let hangExtension = "log"
    nonisolated static let heartbeatInterval: Duration = .seconds(1)
    nonisolated static let hangThresholdSeconds = 5.0

    /// Üretimde `AgenticSidebarApp` açılışında bir kez çağrılır; testler
    /// çağırmaz (arka plan görevi üretir).
    static func start(
        in directory: URL = CrashReporter.crashesDirectory()
    ) -> Task<Void, Never> {
        Task.detached(priority: .background) {
            var hangActive = false
            while !Task.isCancelled {
                let pingSent = Date()
                // Ana iş parçacığı yaşıyorsa hemen döner; takılıysa burada
                // bekleriz ve bekleme süresi takılmanın ölçüsü olur.
                await MainActor.run {}
                let elapsed = Date().timeIntervalSince(pingSent)
                if elapsed >= hangThresholdSeconds {
                    if !hangActive {
                        hangActive = true
                        writeHangReport(elapsed: elapsed, in: directory)
                    }
                } else {
                    hangActive = false
                }
                try? await Task.sleep(for: heartbeatInterval)
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

    /// Test edilebilir karar: eşik aşıldıysa ve henüz kayıt düşülmediyse yaz.
    static func hangDetected(unresponsiveSeconds: TimeInterval, hangActive: Bool) -> Bool {
        !hangActive && unresponsiveSeconds >= hangThresholdSeconds
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
