import Foundation
import UniformTypeIdentifiers

/// Sürükle-bırak ile gelen ham görüntü verisi dosya eki olur.
///
/// macOS ekran görüntüsü önizleme küçük resmi (sağ alttaki yüzen thumbnail)
/// sürüklendiğinde pano dosya URL'si vermez, yalnızca görüntü verisi
/// (`public.tiff` vb.) verir. Eskiden `onDrop` yalnız `.fileURL` kabul ettiği
/// için bu bırakma sessizce reddediliyordu. Veri burada kalıcı bir dosyaya
/// yazılır ve normal ek gibi yola bağlanır: taslak deposu yolları sakladığı
/// için geçici dosya yeniden başlatmada kaybolamazdı.
enum DroppedImageAttachment {
    /// Kaç bırakma klasörü tutulur; fazlası yazarken budanır.
    static let maximumStoredFiles = 50

    static let directoryName = "DroppedImages"

    /// Tür kimliğinden dosya uzantısı: bilinmeyen tür ham yazılır.
    static func fileExtension(forTypeIdentifier typeIdentifier: String) -> String {
        if let type = UTType(typeIdentifier) {
            if type.conforms(to: .png) { return "png" }
            if type.conforms(to: .jpeg) { return "jpg" }
            if type.conforms(to: .tiff) { return "tiff" }
            if type.conforms(to: .gif) { return "gif" }
            if type.conforms(to: .heic) { return "heic" }
            if type.conforms(to: .webP) { return "webp" }
            if type.conforms(to: .bmp) { return "bmp" }
        }
        return "png"
    }

    /// `screenshot-20260916-171300-a1b2c3.png`: sıralanabilir, yazı başına tekil.
    ///
    /// `suggestedName` sürükleme kaynağından gelir (saldırgan-etkili olabilir):
    /// `lastPathComponent` alınır, izinli karakterler dışındakiler `_` olur,
    /// uzunluk sınırlanır. `/` ve `..` korunmaz, yalıtım klasörü dışına
    /// yazılamaz.
    static func fileName(
        suggestedName: String? = nil,
        typeIdentifier: String? = nil,
        date: Date = Date(),
        uniquifier: String = defaultUniquifier()
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: date)
        let ext = fileExtension(forTypeIdentifier: typeIdentifier ?? UTType.png.identifier)
        if let suggested = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !suggested.isEmpty
        {
            let base = (suggested as NSString).deletingPathExtension
            let clean = sanitizedFileStem(base)
            return "\(clean)-\(stamp)-\(uniquifier).\(ext)"
        }
        return "screenshot-\(stamp)-\(uniquifier).\(ext)"
    }

    /// Dosya gövdesini güvenli kümeye indirger: yol ayraçları ve `..`
    /// elenir, boş sonuç `"screenshot"` olur, uzunluk 64 karakterle sınırlıdır.
    static func sanitizedFileStem(_ raw: String) -> String {
        let leaf = (raw as NSString).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let mapped = leaf.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let collapsed = String(mapped).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        guard !trimmed.isEmpty else {
            return "screenshot"
        }
        return String(trimmed.prefix(64))
    }

    static func defaultUniquifier() -> String {
        String(UUID().uuidString.prefix(6)).lowercased()
    }

    static func directory(baseURL: URL) -> URL {
        baseURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Uygulamanın kendi bırakılan-görüntü klasörü, uygulama evi dışında `nil`.
    static func liveDirectory() -> URL? {
        guard
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            return nil
        }

        return directory(
            baseURL: support.appendingPathComponent(AppIdentity.name, isDirectory: true)
        )
    }

    /// Veriyi yalıtılmış bir alt klasöre yazar, eskileri budar, URL döner.
    ///
    /// Yazma başarısız olursa hata fırlatır; arayan bırakmayı yok sayar.
    @discardableResult
    static func save(
        _ data: Data,
        suggestedName: String? = nil,
        typeIdentifier: String? = nil,
        date: Date = Date(),
        uniquifier: String = defaultUniquifier(),
        fileManager: FileManager = .default,
        baseURL: URL? = liveDirectory()
    ) throws -> URL {
        guard let baseURL else {
            throw DroppedImageAttachmentError.noStorageLocation
        }
        guard !data.isEmpty else {
            throw DroppedImageAttachmentError.emptyData
        }

        let baseFolder = directory(baseURL: baseURL)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let itemFolder = baseFolder.appendingPathComponent(
            "drop-\(formatter.string(from: date))-\(uniquifier)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: itemFolder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let url = itemFolder.appendingPathComponent(
            fileName(
                suggestedName: suggestedName,
                typeIdentifier: typeIdentifier,
                date: date,
                uniquifier: uniquifier
            )
        )
        try AttachmentStorage.writeAtomically(data, to: url, fileManager: fileManager)

        prune(directory: baseFolder, fileManager: fileManager)
        return url
    }

    private static func prune(directory: URL, fileManager: FileManager) {
        AttachmentStorage.prune(directory: directory, keeping: maximumStoredFiles, fileManager: fileManager)
    }

    private static func modificationDate(of url: URL, fileManager: FileManager) -> Date {
        AttachmentStorage.modificationDate(of: url, fileManager: fileManager)
    }
}

enum DroppedImageAttachmentError: Error, Equatable {
    case noStorageLocation
    case emptyData
}
