import Foundation

/// Bir turun başındaki transkript + depo durumu.
///
/// Kayıt turun kullanıcı mesajı eklenmeden hemen önce alınır: `rewind(to:)`
/// bu noktaya döner. Depo tarafı yalnızca gözlemdir (SHA saklanır, ağaç
/// el değmez); geri sarma transkripti ve zaman çizelgesini budar, dosyaları
/// geri almaz.
struct SessionTurnCheckpoint: Equatable, Sendable, Identifiable {
    /// Kayıt kimliği.
    let id: UUID
    /// Kayıt anı.
    let createdAt: Date
    /// Başlayacak turun kimliği.
    let turnID: UUID
    /// Kayıt anındaki son mesaj (`nil` = boş transkript).
    let throughMessageID: UUID?
    /// Kayıt anındaki depo HEAD'i (`nil` = bilinmiyor ya da depo yok).
    let gitCommitSHA: String?
}

enum SessionCheckpointGit {
    /// Depo HEAD'ini kabuksuz okur: sabit argv, `GitCommandRunner` üstünden.
    ///
    /// Başarısızlık sessizce `nil` döner: depo yoksa, komut tutmazsa ya da
    /// çıktı tam SHA değilse kayıt SHA'sız tutulur, tur engellenmez.
    nonisolated static func headSHA(
        runner: GitCommandRunner,
        directory: URL,
        timeout: TimeInterval = 10
    ) -> String? {
        guard
            let result = try? runner.run(
                executable: "git",
                arguments: ["rev-parse", "HEAD"],
                directory: directory,
                timeout: timeout
            ),
            result.exitCode == 0
        else {
            return nil
        }
        let sha =
            result.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard sha.range(of: "^[0-9a-f]{40}$|^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            return nil
        }
        return sha
    }
}

extension AgentSession {
    /// Bellekte tutulan en fazla tur kaydı: tur başına bir kayıt düşer,
    /// sınırsız liste uzun sohbette büyürdü.
    private static let maximumCheckpoints = 20

    /// Tur başı kayıtları, eskiden yeniye.
    ///
    /// Depo `AgentSession` gövdesindedir (eklenti saklı özellik taşıyamaz);
    /// buradaki yöntemler o depoyu okur/yazar.
    var checkpoints: [SessionTurnCheckpoint] {
        checkpointStorage
    }

    /// Servis katmanının `GitCommandRunner` ile okuyup verdiği son HEAD.
    ///
    /// Koşucu çağrısı ana iş parçacığını tutacağı için oturum git çalıştırmaz;
    /// depo bağını bilen katman (`workingDirectoryPath` sahibi) anlık HEAD'i
    /// buraya yazar, tur başı kaydı onu gömer.
    func noteRepositoryHead(_ sha: String?) {
        let trimmed = sha?.trimmingCharacters(in: .whitespacesAndNewlines)
        lastKnownRepositoryHead = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// Tur başı kaydını alır: kullanıcı mesajından önce çağrılır.
    func recordCheckpoint(turnID: UUID) {
        let checkpoint = SessionTurnCheckpoint(
            id: UUID(),
            createdAt: Date(),
            turnID: turnID,
            throughMessageID: state.messages.last?.id,
            gitCommitSHA: lastKnownRepositoryHead
        )
        checkpointStorage.append(checkpoint)
        if checkpointStorage.count > Self.maximumCheckpoints {
            checkpointStorage.removeFirst(checkpointStorage.count - Self.maximumCheckpoints)
        }
    }

    /// Transkripti verilen tur başı kaydına döndürür.
    ///
    /// Meşgul oturum geri sarılmaz (`false`): önce tur bitmeli ya da iptal
    /// edilmeli, yoksa akan akış budanmış transkriptin üstüne yazardı. Kayıt
    /// bulunamazsa da `false` döner. Başarıda kayıttan sonraki mesajlar ve
    /// onlara çapalı aktivite grupları düşer, sayaç bayatlar, kalıcılık ve
    /// özet bildirilir; dosyalar el değmez (SHA yalnız gözlemdir).
    ///
    /// - Returns: Geri sarma uygulandıysa `true`.
    @discardableResult
    func rewind(to checkpointID: UUID) -> Bool {
        guard !isBusy else {
            return false
        }
        guard let checkpoint = checkpointStorage.first(where: { $0.id == checkpointID }) else {
            return false
        }
        if let throughID = checkpoint.throughMessageID {
            guard let index = state.messages.firstIndex(where: { $0.id == throughID }) else {
                return false
            }
            state.messages.removeSubrange((index + 1)...)
        } else {
            state.messages.removeAll()
        }
        let remainingIDs = Set(state.messages.map(\.id))
        state.activityGroups = state.activityGroups.filter { remainingIDs.contains($0.anchorMessageID) }
        // Geri alınan turların sayımı paydaya vurulmamalı.
        clearReportedUsageForRewind()
        // Kayıt öncesi durumda koşan tur yoktur: durum boşa alınır, yoksa
        // budanmış transkriptin üstünde bitmiş bir turun rozeti kalırdı.
        state.status = .idle
        state.error = nil
        state.completedAt = nil
        // Soru kartı budanan turun sorusu olabilir; takılı kalmamalı.
        state.activeQuestion = nil
        state.isQuestionSubmitting = false
        state.questionSubmissionFailed = false
        // Kuyruk korunur: kullanıcı yazdığını geri yazar, tur bitince koşar.
        noteSummaryChange()
        onImmediatePersistentChange?()
        return true
    }
}
