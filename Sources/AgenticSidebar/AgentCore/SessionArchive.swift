import Foundation

/// What survives a relaunch for one conversation.
///
/// The activity timeline is stored alongside the transcript so the commands a
/// turn ran are still readable after a relaunch; a turn that was still running
/// when the process died cannot be, and is closed on restore.
struct SessionSnapshot: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var configuration: SessionConfiguration?
    var messages: [ChatMessage]
    var activityGroups: [AgentTurnActivityGroup] = []
    /// Kullanıcının verdiği başlık; yoksa otomatik başlık kullanılır.
    var customTitle: String? = nil
    /// Sabitli oturumlar budamada korunur.
    var isPinned: Bool = false
}

extension SessionSnapshot {
    /// Older archives predate the activity timeline, so the key is optional
    /// instead of being required to decode.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            configuration: try container.decodeIfPresent(
                SessionConfiguration.self,
                forKey: .configuration
            ),
            messages: try container.decode([ChatMessage].self, forKey: .messages),
            activityGroups: try container.decodeIfPresent(
                [AgentTurnActivityGroup].self,
                forKey: .activityGroups
            ) ?? [],
            customTitle: try container.decodeIfPresent(String.self, forKey: .customTitle),
            isPinned: try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        )
    }

    /// Trims the snapshot down to what the archive is willing to store: the
    /// newest activity groups, bounded tool results, and no timeline for a
    /// message that is no longer in the transcript.
    func boundedForArchive(
        maximumActivities: Int,
        maximumOutputLength: Int
    ) -> SessionSnapshot {
        var bounded = self
        bounded.activityGroups = activityGroups
            .bounded(
                toActivityCount: maximumActivities,
                anchoredTo: Set(messages.map(\.id))
            )
            .boundingOutputs(to: maximumOutputLength)
        return bounded
    }
}

struct SessionArchive: Codable, Equatable, Sendable {
    static let currentVersion = 3

    var version: Int
    var activeSessionID: UUID
    var sessions: [SessionSnapshot]
}

extension SessionArchive {
    /// Arşivi saklama kurallarına indirger: yalnızca en yeni oturumlar, oturum
    /// başına sınırlı zaman çizelgesi ve sınırlı araç çıktısı.
    func boundedForStorage(
        maximumSessionCount: Int,
        maximumActivities: Int,
        maximumOutputLength: Int
    ) -> SessionArchive {
        var bounded = self

        if bounded.sessions.count > maximumSessionCount {
            // Sabitliler korunur: önce pinsiz en eskiler düşer.
            let sorted = bounded.sessions.sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned {
                    return rhs.isPinned && !lhs.isPinned
                }
                return lhs.createdAt > rhs.createdAt
            }
            bounded.sessions = Array(sorted.prefix(maximumSessionCount))
        }

        bounded.sessions = bounded.sessions.map {
            $0.boundedForArchive(
                maximumActivities: maximumActivities,
                maximumOutputLength: maximumOutputLength
            )
        }

        return bounded
    }

    /// Bayt tavanına sığmayan arşivden atılacak bir sonraki parçayı düşürür:
    /// önce en eski pasif oturum, geriye tek oturum kaldığında onun en eski
    /// mesajları. Düşürülecek bir şey kalmamışsa `nil`.
    ///
    /// Tavan yükleme sırasında uygulanırsa bütün sohbetler tek seferde gider;
    /// bu yüzden sınır verinin üretildiği yerde, yazma anında zorlanır.
    func droppingOldestStoredContent(fraction: Double = 0.1) -> SessionArchive? {
        if sessions.count > 1 {
            let candidates = sessions.filter({ $0.id != activeSessionID })
            // Önce pinsizler arasından en eski düşer; hepsi sabitliyse en eski sabitli düşer.
            let unpinned = candidates.filter({ !$0.isPinned })
            let pool = unpinned.isEmpty ? candidates : unpinned
            if let oldest = pool.min(by: { $0.createdAt < $1.createdAt }) {
                var reduced = self
                reduced.sessions.removeAll { $0.id == oldest.id }
                return reduced
            }
        }

        guard
            var session = sessions.first,
            session.messages.count > 1
        else {
            return nil
        }

        // Her tur bütün yükü yeniden kodlar; sabit %10 kesmek 64 MB'lık bir arşivde
        // onlarca tam kodlama demekti. Kesim, yükün tavanı ne kadar aştığından
        // hesaplanır ve döngü kalanı toparlar.
        let dropCount = max(1, Int(Double(session.messages.count) * fraction))
        session.messages.removeFirst(min(dropCount, session.messages.count - 1))

        let remainingMessageIDs = Set(session.messages.map(\.id))
        session.activityGroups = session.activityGroups.filter {
            remainingMessageIDs.contains($0.anchorMessageID)
        }

        var reduced = self
        reduced.sessions[0] = session
        return reduced
    }
}

