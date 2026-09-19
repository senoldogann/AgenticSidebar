import XCTest

@testable import AgenticSidebar

/// Canlı önizleme: belge sarma ve gezinme ilkesi.
///
/// Çıta: HTML belgesi betik/ağ çalıştırmaz (CSP `default-src 'none'`),
/// Mermaid yalnızca sabitlenmiş betik URL'sinden beslenir, ana çerçeve
/// gezinmesi asla açılmaz.
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

        XCTAssertTrue(document.contains(PreviewArtifactBuilder.mermaidScriptURL))
        XCTAssertTrue(document.contains("mermaid@\(PreviewArtifactBuilder.mermaidVersion)/"))
        XCTAssertTrue(document.contains("securityLevel:'strict'"))
        XCTAssertTrue(document.contains("&lt;script&gt;"))
        XCTAssertFalse(document.contains("<script>alert(1)"))
    }

    // MARK: - Gezinme ilkesi

    func testMainFrameNavigationIsNeverAllowed() {
        XCTAssertFalse(PreviewNavigationPolicy.allowsMainFrameNavigation(nil))
        XCTAssertFalse(
            PreviewNavigationPolicy.allowsMainFrameNavigation(
                URL(string: "https://example.com")
            ))
    }

    func testSubresourceLoadAllowsOnlyPinnedMermaidScript() {
        XCTAssertTrue(
            PreviewNavigationPolicy.allowsSubresourceLoad(
                url: URL(string: PreviewArtifactBuilder.mermaidScriptURL)
            ))
        XCTAssertFalse(
            PreviewNavigationPolicy.allowsSubresourceLoad(
                url: URL(string: "https://cdn.jsdelivr.net/npm/evil-pkg@1.0.0/dist/evil.min.js")
            ))
        XCTAssertFalse(
            PreviewNavigationPolicy.allowsSubresourceLoad(
                url: URL(string: "https://evil.example/mermaid.min.js")
            ))
        XCTAssertFalse(PreviewNavigationPolicy.allowsSubresourceLoad(url: nil))
    }
}
