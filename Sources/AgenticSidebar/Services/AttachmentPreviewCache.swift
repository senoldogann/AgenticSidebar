import AppKit
import Foundation
import ImageIO
import PDFKit

/// High-performance memory-bounded cache for image and PDF attachment thumbnails.
///
/// Prevents repetitive synchronous disk I/O and large bitmap decoding inside
/// SwiftUI view evaluation bodies during scrolling, typing, or streaming.
@MainActor
final class AttachmentPreviewCache {
    static let shared = AttachmentPreviewCache()

    private let imageCache = NSCache<NSString, NSImage>()
    private var pdfPageCounts: [URL: Int] = [:]
    private static let maximumPDFPageCountEntries = 200

    private static let defaultMaxPixelSize: CGFloat = 520
    private static let memoryCostLimit = 30 * 1024 * 1024 // 30 MB
    private static let maximumItemCount = 50

    init() {
        imageCache.totalCostLimit = Self.memoryCostLimit
        imageCache.countLimit = Self.maximumItemCount
    }

    /// Retrieves or decodes a downsampled thumbnail for an image file.
    ///
    /// Uses ImageIO thumbnail creation to decode only the pixels needed for display,
    /// reducing memory usage by up to 90% compared to loading full-resolution bitmaps.
    func imageThumbnail(for url: URL, maxPixelSize: CGFloat) -> NSImage? {
        let key = Self.cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let cached = imageCache.object(forKey: key) {
            return cached
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let size = NSSize(width: cgImage.width, height: cgImage.height)
        let image = NSImage(cgImage: cgImage, size: size)

        let estimatedCost = cgImage.width * cgImage.height * 4
        imageCache.setObject(image, forKey: key, cost: estimatedCost)
        return image
    }

    /// Convenience overload using standard thumbnail dimension.
    func imageThumbnail(for url: URL) -> NSImage? {
        imageThumbnail(for: url, maxPixelSize: Self.defaultMaxPixelSize)
    }

    /// Retrieves or renders a thumbnail for the first page of a PDF document.
    func pdfThumbnail(for url: URL, maxPixelSize: CGFloat) -> NSImage? {
        let key = Self.cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let cached = imageCache.object(forKey: key) {
            return cached
        }

        guard let document = PDFDocument(url: url) else {
            return nil
        }

        storePDFPageCount(document.pageCount, for: url)

        guard let page = document.page(at: 0) else {
            return nil
        }

        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }

        let scale = min(maxPixelSize / bounds.width, maxPixelSize / bounds.height)
        let targetSize = NSSize(width: ceil(bounds.width * scale), height: ceil(bounds.height * scale))

        let rendered = page.thumbnail(of: targetSize, for: .mediaBox)
        let cost = Int(targetSize.width * targetSize.height * 4)
        imageCache.setObject(rendered, forKey: key, cost: cost)
        return rendered
    }

    /// Convenience overload using standard thumbnail dimension.
    func pdfThumbnail(for url: URL) -> NSImage? {
        pdfThumbnail(for: url, maxPixelSize: Self.defaultMaxPixelSize)
    }

    /// Returns cached page count or reads it once from the document.
    func pdfPageCount(for url: URL) -> Int? {
        if let count = pdfPageCounts[url] {
            return count
        }
        guard let document = PDFDocument(url: url) else {
            return nil
        }
        let count = document.pageCount
        storePDFPageCount(count, for: url)
        return count
    }

    /// Önbellek anahtarı boyutu içerir: aynı dosya çip için 96 px, transkript
    /// için 520 px ve önizleme için 1800 px istenir; anahtar yalnız URL olsaydı
    /// ilk üretilen boyut diğerlerini gölgeler ve büyük görüntü bulanık kalırdı.
    private static func cacheKey(for url: URL, maxPixelSize: CGFloat) -> NSString {
        "\(url.path)#\(Int(maxPixelSize))" as NSString
    }

    private func storePDFPageCount(_ count: Int, for url: URL) {
        if pdfPageCounts.count > Self.maximumPDFPageCountEntries {
            pdfPageCounts.removeAll()
        }
        pdfPageCounts[url] = count
    }

    /// Clears cached thumbnails and metadata to free memory immediately.
    func clear() {
        imageCache.removeAllObjects()
        pdfPageCounts.removeAll()
    }
}
