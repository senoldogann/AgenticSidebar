import AppKit
import Foundation
import ImageIO
import PDFKit

/// High-performance memory-bounded cache for image and PDF attachment thumbnails.
///
/// Prevents repetitive synchronous disk I/O and large bitmap decoding inside
/// SwiftUI view evaluation bodies during scrolling, typing, or streaming.
/// Cache hits return synchronously; the first miss for a key decodes on a
/// background task and returns `nil` (placeholder) immediately, then bumps
/// `generation` so only the rows waiting on that thumbnail re-render.
@MainActor
@Observable
final class AttachmentPreviewCache {
    static let shared = AttachmentPreviewCache()

    private let imageCache = NSCache<NSString, NSImage>()
    @ObservationIgnored
    private var pdfPageCounts: [URL: Int] = [:]
    private static let maximumPDFPageCountEntries = 200

    /// Bumped whenever a background decode lands. The accessors below read it,
    /// so a view body evaluating them subscribes to exactly this counter and
    /// re-renders when its thumbnail arrives — no caller changes, no polling.
    private(set) var generation = 0

    /// Keys with a decode already in flight; a repeated miss while decoding
    /// returns the placeholder instead of spawning another task.
    @ObservationIgnored
    private var inflight: Set<String> = []

    private static let defaultMaxPixelSize: CGFloat = 520
    private static let memoryCostLimit = 30 * 1024 * 1024  // 30 MB
    private static let maximumItemCount = 50

    init() {
        imageCache.totalCostLimit = Self.memoryCostLimit
        imageCache.countLimit = Self.maximumItemCount
    }

    /// Retrieves or decodes a downsampled thumbnail for an image file.
    ///
    /// Uses ImageIO thumbnail creation to decode only the pixels needed for display,
    /// reducing memory usage by up to 90% compared to loading full-resolution bitmaps.
    /// Cold miss never decodes on the caller: it schedules a background task and
    /// returns `nil` so the row shows its placeholder this frame.
    func imageThumbnail(for url: URL, maxPixelSize: CGFloat) -> NSImage? {
        _ = generation
        let key = Self.cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let cached = imageCache.object(forKey: key) {
            return cached
        }
        scheduleImageDecode(url: url, maxPixelSize: maxPixelSize, key: key)
        return nil
    }

    /// Convenience overload using standard thumbnail dimension.
    func imageThumbnail(for url: URL) -> NSImage? {
        imageThumbnail(for: url, maxPixelSize: Self.defaultMaxPixelSize)
    }

    /// Retrieves or renders a thumbnail for the first page of a PDF document.
    ///
    /// Cold miss behaves like the image path: background render, `nil` now.
    func pdfThumbnail(for url: URL, maxPixelSize: CGFloat) -> NSImage? {
        _ = generation
        let key = Self.cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let cached = imageCache.object(forKey: key) {
            return cached
        }
        schedulePDFDecode(url: url, maxPixelSize: maxPixelSize, key: key)
        return nil
    }

    /// Convenience overload using standard thumbnail dimension.
    func pdfThumbnail(for url: URL) -> NSImage? {
        pdfThumbnail(for: url, maxPixelSize: Self.defaultMaxPixelSize)
    }

    /// Returns cached page count or reads it once from the document.
    ///
    /// Miss opens the document on a background task and returns `nil` now;
    /// callers already fall back (`?? 1`) until the count lands.
    func pdfPageCount(for url: URL) -> Int? {
        _ = generation
        if let count = pdfPageCounts[url] {
            return count
        }
        schedulePDFCount(url: url)
        return nil
    }

    /// Önbellek anahtarı boyutu içerir: aynı dosya çip için 96 px, transkript
    /// için 520 px ve önizleme için 1800 px istenir; anahtar yalnız URL olsaydı
    /// ilk üretilen boyut diğerlerini gölgeler ve büyük görüntü bulanık kalırdı.
    /// Üç kova ile 4 boyut 2 girişe iner: çip (<=128) ve tam (diğerleri).
    private static func cacheKey(for url: URL, maxPixelSize: CGFloat) -> NSString {
        let bucketed: CGFloat = maxPixelSize <= 128 ? 128 : 1024
        return "\(url.path)#\(Int(bucketed))" as NSString
    }

