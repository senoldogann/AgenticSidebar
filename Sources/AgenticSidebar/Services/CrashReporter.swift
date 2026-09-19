import Foundation

/// Cihaz-içi çökme yakalama — harici servise hiçbir şey gitmez.
///
/// Üç katman:
/// 1. Yakalanmamış istisna → `NSSetUncaughtExceptionHandler` rapor dosyası
///    yazar (ad, gerekçe, yığın, sürüm).
/// 2. Ölümcül sinyal (`SIGABRT`/`SIGILL`/`SIGSEGV`/`SIGFPE`/`SIGBUS`) →
///    yalnızca async-signal-safe `write()` ile tek satır düşer, ardından
///    varsayılan davranışa dönülüp sinyal yeniden yükseltilir (sistem raporu
///    da üretilir).
/// 3. Temiz-çıkış işareti → güvenilir tespit: açılışta yazılır, zarif
///    kapanışta silinir. Açılışta işaret duruyorsa önceki çalış beklenmedik
///    bitmiştir (çökme ya da `kill -9`).
///
/// Gizlilik: rapora transkript, pano ya da ekran içeriği yazılmaz — yalnızca
/// istisna adı/gerekçesi, sinyal numarası, yığın ve sürüm bilgisi.
enum CrashReporter {
    nonisolated static let crashesDirectoryName = "Crashes"
    nonisolated static let runningMarkerName = "running.marker"
    nonisolated static let signalLogName = "signal.log"
    nonisolated static let reportPrefix = "crash-"
    nonisolated static let hangReportPrefix = "hang-"
    nonisolated static let reportExtension = "log"
    nonisolated static let maximumReports = 20
    /// Tek raporun okuma üst sınırı; üstü kırpılır.
    nonisolated static let maximumReportBytes = 256 * 1024

    /// Bu çalışın başlama anı; `install` sırasında damgalanır.
    nonisolated(unsafe) static var launchDate = Date()

    /// Açılışta, yeni işaret yazılmadan ÖNCE okunan önceki-çalış durumu.
    ///
    /// `install` işareti her açılışta yazar; bu yüzden sonradan dosya
    /// varlığına bakmak her zaman "çöktü" derdi. Doğru değer yalnızca
    /// buradadır; `nil` ise `install` henüz koşmamıştır.
    nonisolated(unsafe) static var previousRunCrashedAtLaunch: Bool?

    static func crashesDirectory() -> URL {
        ManagedAppDirectories.openCodeWorkingDirectory()
            .appendingPathComponent(crashesDirectoryName, isDirectory: true)
    }

    static func markerURL(in directory: URL) -> URL {
        directory.appendingPathComponent(runningMarkerName)
    }

    static func reportFilename(for date: Date, processID: Int32) -> String {
        "\(reportPrefix)\(Self.filenameStamp(for: date))-\(processID)-\(UUID().uuidString.prefix(8)).\(reportExtension)"
    }

    /// Kurulum: dizin + işaret + sinyal günlüğü + işleyiciler. Önceki çalışın
    /// durumu işareti ezmeden ÖNCE `previousRunCrashedAtLaunch` içine alınır.
    static func install(
        in directory: URL = crashesDirectory(),
        fileManager: FileManager = .default
    ) {
        launchDate = Date()
        previousRunCrashedAtLaunch = fileManager.fileExists(
            atPath: markerURL(in: directory).path
        )
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        pruneReports(in: directory, fileManager: fileManager)
        let stamp = ISO8601DateFormatter().string(from: launchDate)
        try? stamp.write(
            to: markerURL(in: directory),
            atomically: true,
            encoding: .utf8
        )
        openSignalLog(in: directory, fileManager: fileManager)
        chainExceptionHandler(directory: directory)
        installSignalHandlers()
    }

    /// Zarif kapanış: işaret silinir, sinyal günlüğü kapatılır.
    static func markCleanExit(
        in directory: URL = crashesDirectory(),
        fileManager: FileManager = .default
    ) {
        closeSignalLog()
        try? fileManager.removeItem(at: markerURL(in: directory))
    }

    static func previousRunCrashed(
        in directory: URL = crashesDirectory(),
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(atPath: markerURL(in: directory).path)
    }

    static func reports(
        in directory: URL = crashesDirectory(),
        fileManager: FileManager = .default
    ) -> [CrashReport] {
        guard
            let names = try? fileManager.contentsOfDirectory(atPath: directory.path)
        else {
            return []
        }
        return
            names
            .filter {
                ($0.hasPrefix(reportPrefix) || $0.hasPrefix(hangReportPrefix))
                    && $0.hasSuffix(".\(reportExtension)")
            }
            .sorted(by: >)
            .compactMap { name in
                let url = directory.appendingPathComponent(name)
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return CrashReport(
                    name: name,
                    url: url,
                    date: values?.contentModificationDate,
                    size: values?.fileSize ?? 0,
                    text: cappedText(at: url)
                )
            }
    }