/// JSON persistence for the session list.
struct SessionArchiveStore: Sendable {
    /// Only the most recent conversations are kept, so the archive cannot grow
    /// without bound.
    static let maximumSessionCount = 50

    /// Yazılan arşivin bayt tavanı.
    ///
    /// Sınır yazma anında zorlanır: tavana sığmayan arşivden en eski oturumlar,
    /// gerekirse en eski mesajlar düşürülür. Yükleme sırasında bundan büyük bir
    /// dosya görülürse o dosya bu uygulamanın yazdığı arşiv değildir.
    static let maximumArchiveBytes = 64 * 1024 * 1024

    /// Activities stored per conversation, newest first. Combined with the
    /// archive ceiling this keeps the file bounded at roughly 24 MB.
    static let maximumActivitiesPerSession = 120

    /// Characters kept per tool result or change preview.
    static let maximumActivityOutputLength = 4_000

    let fileURL: URL

    /// Kodlama ve disk yazımı burada, ana iş parçacığının dışında yapılır.
    private let writer: SessionArchiveWriter

    private var fileManager: FileManager {
        .default
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.writer = SessionArchiveWriter(fileURL: fileURL)
    }

    /// The application's own archive location.
    static func live() -> SessionArchiveStore? {
        guard
            let directory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            return nil
        }

