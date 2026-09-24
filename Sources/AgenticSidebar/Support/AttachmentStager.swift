import Foundation

/// Tur başlamadan ekleri tek, kalıcı konuma sabitler.
///
/// Sorun: `ChatMessage` yalnız yol dizgileri taşır; dosya seçiciden gelen yol
/// taşınabilir/silinebilir, `DroppedImages` 50 dosyada budanır, geçici ekran
/// görüntüleri süpürülür. Tur, arşivdeki ölü bir yolu okumaya çalışırsa ajan
/// eki hiç göremez. Bu aşama her eki `SessionAttachments/` altına kopyalar
/// (küçükse) ya da yerinde bırakır (uygulama evindeki ya da büyük dosya) ve
/// tur bundan sonra yalnız dönen yolları kullanır: prompt kurucu, alıntılayan
/// ve arşiv hep aynı, tur başında var olduğu doğrulanmış dosyayı görür.
///
/// Kopya eşiği bilerek ``OpenCodePromptBuilder/maximumInlineAttachmentBytes``
/// ile aynıdır: satır içi gidebilen her dosya kopyalanabilir de; daha
/// büyüğü zaten yoldan okunur, kopyalamak diski şişirirdi.
enum AttachmentStager {
    static let directoryName = "SessionAttachments"

    /// Klasörün üst sınırı; aşınca en eski yazılanlar budanır.
    static let maximumStoredFiles = 200

    /// Bu boyun üstündeki dosyalar kopyalanmaz, yerinde yoldan okunur.
    static let maximumStagedBytes = 10 * 1024 * 1024

    static func directory(baseURL: URL) -> URL {
        baseURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Uygulamanın kendi ek klasörü, uygulama evi dışında `nil`.
    static func liveBaseURL() -> URL? {
        guard
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            return nil
        }

        return support.appendingPathComponent(AppIdentity.name, isDirectory: true)
    }

    /// Yolları tura hazır listeye çevirir: sırayı korur, tekrarı ve
    /// kaybolmuş dosyayı düşürür.
    ///
    /// `baseURL` `nil` ise (test dışı gerçek dışı durum) liste yalnızca
    /// kayıp-dosya temizliğinden geçer; kopya yapılmaz.
    static func stage(
        paths: [String],
        sessionID: UUID,
        date: Date,
        uniquifier: String,
        fileManager: FileManager,
        baseURL: URL?
    ) -> [String] {
        var staged: [String] = []
        var seen = Set<String>()
        guard let baseURL else {
            for path in paths {
                if seen.insert(path).inserted, fileExists(atPath: path, fileManager: fileManager) {
                    staged.append(path)
                }
            }
            return staged
        }

        let folder = directory(baseURL: baseURL)
        var copiedAnything = false
        for path in paths {
            if seen.contains(path) {
                continue
            }
            seen.insert(path)
            guard fileExists(atPath: path, fileManager: fileManager) else {
                continue
            }
            if let stagedCopy = stagedCopy(
                ofPath: path,
                sessionID: sessionID,
                date: date,
                uniquifier: uniquifier,
                folder: folder,
                baseURL: baseURL,
                fileManager: fileManager
            ) {
                staged.append(stagedCopy.url.path)
                if stagedCopy.didCopy {
                    copiedAnything = true
                }
            }
        }
        if copiedAnything {
            AttachmentStorage.prune(
                directory: folder,
                keeping: maximumStoredFiles,
                fileManager: fileManager
            )
        }
        return staged
    }

    /// Tek dosyanın tur kopyası: uygulama evindekiler ve büyük dosyalar
    /// yerinde kalır, küçük dış dosyalar klasöre kopyalanır.
    private static func stagedCopy(
        ofPath path: String,
        sessionID: UUID,
        date: Date,
        uniquifier: String,
        folder: URL,
        baseURL: URL,
        fileManager: FileManager
    ) -> (url: URL, didCopy: Bool)? {
        let sourceURL = URL(fileURLWithPath: path)
        let managedRoot = baseURL.standardized.path
        if sourceURL.standardized.path.hasPrefix(managedRoot + "/") {
            return (sourceURL, false)
        }
        if fileSize(atPath: path, fileManager: fileManager) > maximumStagedBytes {
            return (sourceURL, false)
        }
        do {
            try fileManager.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let target = folder.appendingPathComponent(
                stagedFileName(
                    sourceURL: sourceURL,
                    sessionID: sessionID,
                    date: date,
                    uniquifier: uniquifier
                )
            )
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: sourceURL, to: target)
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: target.path
            )
            return (target, true)
        } catch {
            return (sourceURL, false)
        }
    }

    /// `a1b2c3d4-ekran-goruntusu-20260924-171300-e4f1a2.png`: oturum öneki
    /// aynı turdaki çakışmayı, damga sıralamayı, tekilleştirici
    /// aynı-saniye çakışmasını çözer. Uzantısız dosya uzantısız kalır
    /// (`README`, `Dockerfile`): türü içerik belirler, ad değil.
    static func stagedFileName(
        sourceURL: URL,
        sessionID: UUID,
        date: Date,
        uniquifier: String
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: date)
        let sessionPrefix = String(sessionID.uuidString.prefix(8)).lowercased()
        let stem = DroppedImageAttachment.sanitizedFileStem(
            sourceURL.deletingPathExtension().lastPathComponent
        )
        let base = "\(sessionPrefix)-\(stem)-\(stamp)-\(uniquifier)"
        let fileExtension = sourceURL.pathExtension
        if fileExtension.isEmpty {
            return base
        }
        return "\(base).\(fileExtension)"
    }

    private static func fileExists(atPath path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return !isDirectory.boolValue
    }

    private static func fileSize(atPath path: String, fileManager: FileManager) -> Int {
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: path),
            let size = SessionArchiveStore.fileSize(from: attributes[.size])
        else {
            return .max
        }
        return size
    }
}
