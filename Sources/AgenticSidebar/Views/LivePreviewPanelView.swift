import SwiftUI
import WebKit

/// Yalıtılmış canlı önizleme paneli.
///
/// İzolasyon katmanları (savunma derinliği):
/// 1. `PreviewArtifactBuilder` belgesi sıkı bir CSP taşır.
/// 2. `WKWebsiteDataStore.nonPersistent()` — önizleme diske çerez/önbellek yazmaz.
/// 3. `loadHTMLString(_:baseURL:)` çağrısında `baseURL: nil` — göreli URL'ler
///    `file://` dahil hiçbir şeye çözümlenemez.
/// 4. `PreviewNavigationPolicy` — kullanıcı tıklamaları ve çerçeve dışı her
///    gezinme iptal edilir; yalnızca Mermaid CDN betiğinin alt kaynak yüklemesi
///    geçer (ana çerçeve gezinmesi asla).
struct LivePreviewPanelView: View {
    let title: String
    let html: String
    let preset: AppThemePreset
    let isDark: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)

                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text("yalıtılmış önizleme")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .interactiveHoverCircle()
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Close preview")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
                .opacity(0.4)

            IsolatedWebView(html: html)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            (isDark ? preset.surfaceDark : preset.surfaceLight).opacity(0.96)
        )
    }
}

// MARK: - WKWebView sarmalayıcı

private struct IsolatedWebView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Belge kimliği değiştiğinde yeniden yükle; aynı belgede gereksiz
        // yükleme kaydırma konumunu sıfırlardı.
        guard context.coordinator.loadedHTML != html else {
            return
        }
        context.coordinator.loadedHTML = html
        webView.stopLoading()
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(loadedHTML: html)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String

        init(loadedHTML: String) {
            self.loadedHTML = loadedHTML
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(PreviewNavigationPolicy.policy(for: navigationAction))
        }
    }
}

// MARK: - Gezinme ilkesi (saf, test edilebilir)

enum PreviewNavigationPolicy {
    /// Ana çerçeve gezinmesi her zaman iptal (bağlantı tıklamaları dahil).
    /// Alt kaynaklara yalnızca Mermaid CDN ana bilgisayarından izin verilir.
    static func allowsMainFrameNavigation(to url: URL?) -> Bool {
        false
    }

    static func allowsSubresourceLoad(fromHost host: String?) -> Bool {
        host == PreviewArtifactBuilder.mermaidCDNHost
    }

    static func policy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
        if action.targetFrame?.isMainFrame != false {
            return .cancel
        }
        let host = action.request.url?.host?.lowercased()
        return allowsSubresourceLoad(fromHost: host) ? .allow : .cancel
    }
}
