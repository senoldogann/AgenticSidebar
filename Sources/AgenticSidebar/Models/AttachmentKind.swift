import Foundation

/// Fotoğraf ekinin tür kararı tek yerde durur: besteci, transkript ve
/// önizleme aynı listeyi kullanır, yoksa bir yere eklenen uzantı diğerinde
/// büyük kart olarak kalır.
enum AttachmentKind {
    /// Kare küçük resimle gösterilen dosya uzantıları.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "tiff", "tif", "gif", "heic", "heif", "bmp",
    ]

    static func isImage(url: URL) -> Bool {
        isImage(pathExtension: url.pathExtension)
    }

    static func isImage(path: String) -> Bool {
        isImage(pathExtension: URL(fileURLWithPath: path).pathExtension)
    }

    private static func isImage(pathExtension: String) -> Bool {
        imageExtensions.contains(pathExtension.lowercased())
    }
}
