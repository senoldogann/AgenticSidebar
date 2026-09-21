import AppKit
import PDFKit
import SwiftUI

/// A slide-in inspector panel on the right side of the chat view
/// for previewing clicked attachments, readme.md files, and documents.
struct FileInspectorPanelView: View {
    let url: URL
    let preset: AppThemePreset
    let isDark: Bool
    let onDismiss: () -> Void
    /// Önizleme için okunan dosya sistemi; üretimde `.default`, testte taklit.
    var fileManager: FileManager = .default

    /// Metin önizlemesinin durumu.
    ///
    /// Ön ek dosyadan bir kez, ana iş parçacığının dışında okunur: okuma
    /// gövdenin içinde yapıldığında her yeniden çizim (hover, tema, pencere
    /// boyutu) aynı 1 MB'ı yeniden okuyup çözüyordu.
    private enum TextPreviewState: Equatable {
        case loading
        case text(String)
        case unreadable
    }

    @State private var copyConfirmation = CopyConfirmation()
    @State private var textPreview: TextPreviewState = .loading

    nonisolated private static let maximumTextBytes = 1_000_000
    nonisolated private static let maximumTruncatedCharacters = 100_000
    /// Bu uzunluğun üstündeki markdown tam ağaç olarak dizilmez; bkz.
    /// `markdownPreview`. 11 KB'lık bir rapor altta rahatça kalır, 100 KB'lık
    /// bir döküm paneli kilitlemez.
    nonisolated private static let maximumMarkdownCharacters = 30_000

    /// Küçültülmüş kopya çözülemediğinde (ör. SVG) dosya doğrudan yüklenir;
    /// o yol tam çözünürlüklü olduğu için çok büyük dosyalarda atlanır.
    private static let maximumOriginalImageBytes: Int64 = 24 * 1024 * 1024

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .opacity(0.4)

