import SwiftUI
import WebKit

/// Sağ paneldeki tarayıcı sekmesi: adres çubuğu, geri/ileri/yenile ve sayfa
/// yüzeyi.
///
/// Sayfa `BrowserServiceCenter` tarafında yaşar; sekme değişiminde görünüm
/// yok olsa da sayfa durur. Görünüm izole önizlemeden (`LivePreviewPanelView`)
/// ayrıdır: burada gezinme serbesttir, çerezler oturum boyunca kalır.
struct BrowserPanelView: View {
    let center: BrowserServiceCenter
    let tabID: String
    let preset: AppThemePreset
    let isDark: Bool
    let onDismiss: () -> Void

    @State private var selectedPageID: String?

    var body: some View {
        VStack(spacing: 0) {
            if let pageID = selectedPageID, let page = center.existing(id: pageID) {
                BrowserPageStrip(
                    center: center,
                    tabID: tabID,
                    selectedPageID: pageID,
                    onSelect: { selectedPageID = $0 }
                )

                BrowserToolbar(
                    model: page,
                    preset: preset,
                    isDark: isDark,
                    onDismiss: onDismiss
                )

                Divider()
                    .opacity(0.4)

                if let notice = page.downloadNotice {
                    BrowserDownloadBanner(
                        notice: notice,
                        onDismiss: { page.dismissDownloadNotice() }
                    )

                    Divider()
                        .opacity(0.4)
                }

                ZStack {
                    BrowserWebSurface(model: page)

                    if !page.hasPage {
                        startHint(status: page.profileStatus)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Opening the browser…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(preset.surface(isDark: isDark).opacity(0.96))
        .onAppear {
            let pages = center.ensurePages(tabID: tabID)
            if selectedPageID == nil || !pages.contains(selectedPageID ?? "") {
                selectedPageID = pages.first
            }
        }
    }

    /// İlk açılışta boş sayfa yerine ne yapılacağını söyleyen ipucu.
    private func startHint(status: String?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)

            Text("Search or enter a website above")
                .font(.system(size: 12.5, weight: .semibold))

            Text(
                "Pages open in this panel; links follow in place and the history stays while the tab is open. For logged-in accounts (e.g. Google), open the page first, then continue it in your personal Chrome profile with the square-arrow button above."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)

            if let status {
                Text(status)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
        }
        .padding(20)
        .allowsHitTesting(false)
    }
}

// MARK: - Sayfa şeridi + indirme bandı

/// Panel içi web sayfaları: sayfa durumu merkezde yaşadığı için şerit yalnız
/// kimlikleri listeler, başlıklar modellerden okunur.
private struct BrowserPageStrip: View {
    let center: BrowserServiceCenter
    let tabID: String
    let selectedPageID: String
    let onSelect: (String) -> Void

    var body: some View {
        let pages = center.pageIDsByTab[tabID] ?? []
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(pages, id: \.self) { id in
                        BrowserPageChip(
                            title: chipTitle(for: id),
                            isSelected: id == selectedPageID,
                            canClose: pages.count > 1,
                            onSelect: { onSelect(id) },
                            onClose: {
                                center.closePage(id, tabID: tabID)
                                if id == selectedPageID {
                                    onSelect(center.pageIDsByTab[tabID]?.first ?? id)
                                }
                            }
                        )
                    }
                }
            }

            Button {
                onSelect(center.newPage(tabID: tabID))
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 22)
                    .interactiveHoverCircle()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Open a new tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func chipTitle(for id: String) -> String {
        if let title = center.existing(id: id)?.pageTitle, !title.isEmpty {
            return title
        }
        if let host = center.existing(id: id)?.currentURL?.host(), !host.isEmpty {
            return host
        }
        return "New tab"
    }
}

private struct BrowserPageChip: View {
    let title: String
    let isSelected: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 140, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (isSelected ? Color.primary.opacity(0.10) : Color.clear),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(title)

            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, height: 16)
                        .interactiveHoverCircle()
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Close this tab")
            }
        }
    }
}

private struct BrowserDownloadBanner: View {
    let notice: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            Text(notice)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 20)
                    .interactiveHoverCircle()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Dismiss")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }
}

// MARK: - Araç çubuğu

private struct BrowserToolbar: View {
    @Bindable var model: BrowserTabModel
    let preset: AppThemePreset
    let isDark: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            iconButton(
                systemName: "chevron.left",
                isEnabled: model.canGoBack,
                help: "Back"
            ) {
                model.goBack()
            }

            iconButton(
                systemName: "chevron.right",
                isEnabled: model.canGoForward,
                help: "Forward"
            ) {
                model.goForward()
            }

            iconButton(
                systemName: model.isLoading ? "xmark" : "arrow.clockwise",
                isEnabled: true,
                help: model.isLoading ? "Stop loading" : "Reload"
            ) {
                model.reloadOrStop()
            }

            Menu {
                let entries = model.historySnapshot()
                if entries.isEmpty {
                    Text("No history yet")
                } else {
                    ForEach(entries.indices, id: \.self) { index in
                        let entry = entries[index]
                        Button {
                            model.load(entry.url)
                        } label: {
                            Text(entry.isCurrent ? "● \(entry.title)" : entry.title)
                        }
                        .disabled(entry.isCurrent)
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .interactiveHoverCircle()
            }
            .menuStyle(.borderlessButton)
            .help("History")

            TextField("Search or enter a website", text: $model.addressText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(preset.border(isDark: isDark).opacity(0.7), lineWidth: 1)
                )
                .onSubmit {
                    model.submitAddress()
                }
                .accessibilityLabel("Address")

            if model.loadError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .help(model.loadError ?? "")
            }

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 20, height: 20)
            }

            iconButton(
                systemName: "arrow.up.right.square",
                isEnabled: model.currentURL != nil,
                help: chromeOpenHelp(profileName: model.chromeProfileName)
            ) {
                if let url = model.currentURL {
                    PersonalChromeOpener.open(url)
                }
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .interactiveHoverCircle()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Close the browser")
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
    }

    /// Kare-ok düğmesinin ipucu: kişisel profil adı biliniyorsa onu yazar,
    /// Chrome yoksa varsayılan tarayıcıya düşüleceğini söyler.
    private func chromeOpenHelp(profileName: String?) -> String {
        if let profileName, !profileName.isEmpty {
            return "Chrome profilinde aç: \(profileName) (gerçek oturumların orada)"
        }
        return "Chrome'da aç (yoksa varsayılan tarayıcıda)"
    }

    private func iconButton(
        systemName: String,
        isEnabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isEnabled ? Color.secondary : Color.secondary.opacity(0.4))
                .frame(width: 24, height: 24)
                .interactiveHoverCircle()
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .disabled(!isEnabled)
        .help(help)
    }
}

// MARK: - Web yüzeyi

/// Modelin `WKWebView`'ini yerleştirir. Görünüm web görünümüne sahip
/// olmadığı için sekme değişiminde sayfa yok olmaz.
private struct BrowserWebSurface: NSViewRepresentable {
    let model: BrowserTabModel

    func makeNSView(context: Context) -> WKWebView {
        model.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