    static func deleteReport(
        _ report: CrashReport,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: report.url)
    }

    // MARK: - Saf biçimleme (test edilebilir)

    static func filenameStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func formatExceptionReport(
        name: String,
        reason: String?,
        stack: [String],
        appVersion: String,
        date: Date
    ) -> String {
        var lines = [
            "AgenticSidebar crash report",
            "date: \(ISO8601DateFormatter().string(from: date))",
            "app: \(appVersion)",
            "exception: \(name)",
            "reason: \(reason ?? "-")",
            "stack:",
        ]
        lines.append(contentsOf: stack.isEmpty ? ["  (empty)"] : stack.map { "  \($0)" })
        return lines.joined(separator: "\n") + "\n"
    }

    static func signalLine(signal: Int32, date: Date) -> String {
        "fatal signal \(signal) at \(ISO8601DateFormatter().string(from: date))\n"
    }

    // MARK: - Özel

    private static func cappedText(at url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ""
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumReportBytes + 1) else {
            return ""
        }
        var slice = data.prefix(maximumReportBytes)
        // Sınır çok baytlı UTF-8 dizisinin ortasına denk geldiyse strict decode
        // tüm raporu "" yapardı; geçerli sınıra geri çekilip kayıplı çözülür.
        while !slice.isEmpty, String(data: slice, encoding: .utf8) == nil {
            slice = slice.dropLast()
        }
        var text = String(decoding: slice, as: UTF8.self)
        if data.count > maximumReportBytes {
            text += "\n[…kırpıldı]"
        }
        return text
    }

    private static func pruneReports(in directory: URL, fileManager: FileManager) {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        let reports =
            names
            .filter {
                ($0.hasPrefix(reportPrefix) || $0.hasPrefix(hangReportPrefix))
                    && $0.hasSuffix(".\(reportExtension)")
            }
            .sorted(by: >)
        for stale in reports.dropFirst(maximumReports) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(stale))
        }
    }

    private static func chainExceptionHandler(directory: URL) {
        UncaughtExceptionState.directory = directory
        UncaughtExceptionState.previous = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(uncaughtExceptionHandler)
    }

    private static func openSignalLog(in directory: URL, fileManager: FileManager) {
        closeSignalLog()
        let url = directory.appendingPathComponent(signalLogName)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        FatalSignalLog.fileDescriptor = url.path.withCString { path in
            open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        }
    }

    private static func closeSignalLog() {
        if FatalSignalLog.fileDescriptor >= 0 {
            close(FatalSignalLog.fileDescriptor)
            FatalSignalLog.fileDescriptor = -1
        }
    }

    private static func installSignalHandlers() {
        for number in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS] {
            signal(number, fatalSignalHandler)
        }
    }
}

/// Yakalanmış bir çökme raporunun dosya karşılığı.
struct CrashReport: Equatable, Sendable, Identifiable {
    let name: String
    let url: URL
    let date: Date?
    let size: Int
    let text: String

    var id: String { name }
}

/// Yakalanmamış istisna işleyicisinin paylaştığı durum.
///
/// C işleyici bağlam yakalayamaz; dizin ve önceki işleyici burada durur.
/// Tek yazan (`install`), tek okuyan (işleyici).
private enum UncaughtExceptionState {
    nonisolated(unsafe) static var directory: URL?
    nonisolated(unsafe) static var previous: (@convention(c) (NSException) -> Void)?
}

private func uncaughtExceptionHandler(_ exception: NSException) {
    if let directory = UncaughtExceptionState.directory {
        let report = CrashReporter.formatExceptionReport(
            name: exception.name.rawValue,
            reason: exception.reason,
            stack: exception.callStackSymbols,
            appVersion: AppVersionInfo.current,
            date: Date()
        )
        let url = directory.appendingPathComponent(
            CrashReporter.reportFilename(for: Date(), processID: ProcessInfo.processInfo.processIdentifier)
        )
        try? report.write(to: url, atomically: true, encoding: .utf8)
    }
    if let previous = UncaughtExceptionState.previous {
        previous(exception)
    }
}

/// Sinyal işleyicinin yazdığı dosya tanıtıcısı.
///
/// İşleyici C bağlamında çalışır; `nonisolated(unsafe)` ile tek yazan
/// (`install`) / tek okuyan (işleyici) paylaşımı belgelenir.
private enum FatalSignalLog {
    nonisolated(unsafe) static var fileDescriptor: Int32 = -1
}

/// Yalnızca async-signal-safe çağrılar: `write`, `signal`, `raise`.
///
/// Bilerek sabit metin yazılır: `signalLine(signal:date:)` buradan çağrılmaz,
/// çünkü `Date`/`String` biçimlendirme sinyal bağlamında güvenli değildir
/// (tahsis/kilit içerir). Sinyal numarası ve tarih sistem raporundadır.
private func fatalSignalHandler(_ signum: Int32) {
    "AgenticSidebar fatal signal\n".withCString { pointer in
        _ = write(FatalSignalLog.fileDescriptor, pointer, strlen(pointer))
    }
    signal(signum, SIG_DFL)
    raise(signum)
}

/// Uygulama sürümünün tek kaynağı (CrashReporter + DiagnosticsCenter).
enum AppVersionInfo {
    nonisolated static var current: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        switch (short, build) {
        case (let short?, let build?):
            return "\(short) (\(build))"
        case (let short?, nil):
            return short
        default:
            return "unknown"
        }
    }
}