            content
        }
        .frame(minWidth: 320, idealWidth: 380, maxWidth: 520)
        .background(
            (isDark ? preset.surfaceDark : preset.surfaceLight).opacity(0.96)
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill((isDark ? preset.borderSubtleDark : preset.borderSubtleLight).opacity(0.6))
                .frame(width: 1)
        }
        .task(id: url) {
            await loadTextPreview()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            fileTypeIcon
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(preset.accentGradient.first ?? .accentColor)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(fileMetadataSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Button {
                    copyConfirmation.copy(url.path)
                } label: {
                    Image(systemName: copyConfirmation.isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(copyConfirmation.isCopied ? .green : .secondary)
                        .frame(width: 24, height: 24)
                        .interactiveHoverCircle()
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Copy file path")
                .accessibilityLabel("Copy file path")

                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .interactiveHoverCircle()
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Open in external app")
                .accessibilityLabel("Open in external app")

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .interactiveHoverCircle()
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Close preview")
                .accessibilityLabel("Close preview")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        let ext = url.pathExtension.lowercased()
        let isImage = ["png", "jpg", "jpeg", "webp", "tiff", "gif", "heic", "bmp", "svg"].contains(ext)
        let isPDF = ext == "pdf"
        let isMarkdown = ["md", "markdown", "mdown", "mkd"].contains(ext)

        if isImage {
            imagePreview
        } else if isPDF {
            pdfPreview
        } else if isMarkdown {
            markdownPreview
        } else {
            codeOrTextPreview
        }
    }

    private var imagePreview: some View {
        ScrollView([.horizontal, .vertical]) {
            // Önizleme de paylaşılan önbellekten beslenir; SVG gibi
            // CGImageSource'un çözemediği biçimler için NSImage'a düşülür.
            if let image = AttachmentPreviewCache.shared.imageThumbnail(for: url, maxPixelSize: 1800) {
                previewImage(image)
            } else if let original = originalImage() {
                previewImage(original)
            } else {
                errorNotice(message: "Could not load image file.")
            }
        }
    }

    private func previewImage(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(16)
    }

    /// Küçültülmüş kopyanın çözemediği biçimler için son çare; dosya boyutu
    /// sınırın üstündeyse hiç denenmez.
    private func originalImage() -> NSImage? {
        let size = (try? fileManager.attributesOfItem(atPath: url.path))
            .flatMap { $0[.size] as? NSNumber }?
            .int64Value

        guard let size, size <= Self.maximumOriginalImageBytes else {
            return nil
        }

        return NSImage(contentsOf: url)
    }

    private var pdfPreview: some View {
        ScrollView {
            if let doc = PDFDocument(url: url) {
                LazyVStack(spacing: 12) {
                    ForEach(0..<doc.pageCount, id: \.self) { index in
                        if let page = doc.page(at: index) {
                            let thumb = page.thumbnail(of: CGSize(width: 440, height: 600), for: .mediaBox)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Page \(index + 1) of \(doc.pageCount)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)

                                Image(nsImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                            }
                        }
                    }
                }
                .padding(14)
            } else {
                errorNotice(message: "Could not load PDF document.")
            }
        }
    }

    private var markdownPreview: some View {
        ScrollView {
            switch textPreview {
            case .loading:
                loadingPlaceholder
            case .text(let content):
                if content.count > Self.maximumMarkdownCharacters {
                    // Tam markdown ağacı bu boyda binlerce görünüm + dev bir
                    // metin yerleşimi demektir: önizleme paneli açılırken ana
                    // iş parçacığı kilitlenir. Sınır üstü dosyalar satır
                    // numaralı düz metin olarak gösterilir; içerik kaybı yok,
                    // biçimleme fedadır.
                    codeOrTextBody(content: content)
                } else {
                    MarkdownContentView(markdown: content, allowsPlanDocuments: false)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .unreadable:
                errorNotice(message: "File is not UTF-8 text or is inaccessible.")
            }
        }
    }

    private var loadingPlaceholder: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
    }

    @ViewBuilder
    private var codeOrTextPreview: some View {
        switch textPreview {
        case .loading:
            loadingPlaceholder
        case .unreadable:
            errorNotice(message: "Binary or non-UTF-8 file.")
        case .text(let content):
            codeOrTextBody(content: content)
        }
    }

    private func codeOrTextBody(content: String) -> some View {
        ScrollView {
            let lines = content.components(separatedBy: "\n")
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 32, alignment: .trailing)
                            .userSelectable(false)

                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)

                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func errorNotice(message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Open Externally") {
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
            .help("Open this file in its default application")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func loadTextPreview() async {
        textPreview = .loading

        let url = self.url
        let content = await Task.detached(priority: .userInitiated) {
            Self.readTextPrefix(of: url)
        }.value

        textPreview = content.map(TextPreviewState.text) ?? .unreadable
    }

    /// Yalnız sınırlı bir ön ek okunur ve kırpılır; `nonisolated` olduğu için
    /// gövdenin çizildiği iş parçacığında değil, ayrı bir görevde çalışır.
    nonisolated static func readTextPrefix(of url: URL) -> String? {
        // Dosya boyutundan bağımsız olarak yalnız sınırlı bir ön ek okunur:
        // eskiden 1 MB üstü dosyalar `String(contentsOf:)` ile tümden okunuyordu
        // ve büyük bir günlük dosyası arayüzü kilitleyebiliyordu.
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        guard
            var data = try? handle.read(upToCount: Self.maximumTextBytes),
            !data.isEmpty
        else {
            return nil
        }

        // Kesme noktası çok baytlı bir karakterin ortasına düşmüş olabilir:
        // çözülene kadar kuyruktan en fazla üç bayt kırpılır; yine çözülmezse
        // dosya metin değildir.
        var text: String?
        for _ in 0..<4 {
            if let decoded = String(data: data, encoding: .utf8) {
                text = decoded
                break
            }
            guard !data.isEmpty else {
                break
            }
            data = data.dropLast()
        }

        guard let text else {
            return nil
        }

        let limit = Self.maximumTruncatedCharacters
        return text.count > limit
            ? String(text.prefix(limit)) + "\n… [truncated]"
            : text
    }

    private var fileTypeIcon: Image {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown"].contains(ext) {
            return Image(systemName: "doc.richtext.fill")
        } else if ["swift", "js", "ts", "json", "py", "sh", "yml", "yaml", "html", "css"].contains(ext) {
            return Image(systemName: "chevron.left.forwardslash.chevron.right")
        } else if ["png", "jpg", "jpeg", "webp", "gif", "heic"].contains(ext) {
            return Image(systemName: "photo.fill")
        } else if ext == "pdf" {
            return Image(systemName: "doc.text.fill")
        }
        return Image(systemName: "doc.fill")
    }

    private var fileMetadataSubtitle: String {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else {
            return url.pathExtension.uppercased()
        }

        let size = attrs[.size] as? Int64 ?? 0
        let formattedSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        return "\(url.pathExtension.uppercased()) · \(formattedSize)"
    }
}

extension View {
    @ViewBuilder
    fileprivate func userSelectable(_ selectable: Bool) -> some View {
        if selectable {
            self.textSelection(.enabled)
        } else {
            self.textSelection(.disabled)
        }
    }
}
