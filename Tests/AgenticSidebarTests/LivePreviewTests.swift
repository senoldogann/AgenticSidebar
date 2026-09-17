import XCTest
@testable import AgenticSidebar

/// Canlı önizleme: belge sarma, gezinme ilkesi ve sekme modeli.
///
/// Çıta: HTML belgesi betik/ağ çalıştırmaz (CSP `default-src 'none'`),
/// Mermaid yalnızca izinli CDN'den beslenir, ana çerçeve gezinmesi asla
/// açılmaz ve önizleme sekmeleri dosya sekmeleriyle birlikte numaralanır.
final class LivePreviewTests: XCTestCase {
    // MARK: - Belge sarma

    func testHTMLDocumentCarriesStrictCSP() {
        let document = PreviewArtifactBuilder.document(for: .html("<h1>Merhaba</h1>"))

        XCTAssertTrue(document.contains("<h1>Merhaba</h1>"))
        XCTAssertTrue(document.contains("default-src 'none'"))
        XCTAssertFalse(document.lowercased().contains("<script"))
    }

    func testSVGDocumentCentersArtwork() {
        let document = PreviewArtifactBuilder.document(for: .svg("<svg></svg>"))

        XCTAssertTrue(document.contains("<svg></svg>"))
        XCTAssertTrue(document.contains("svg-stage"))
        XCTAssertTrue(document.contains("default-src 'none'"))
    }

    func testMermaidDocumentEscapesCodeAndPinsCDN() {
        let document = PreviewArtifactBuilder.document(
            for: .mermaid("A --> B <script>alert(1)</script>")
        )

        XCTAssertTrue(document.contains(PreviewArtifactBuilder.mermaidCDNHost))
        XCTAssertTrue(document.contains("securityLevel:'strict'"))
        XCTAssertTrue(document.contains("&lt;script&gt;"))
        XCTAssertFalse(document.contains("<script>alert(1)"))
    }

    // MARK: - Gezinme ilkesi

    func testMainFrameNavigationIsNeverAllowed() {
        XCTAssertFalse(PreviewNavigationPolicy.allowsMainFrameNavigation(to: nil))
        XCTAssertFalse(PreviewNavigationPolicy.allowsMainFrameNavigation(
            to: URL(string: "https://example.com")
        ))
    }

    func testSubresourceLoadAllowsOnlyMermaidCDN() {
        XCTAssertTrue(PreviewNavigationPolicy.allowsSubresourceLoad(
            fromHost: PreviewArtifactBuilder.mermaidCDNHost
        ))
        XCTAssertFalse(PreviewNavigationPolicy.allowsSubresourceLoad(fromHost: "evil.example"))
        XCTAssertFalse(PreviewNavigationPolicy.allowsSubresourceLoad(fromHost: nil))
    }

    // MARK: - Sekme modeli

    func testForLivePreviewBuildsTabAndCountsAsFileTab() {
        let preview = InspectorTab.forLivePreview(id: "abc", title: "demo.html", html: "<b>x</b>")
        let file = InspectorTab.forFile(url: URL(fileURLWithPath: "/tmp/not.md"))

        XCTAssertEqual(preview.id, "preview:abc")
        XCTAssertEqual(preview.title, "demo.html")
        XCTAssertEqual(
            InspectorTab.displayLabel(for: preview, among: [file, preview]),
            "Sekme 2"
        )
    }
}
