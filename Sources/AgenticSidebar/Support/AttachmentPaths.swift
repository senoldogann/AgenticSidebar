import Foundation

/// Besteleyiciye geri konan ek yollar için enjekte edilebilir filtre.
///
/// `PastedTextAttachment.spill(fileManager:baseURL:)` deseniyle aynı fikir:
/// dosya sistemi doğrudan View gövdesinden değil, varsayılanı `.default` olan
/// bir parametre üzerinden okunur, böylece saf testte taklit edilebilir.
enum AttachmentPaths {
    /// Var olan yolları `URL` listesine çevirir; silinmiş dosyalar sessizce
    /// düşer, çünkü okunamayan bir yol ajana gönderilmemelidir.
    static func existingAttachmentURLs(
        _ paths: [String],
        excluding excluded: Set<String> = [],
        fileManager: FileManager = .default
    ) -> [URL] {
        paths
            .filter { !excluded.contains($0) && fileManager.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}
