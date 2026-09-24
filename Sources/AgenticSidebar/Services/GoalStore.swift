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

/// Aktif `/goal` koşularının kalıcılığı: uygulama kapanıp açılsa hedef
/// kaybolmaz, panel kaldığı yerden devam etmeyi önerir. Saf yardımcıdır
/// (G/Ç yalnız verilen URL'de), o yüzden penceresiz test edilir.
///
/// Çoklu-goal kuralı: her sohbet kendi dosyasında koşar
/// (`goal-run-<oturum>.json`). Farklı oturumlar birbirini engellemez; aynı
/// oturumda ikinci koşu reddedilir (tek transkripte tek döngü). Bölmeler arası
/// kilitlenmeye gerek kalmaz.
enum GoalStore {
    /// Miras tek-dosya adı: çoklu-goal öncesi sürümler tüm uygulamayı bu
    /// dosyayla kilitliyordu. Artık oturum başına dosya kullanılır; bu ad
    /// yalnız migration ve eski testler içindir.
    static let fileName = "goal-run.json"
    static let filePrefix = "goal-run"
    static let fileExtension = "json"
    /// Son başarılı hedef dizini: yönetilen dizinde proje işareti yoktur,
    /// o yüzden her `/goal` körü körüne orayı verirse görünmez retle düşer.
    /// Kullanıcı bir kez proje klasörü seçince yolu burada durur, sonraki
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

    /// Üretim dizini: tüm goal dosyalarının (oturum başına) durduğu klasör.
    static func directoryURL(fileManager: FileManager = .default) -> URL? {
        guard
            let directory = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            return nil
        }
        return directory.appendingPathComponent(AppIdentity.name, isDirectory: true)
    }

    /// Oturum başına dosya adı: `goal-run-<oturum-uuid>.json`. Farklı
    /// sohbetler/bölmeler birbirini kilitlemeden eşzamanlı goal koşar; aynı
    /// sohbet hâlâ tek koşuyla sınırlıdır (aynı transkripte iki döngü yazılmaz).
    static func fileName(for sessionID: UUID) -> String {
        "\(filePrefix)-\(sessionID.uuidString.lowercased()).\(fileExtension)"
    }

    /// Üretimdeki oturum dosyası: her sohbet kendi koşusunu kendi dosyasında tutar.
    static func liveFileURL(for sessionID: UUID, fileManager: FileManager = .default) -> URL? {
        guard let directory = directoryURL(fileManager: fileManager) else {
            return nil
        }
        return directory.appendingPathComponent(fileName(for: sessionID))
    }

    /// Miras tek-dosya yolu (`goal-run.json`): yeni kod yazmaz, yalnız
    /// migration ve geriye uyumluluk için okur.
    static func legacyFileURL(fileManager: FileManager = .default) -> URL? {
        guard let directory = directoryURL(fileManager: fileManager) else {
            return nil
        }
        return directory.appendingPathComponent(fileName)
    }

    /// Üretimdeki dosya: taslakların yanına, uygulama desteğine.
    /// Miras yolu döner (`legacyFileURL` ile aynı); yeni başlatmalar
    /// `liveFileURL(for:)` kullanmalıdır.
    static func liveFileURL(fileManager: FileManager = .default) -> URL? {
        legacyFileURL(fileManager: fileManager)
    }

    /// Miras tek-dosyayı oturum dosyasına taşır (bir kez): eski sürümden
    /// kalan terminal-olmayan koşu yeni düzende sahibinin dosyasında yaşar,
    /// miras dosya kalkar. Bozuk miras dosya kurtarmaya alınır (silinmez) ki
    /// yeni `/goal`ların önü açılsın. Taşınan/hedef dosyanın URL'sini döner,
    /// yapacak iş yoksa `nil`.
    @discardableResult
    static func migrateLegacyIfNeeded(fileManager: FileManager = .default) -> URL? {
        guard let legacy = legacyFileURL(fileManager: fileManager) else {
            return nil
        }
        guard fileManager.fileExists(atPath: legacy.path) else {
            return nil
        }
        guard let stored = load(from: legacy, fileManager: fileManager) else {
            moveAside(at: legacy, fileManager: fileManager)
            return nil
        }
        guard let destination = liveFileURL(for: stored.sessionID, fileManager: fileManager) else {
            return nil
        }
        if destination.path == legacy.path {
            return destination
        }
        if fileManager.fileExists(atPath: destination.path) {
            // Hedefte zaten koşu var: miras kopya silinir, hedef korunur.
            try? fileManager.removeItem(at: legacy)
            return destination
        }
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: legacy, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Dizindeki tüm goal dosyaları (miras + oturum dosyaları).
    static func storeURLs(in directory: URL, fileManager: FileManager = .default) -> [URL] {
        let contents =
            (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []
        return contents.filter {
            $0.lastPathComponent.hasPrefix(filePrefix)
                && $0.pathExtension == fileExtension
        }.sorted { $0.path < $1.path }
    }

    /// Dizindeki tüm okunabilir koşular (terminal dahil, kurtarma/teşhis için).
    static func allStoredRuns(in directory: URL, fileManager: FileManager = .default) -> [GoalStoredRun] {
        storeURLs(in: directory, fileManager: fileManager).compactMap {
            load(from: $0, fileManager: fileManager)
        }
    }

    /// Dizindeki terminal-olmayan (aktif) koşular: çoklu-goal tanılama özeti buradan beslenir.
    static func activeStoredRuns(in directory: URL, fileManager: FileManager = .default) -> [GoalStoredRun] {
        allStoredRuns(in: directory, fileManager: fileManager).filter { !$0.run.isTerminal }
    }

    /// Üretim dizinindeki aktif koşular (uygulama desteği).
    static func activeStoredRunsLive(fileManager: FileManager = .default) -> [GoalStoredRun] {
        guard let directory = directoryURL(fileManager: fileManager) else {
            return []
        }
        return activeStoredRuns(in: directory, fileManager: fileManager)
    }

    static func save(_ stored: GoalStoredRun, to url: URL, fileManager: FileManager = .default) throws {
        let data = try JSONEncoder().encode(stored)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
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
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
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
