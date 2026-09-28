import Foundation

/// Simülatör panelinin tek satırlık durum özeti.
///
/// Servisten kopyayla alınır; `Sendable` ve `Equatable` olduğu için aktör
/// sınırından güvenle geçer ve değişim karşılaştırması ucuzdur. Alanlar
/// panelin o anki kararlarını aynalar: cihaz açık mı, pencere akışı tuttu
/// mu, dokunma köprüsü hazır mı, hangi araç zinciri ve çalışma zamanı
/// seçili.
struct SimulatorDiagnostics: Equatable, Sendable {
    /// Seçili cihaz açık durumda.
    let booted: Bool
    /// Canlı pencere akışı kare veriyor.
    let windowFound: Bool
    /// Akış evresinin kısa adı: `active`, `starting`, `idle`, `denied`,
    /// `unavailable`. İleti taşınmaz, log satırı kararlı kalır.
    let streamPhase: String
    /// Son dokunuş hatasızsa hazır.
    let hidReady: Bool
    /// Son dokunuş hatası; hatasızken `nil`.
    let lastHIDError: String?
    /// Etkin geliştirici dizini.
    let xcodePath: String
    /// Seçili cihazın çalışma zamanı; seçim yoksa `-`.
    let runtime: String
    /// Toolchain uyarısı; yoksa `nil`. Özet satırına aynen düşer.
    let transportNote: String?

    /// Tek satırlık özet; durum değişim günlüğünün gövdesidir.
    var summaryLine: String {
        let hid = hidReady ? "ready" : "not-ready"
        let hidDetail = lastHIDError.map { " hidError=\($0)" } ?? ""
        let transportDetail = transportNote.map { " transportNote=\($0)" } ?? ""
        return
            "booted=\(booted) windowFound=\(windowFound) stream=\(streamPhase) hid=\(hid)\(hidDetail)\(transportDetail) xcode=\(xcodePath) runtime=\(runtime)"
    }

    /// Önceki özetle farklıysa tek satır günler, saklanacak özeti döner.
    /// Aynı durum tekrar günlenmez; canlı kare hızında çağrılsa bile günlük
    /// şişmez.
    @discardableResult
    func logIfChanged(since previous: SimulatorDiagnostics?) -> SimulatorDiagnostics {
        if previous != self {
            AppLog.panels.info("Simulator diagnostics: \(self.summaryLine, privacy: .public)")
        }
        return self
    }

    /// Akış evresini kısa kararlı ada indirger; ileti kısmı atılır.
    static func phaseName(for phase: SimulatorLiveStreamPhase) -> String {
        switch phase {
        case .idle:
            return "idle"
        case .starting:
            return "starting"
        case .active:
            return "active"
        case .denied:
            return "denied"
        case .unavailable:
            return "unavailable"
        }
    }

    /// Etkin geliştirici dizinini çözer; `DEVELOPER_DIR` yoksa
    /// `xcode-select` sorulur, o da yoksa bilinen kurulum döner.
    static func resolvedXcodePath() -> String {
        if let configured = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !configured.isEmpty {
            return configured
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                return path
            }
        }
        return "/Applications/Xcode.app/Contents/Developer"
    }
}
