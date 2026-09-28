import Foundation

/// LLM üretimi işaretlemeden güvenli önizleme belgesi kurar.
///
/// Tehdit modeli: önizlenen HTML/JS model üretimidir; dışarıya veri sızdırma
/// (`fetch`, form, `file://` okuma) ve ana uygulamaya erişim engellenmelidir.
/// Bu builder yalnızca belge metnini üretir — çalıştırma izolasyonu
/// `LivePreviewPanelView` tarafındadır (kalıcı olmayan veri deposu,
/// `baseURL: nil`, gezinme temsilcisinde izin listesi).
enum PreviewArtifactBuilder {
    /// Sabitlenmiş Mermaid sürümü. Yüzer `mermaid@11` hem her açılışta
    /// sürüklenir hem de 11.16.1 öncesi prototip kirliliği (CVE-2026-71437)
    /// taşıyan sürüme çözümlenebilirdi.
    nonisolated static let mermaidVersion = "11.17.2"

    /// İzin verilen tek dış kaynak: tam URL. Host-seviyesi izin, aynı CDN'deki
    /// keyfi paketlerden betik yüklenmesine kapı aralardı.
    nonisolated static let mermaidScriptURL =
        "https://cdn.jsdelivr.net/npm/mermaid@11.17.2/dist/mermaid.min.js"

    enum Source: Equatable, Sendable {
        case html(String)
        case svg(String)
        case mermaid(String)
    }

    /// Kaynağı tam bir önizleme belgesine sarar.
    static func document(for source: Source) -> String {
        switch source {
        case .html(let body):
            return wrapped(body: sanitizedMarkup(body), extraHead: "")
        case .svg(let svg):
            return wrapped(
                body: "<div class=\"svg-stage\">\(sanitizedMarkup(svg))</div>",
                extraHead: """
                    <style>.svg-stage{display:flex;justify-content:center;padding:24px}svg{max-width:100%;height:auto}</style>
                    """
            )
        case .mermaid(let code):
            return mermaidDocument(code: code)
        }
    }

    /// Ham model çıktısındaki etkin içeriği şeritler: betik ve gömülü
    /// çerçeve öğeleri, vektör taşıyabilen gömülü ortam öğeleri (`math`,
    /// `video`/`audio`+`source`, `link`/`base`), on* olay öznitelikleri ve
    /// javascript: adresleri. `svg` bilerek listede değildir: `.svg`
    /// yapıtları statik çizim önizlemesidir, test kilitlidir
    /// (`LivePreviewTests.testSVGDocumentCentersArtwork`); svg içindeki
    /// olay öznitelikleri (`onbegin` dahil) genel on* deseniyle, dış
    /// yükler CSP (`default-src 'none'`) ile tutulur. CSP ve izolasyon
    /// katmanları yerinde durur; bu, tek katman hatasında aktifleşecek
    /// vektörleri baştan kaldırır.
    /// Desenler çağrı başına derlenmez: aynı belge her satırda yeniden
    /// taranır, derleme maliyeti her seferinde ödenmezdi.
    private static let strippedElements = [
        "script", "iframe", "object", "embed", "form", "foreignobject",
        "math", "body", "video", "audio", "source", "track",
        "link", "base",
    ]

    private static let elementPairPatterns: [(element: String, regex: NSRegularExpression?)] = strippedElements.map { element in
        (
            element: element,
            regex: try? NSRegularExpression(
                pattern: "<\(element)\\b[^>]*>([\\s\\S]*?)</\(element)\\s*>",
                options: [.caseInsensitive]
            )
        )
    }

    private static let elementOpenPatterns: [(element: String, regex: NSRegularExpression?)] = strippedElements.map { element in
        (
            element: element,
            regex: try? NSRegularExpression(
                pattern: "<\(element)\\b[^>]*/?>",
                options: [.caseInsensitive]
            )
        )
    }

    private static let metaPattern = try? NSRegularExpression(
        pattern: "<meta\\b[^>]*>", options: [.caseInsensitive]
    )
    private static let eventHandlerPattern = try? NSRegularExpression(
        pattern: "\\s+on[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)",
        options: [.caseInsensitive]
    )
    private static let javascriptSchemePattern = try? NSRegularExpression(
        pattern: "javascript\\s*:", options: [.caseInsensitive]
    )

    static func sanitizedMarkup(_ markup: String) -> String {
        // Sayısal karakter referansları (`&#106;`, `&#x6A;`) önce çözülür:
        // kodlanmış `javascript:` ve olay öznitelikleri desenden kaçamazdı.
        var result = decodingNumericCharacterReferences(markup)
        for entry in elementPairPatterns {
            result = replacingMatches(regex: entry.regex, in: result)
        }
        for entry in elementOpenPatterns {
            result = replacingMatches(regex: entry.regex, in: result)
        }
        result = replacingMatches(regex: metaPattern, in: result)
        result = replacingMatches(regex: eventHandlerPattern, in: result)
        result = replacingMatches(regex: javascriptSchemePattern, in: result)
        return result
    }

    private static func replacingMatches(regex: NSRegularExpression?, in text: String) -> String {
        guard let regex else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }

    /// Sayısal karakter referanslarını (`&#106;`, `&#x6A;`) çözer; geçersiz
    /// ya da denetimsiz değerler olduğu gibi bırakılır. Çözüm yalnız
    /// arındırma içindir, çıktıya kaçmaz: `javascript:` gizleme kalıbı
    /// (`&#106;avascript:`) böylece yakalanır.
    private static func decodingNumericCharacterReferences(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&", text[index...].hasPrefix("&#") else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }
            guard let semicolon = text[index...].firstIndex(of: ";"),
                semicolon < text.index(index, offsetBy: 10, limitedBy: text.endIndex) ?? text.endIndex
            else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }
            let body = String(text[text.index(index, offsetBy: 2)..<semicolon])
            let scalarValue: UInt32? = {
                if body.hasPrefix("x") || body.hasPrefix("X") {
                    return UInt32(String(body.dropFirst()), radix: 16)
                }
                return UInt32(body, radix: 10)
            }()
            guard let value = scalarValue, let scalar = Unicode.Scalar(value) else {
                result.append(contentsOf: text[index...semicolon])
                index = text.index(after: semicolon)
                continue
            }
            result.append(Character(scalar))
            index = text.index(after: semicolon)
        }
        return result
    }

    // MARK: - Özel

    /// Sıkı CSP: betik, ağ ve eklenti yok; yalnızca satır içi stil ve `data:` görselleri.
    private static func wrapped(body: String, extraHead: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width,initial-scale=1">\
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:;">\
        <style>body{margin:0;padding:16px;font-family:-apple-system,Helvetica,Arial,sans-serif}</style>\
        \(extraHead)</head><body>\(body)</body></html>
        """
    }

    /// Mermaid çalışması için betik gerekir; bu yüzden izin listesi yalnızca
    /// CDN betiğine ve satır içi başlatıcıya açıktır, geri kalan her şey kapalı.
    private static func mermaidDocument(code: String) -> String {
        let escaped =
            code
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
            <!doctype html><html><head><meta charset="utf-8">\
            <meta name="viewport" content="width=device-width,initial-scale=1">\
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src \(mermaidScriptURL) 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:;">\
            <style>body{margin:0;padding:16px;font-family:-apple-system,Helvetica,Arial,sans-serif}</style>\
            <script src="\(mermaidScriptURL)"></script>\
            </head><body><pre class="mermaid">\(escaped)</pre>\
            <script>mermaid.initialize({startOnLoad:true,securityLevel:'strict'});</script></body></html>
            """
    }
}