        let folder = directory.appendingPathComponent(AppIdentity.name, isDirectory: true)
        return SessionArchiveStore(
            fileURL: folder.appendingPathComponent("sessions.json")
        )
    }

    /// Returns the stored archive, or `nil` when there is nothing usable.
    ///
    /// Kullanılamayan her dosya kenara alınır. Yerinde bırakılırsa bir sonraki
    /// yazma onu kalıcı olarak siler; oysa tek bir okuma hatası bütün sohbetleri
    /// kaybetmek için yeterli bir gerekçe değildir.
    func load() -> SessionArchive? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        guard
            let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? Int
        else {
            AppLog.agentSession.error(
                "Session archive attributes are unreadable; keeping it aside and starting empty"
            )
            moveAside()
            return nil
        }

        guard size <= Self.maximumArchiveBytes else {
            // Bu uygulamanın yazdığı arşiv tavanın altında tutulur, yani bu
            // dosya başka bir şey.
            AppLog.agentSession.error(
                "Session archive exceeds \(Self.maximumArchiveBytes, privacy: .public) bytes; keeping it aside and starting empty"
            )
            moveAside()
            return nil
        }

        guard let data = fileManager.contents(atPath: fileURL.path) else {
            AppLog.agentSession.error(
                "Session archive could not be read; keeping it aside and starting empty"
            )
            moveAside()
            return nil
        }

        do {
            let archive = try Self.decoder.decode(SessionArchive.self, from: data)
            guard archive.version <= SessionArchive.currentVersion else {
                AppLog.agentSession.error(
                    "Session archive was written by a newer version; keeping it aside and starting empty"
                )
                moveAside()
                return nil
            }
            return archive
        } catch {
            AppLog.agentSession.error(
                "Session archive could not be decoded; keeping it aside and starting empty"
            )
            moveAside()
            return nil
        }
    }

    /// Arşivi diske yazar.
    ///
    /// Budama, kodlama ve yazmanın tamamı aktörde çalışır: çağıran ana iş
    /// parçacığında olsa bile bu işlerin hiçbiri orada yapılmaz.
    func save(_ archive: SessionArchive) async {
        await writer.write(archive, bounds: Self.bounds)
    }

    private static let bounds = SessionArchiveBounds(
        maximumSessionCount: maximumSessionCount,
        maximumActivities: maximumActivitiesPerSession,
        maximumOutputLength: maximumActivityOutputLength,
        maximumBytes: maximumArchiveBytes
    )

    private func moveAside() {
        let damagedURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("corrupt.json")

        try? fileManager.removeItem(at: damagedURL)
        try? fileManager.moveItem(at: fileURL, to: damagedURL)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Arşivin diske yazılırken uyacağı sınırlar.
struct SessionArchiveBounds: Equatable, Sendable {
    let maximumSessionCount: Int
    let maximumActivities: Int
    let maximumOutputLength: Int
    let maximumBytes: Int
}

/// Arşivi diske yazan aktör.
///
/// `JSONEncoder.encode` ve `Data.write(atomic:)` senkron çağrılardır; oturum
/// servisi ana iş parçacığında olduğu için akış boyunca saniyede birkaç kez
/// bütün arşivi orada kodlamak arayüzü takar. Aktör bu işi ana iş parçacığından
/// çıkarır ve üst üste gelen yazmaları sıraya sokar.
actor SessionArchiveWriter {
    private let fileURL: URL

    /// En son başarıyla yazılan istek; aynı içerik ikinci kez kodlanmaz.
    private var lastWritten: SessionArchive?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func write(_ archive: SessionArchive, bounds: SessionArchiveBounds) {
        guard archive != lastWritten else {
            return
        }

        let bounded = archive.boundedForStorage(
            maximumSessionCount: bounds.maximumSessionCount,
            maximumActivities: bounds.maximumActivities,
            maximumOutputLength: bounds.maximumOutputLength
        )

        do {
            guard
                let fitted = try Self.fitted(
                    bounded,
                    maximumBytes: bounds.maximumBytes
                )
            else {
                AppLog.agentSession.error(
                    "A single conversation does not fit the archive ceiling; the previous archive was kept"
                )
                return
            }

            if fitted.archive != bounded {
                AppLog.agentSession.error(
                    "Archive exceeded its \(bounds.maximumBytes, privacy: .public) byte ceiling; stored \(fitted.archive.sessions.count, privacy: .public) of \(archive.sessions.count, privacy: .public) conversations after dropping the oldest content"
                )
            }

            // Read the payload back before it replaces anything. A valid-JSON
            // record this app itself cannot decode — a new required field, a
            // rename — would otherwise be discovered on the next launch, after the
            // previous archive had already been rewritten and moved aside as
            // corrupt. One extra pass over bytes that were just encoded buys a
            // logged failure instead of a lost transcript; the whole write already
            // runs off the main actor, behind the coalescing debounce.
            guard (try? Self.decoder.decode(SessionArchive.self, from: fitted.data)) != nil else {
                AppLog.agentSession.error(
                    "Refusing to replace the session archive: the encoded payload does not decode; the previous archive was kept"
                )
                return
            }

            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fitted.data.write(to: fileURL, options: .atomic)
            lastWritten = archive
        } catch {
            AppLog.agentSession.error(
                "Session archive could not be written: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Bayt tavanına sığan en büyük arşivi ve kodlanmış hâlini üretir. Tek bir
    /// mesaj bile sığmıyorsa `nil`.
    private static func fitted(
        _ archive: SessionArchive,
        maximumBytes: Int
    ) throws -> (archive: SessionArchive, data: Data)? {
        var candidate = archive
        var data = try encoder.encode(candidate)

        while data.count > maximumBytes {
            guard
                let smaller = candidate.droppingOldestStoredContent(
                    fraction: dropFraction(encodedSize: data.count, ceiling: maximumBytes)
                )
            else {
                return nil
            }
            candidate = smaller
            data = try encoder.encode(candidate)
        }

        return (candidate, data)
    }

    /// Yükün tavanı ne kadar aştığından kesim oranı: iki katı büyükse yarısı düşer,
    /// döngü kalanı toparlar.
    static func dropFraction(encodedSize: Int, ceiling: Int) -> Double {
        let overshoot = (Double(encodedSize) / Double(ceiling)) - 1
        return min(0.5, max(0.1, overshoot + 0.05))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
