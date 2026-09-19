import Foundation

/// Tek aktif hedefin diskteki karşılığı: koşu fotoğrafı, bütçe ve hangi
/// oturum/dizinde çalıştığı. `GoalRun` + `GoalBudget` zaten `Codable`
/// olduğu için burası düz bir zarftır; sürüm alanı ilerideki şema
/// değişimlerinde eski dosyayı sessizce düşürmeye yarar.
struct GoalStoredRun: Equatable, Sendable, Codable {
    static let currentVersion = 1

    var version: Int
    var run: GoalRun
    var budget: GoalBudget
    var sessionID: UUID
    var speedMode: ResponseSpeedMode
    var mode: AgentMode
    var workingDirectoryPath: String
    /// Kaydetme anında bekleyen iş (`nil` = tur uçuyordu ya da duraklatıldı).
    /// Devamında faz varsayımıyla değil bununla hareket edilir.
    var pendingAction: GoalPendingAction?
    var updatedAt: Date

    init(
        version: Int = GoalStoredRun.currentVersion,
        run: GoalRun,
        budget: GoalBudget,
        sessionID: UUID,
        speedMode: ResponseSpeedMode,
        mode: AgentMode,
        workingDirectoryPath: String,
        pendingAction: GoalPendingAction? = nil,
        updatedAt: Date
    ) {
        self.version = version
        self.run = run
        self.budget = budget
        self.sessionID = sessionID
        self.speedMode = speedMode
        self.mode = mode
        self.workingDirectoryPath = workingDirectoryPath
        self.pendingAction = pendingAction
        self.updatedAt = updatedAt
    }
}

/// Aktif `/goal` koşusunun kalıcılığı: uygulama kapanıp açılsa hedef
/// kaybolmaz, panel kaldığı yerden devam etmeyi önerir. Saf yardımcıdır
/// (G/Ç yalnız verilen URL'de), o yüzden penceresiz test edilir.
///
/// Tek-aktif-hedef kuralı: dosya bir koşu tutar. İkinci bir bölme hedef
/// başlatmak isterse depoda terminal-olmayan koşu görür ve reddedilir;
/// bölmeler arası kilitlenmeye gerek kalmaz.
enum GoalStore {
    static let fileName = "goal-run.json"
    /// Son başarılı hedef dizini: yönetilen dizinde `Package.swift` yoktur,
    /// o yüzden her `/goal` körü körüne orayı verirse görünmez retle düşer.
    /// Kullanıcı bir kez paket klasörü seçince yolu burada durur, sonraki
    /// başlatmalar (geçerliyse) orayı kullanır. Enjekte edilebilir
    /// `UserDefaults` ile test edilir.
    static let preferredDirectoryKey = "goalPackageDirectory"

    /// Kayıtlı paket dizini yolu (`nil` = kayıt yok ya da boş).
    static func preferredPackageDirectory(defaults: UserDefaults = .standard) -> String? {
        guard
            let path = defaults.string(forKey: preferredDirectoryKey),
            !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return path
    }

    static func savePreferredPackageDirectory(_ path: String, defaults: UserDefaults = .standard) {
        defaults.set(path, forKey: preferredDirectoryKey)
    }

    /// Üretimdeki dosya: taslakların yanına, uygulama desteğine.
    static func liveFileURL(fileManager: FileManager = .default) -> URL? {
        guard
            let directory = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            return nil
        }
        return
            directory
            .appendingPathComponent(AppIdentity.name, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func save(_ stored: GoalStoredRun, to url: URL, fileManager: FileManager = .default) throws {
        let data = try JSONEncoder().encode(stored)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: url.path) {
            let previous = try Data(contentsOf: url)
            let decoded = try? JSONDecoder().decode(GoalStoredRun.self, from: previous)
            if decoded?.version != GoalStoredRun.currentVersion {
                // A corrupt or future-version run must not be overwritten. Moving it
                // aside must succeed before we replace the original path.
                let quarantine = url.deletingLastPathComponent().appendingPathComponent(
                    "\(url.deletingPathExtension().lastPathComponent).corrupt-\(UUID().uuidString).\(url.pathExtension)"
                )
                try fileManager.moveItem(at: url, to: quarantine)
            }
        }
        try data.write(to: url, options: .atomic)
    }

    /// Bozuk/uyumsuz dosya `nil` döner. Saf okumadır: dosyayı taşımaz,
    /// silmez. Kurtarma kopyası yalnızca `save` üzerine yazmadan önce
    /// (`save` içindeki karantina) ya da açık `moveAside` çağrısıyla alınır.
    /// `resumeStoredRun` keşif-sonrası-bozulmada tek kurtarılabilir baytları
    /// korumak için bu saflığa güvenir.
    static func load(from url: URL, fileManager: FileManager = .default) -> GoalStoredRun? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        guard
            let stored = try? JSONDecoder().decode(GoalStoredRun.self, from: data),
            stored.version == GoalStoredRun.currentVersion
        else {
            return nil
        }
        return stored
    }

    /// Bozuk dosyayı silmeden kenara alır.
    static func moveAside(at url: URL, fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        let quarantine = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.deletingPathExtension().lastPathComponent).corrupt-\(UUID().uuidString).\(url.pathExtension)"
        )
        try? fileManager.moveItem(at: url, to: quarantine)
    }

    static func clear(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Devam edilebilir koşu: terminal (`done`/`failed`) dosyası devam
    /// değildir. `verifying`/`reviewing`/`fixing` ortasında kapanmışsa
    /// koşu `building` fazına indirgenir — motor o fazlar arası geçici
    /// kapı değerlerini bellekte tutuyordu, diskte yoklar; yeniden
    /// doğrulamadan devam etmek yanlış "yeşil" üretirdi. `paused` aynen
    /// korunur, `planning`/`building`/`decomposing` oldukları gibi döner.
    static func resumableRun(from stored: GoalStoredRun, now: Date) -> GoalStoredRun? {
        if stored.run.isTerminal {
            return nil
        }
        var next = stored
        switch stored.run.phase {
        case .verifying, .reviewing, .fixing:
            next.run.phase = .building
            next.run.log.append(
                GoalLogEntry(
                    date: now,
                    phase: .building,
                    message: "Resumed after relaunch; re-verifying from the build step"
                ))
        case .done, .failed:
            return nil
        case .decomposing, .planning, .building, .paused:
            break
        }
        next.updatedAt = now
        return next
    }
}
