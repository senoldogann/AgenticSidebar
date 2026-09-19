import Foundation

/// Ek dosyaları için paylaşılan atomik yazım ve budama yardımcısı.
///
/// `PastedTextAttachment` ve `DroppedImageAttachment` aynı `prune` mantığını
/// kopyalıyordu; tek kaynak burada yaşar.
enum AttachmentStorage {
    static func writeAtomically(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    static func prune(directory: URL, keeping maximumStoredFiles: Int, fileManager: FileManager = .default) {
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }

        let sorted = entries.sorted {
            modificationDate(of: $0, fileManager: fileManager)
                < modificationDate(of: $1, fileManager: fileManager)
        }

        guard sorted.count > maximumStoredFiles else {
            return
        }

        for stale in sorted.prefix(sorted.count - maximumStoredFiles) {
            try? fileManager.removeItem(at: stale)
        }
    }

    static func modificationDate(of url: URL, fileManager: FileManager = .default) -> Date {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            ?? .distantPast
    }
}