    private func storePDFPageCount(_ count: Int, for url: URL) {
        if pdfPageCounts.count > Self.maximumPDFPageCountEntries {
            // Tek şişmede hepsini silmek yeniden kodlama fırtınası yapar:
            // en eski yarıyı at.
            let sortedKeys = Array(pdfPageCounts.keys).sorted { $0.path < $1.path }
            for key in sortedKeys.prefix(sortedKeys.count / 2 + 1) {
                pdfPageCounts.removeValue(forKey: key)
            }
        }
        pdfPageCounts[url] = count
    }

    /// Clears cached thumbnails and metadata to free memory immediately.
    func clear() {
        imageCache.removeAllObjects()
        pdfPageCounts.removeAll()
        generation += 1
    }

    // MARK: - Background decode

    /// Background decode never touches main-thread state: pure statics decode,
    /// the MainActor hop stores. `NSImage` assembly happens on main; only
    /// pixel decoding (ImageIO/PDFKit, both thread-safe for reading) runs off-main.
    private func scheduleImageDecode(url: URL, maxPixelSize: CGFloat, key: NSString) {
        let keyString = key as String
        guard inflight.insert(keyString).inserted else {
            return
        }
        // `key` (NSString) detach edilmiş gövdeye taşınmaz: çalışma-anında
        // `NSMutableString` olabilir; anahtar içeride saf girdilerden üretilir.
        Task.detached(priority: .userInitiated) {
            let decoded = Self.decodedImageThumbnail(url: url, maxPixelSize: maxPixelSize)
            await MainActor.run {
                let cache = AttachmentPreviewCache.shared
                cache.inflight.remove(keyString)
                guard let decoded else {
                    return
                }
                let image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
                cache.imageCache.setObject(
                    image,
                    forKey: Self.cacheKey(for: url, maxPixelSize: maxPixelSize),
                    cost: decoded.width * decoded.height * 4
                )
                cache.generation += 1
            }
        }
    }

    private func schedulePDFDecode(url: URL, maxPixelSize: CGFloat, key: NSString) {
        let keyString = key as String
        guard inflight.insert(keyString).inserted else {
            return
        }
        Task.detached(priority: .userInitiated) {
            let decoded = Self.decodedPDFThumbnail(url: url, maxPixelSize: maxPixelSize)
            await MainActor.run {
                let cache = AttachmentPreviewCache.shared
                cache.inflight.remove(keyString)
                guard let (image, pageCount) = decoded else {
                    return
                }
                cache.storePDFPageCount(pageCount, for: url)
                let size = image.size
                cache.imageCache.setObject(
                    image,
                    forKey: Self.cacheKey(for: url, maxPixelSize: maxPixelSize),
                    cost: Int(size.width * size.height * 4)
                )
                cache.generation += 1
            }
        }
    }

    private func schedulePDFCount(url: URL) {
        let keyString = "count#\(url.path)"
        guard inflight.insert(keyString).inserted else {
            return
        }
        Task.detached(priority: .utility) {
            let document = PDFDocument(url: url)
            let count = document?.pageCount
            await MainActor.run {
                let cache = AttachmentPreviewCache.shared
                cache.inflight.remove(keyString)
                guard let count else {
                    return
                }
                cache.storePDFPageCount(count, for: url)
                cache.generation += 1
            }
        }
    }

    nonisolated private static func decodedImageThumbnail(url: URL, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated private static func decodedPDFThumbnail(
        url: URL,
        maxPixelSize: CGFloat
    ) -> (NSImage, Int)? {
        guard
            let document = PDFDocument(url: url),
            let page = document.page(at: 0)
        else {
            return nil
        }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }
        let scale = min(maxPixelSize / bounds.width, maxPixelSize / bounds.height)
        let targetSize = NSSize(width: ceil(bounds.width * scale), height: ceil(bounds.height * scale))
        return (page.thumbnail(of: targetSize, for: .mediaBox), document.pageCount)
    }
}
