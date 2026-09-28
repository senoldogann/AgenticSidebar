import AppKit
import Observation
import WebKit

/// Adres çubuğuna yazılanı yüklenecek URL'ye çevirir.
///
/// Saf: ağ ya da görünüm durumu okumaz. Bilinen şema aynen kalır; `/` ya da
/// `~` ile başlayan yol yerel dosyadır; nokta ya da `host:port` taşıyan
/// şemasız metin `https://` ile tamamlanır — yerel geliştirme sunucuları
/// (loopback, `.local`, özel ağ IPv4) düz TLS konuşmadığı için `http://` alır;
/// kalan her şey arama sorgusudur (boşluk içeren metin dahil).
enum BrowserURLNormalizer {
    /// Varsayılan arama motoru ve başlangıç sayfası: Google.
    static let searchEngineURL = URL(string: "https://www.google.com/")!
    static let searchBaseURL = URL(string: "https://www.google.com/search")!

    private static let knownSchemes: Set<String> = [
        "http", "https", "file", "about", "data", "blob", "view-source",
    ]

    static func normalizedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            knownSchemes.contains(scheme)
        {
            return url
        }

        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }

        if !trimmed.contains(" "), looksLikeHost(trimmed) {
            let scheme = isLocalDevelopmentHost(hostPart(of: trimmed)) ? "http" : "https"
            return URL(string: "\(scheme)://\(trimmed)")
        }

        return searchURL(for: trimmed)
    }

    /// `example.com`, `localhost`, `localhost:3000` ya da `[::1]:8080` gibi
    /// şemasız ana bilgisayar metni.
    static func looksLikeHost(_ text: String) -> Bool {
        if isLocalDevelopmentHost(hostPart(of: text)) {
            return true
        }
        if text.contains(".") {
            return true
        }
        return text.range(
            of: "^[A-Za-z0-9-]+(:[0-9]+)(/.*)?$",
            options: .regularExpression
        ) != nil
    }

    /// Şemasız metnin ana bilgisayar kısmı: ilk `/`, `?` ya da `#` öncesi,
    /// port hariç, küçük harf. IPv6 literali köşeli parantezleriyle döner.
    static func hostPart(of text: String) -> String {
        let authority: Substring = text.prefix { !"/?#".contains($0) }
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            return String(authority[...close]).lowercased()
        }
        let host: Substring = authority.split(separator: ":", maxSplits: 1).first ?? ""
        return String(host).lowercased()
    }

    /// Yerel geliştirme sunucusu mu: loopback, `.localhost`/`.local` adları ve
    /// özel ağ IPv4 blokları (RFC 1918, link-local). Bunlar TLS sertifikası
    /// taşımaz; `https://` ile açmak bağlantıyı SSL hatasıyla düşürür.
    static func isLocalDevelopmentHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        if host == "[::1]" {
            return true
        }
        let parts: [Substring] = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets: [Int] = parts.compactMap { Int($0) }
        guard parts.count == 4, octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (0, _), (192, 168), (169, 254):
            return true
        case (172, 16...31):
            return true
        default:
            return false
        }
    }

    static func searchURL(for query: String) -> URL? {
        var components = URLComponents(url: searchBaseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

/// Bir tarayıcı sekmesinin durumu: sayfa, gezinme düğmelerinin okuduğu alanlar
/// ve adres çubuğu.
///
/// `WKWebView` burada yaşar; sekme değişiminde SwiftUI görünümü yok olsa da
/// sayfa yüklemeye devam eder, sekmeye dönülünce aynı sayfa durur
/// (`TerminalServiceCenter` ile aynı sözleşme).
@MainActor
@Observable
final class BrowserTabModel: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView

    /// Adres çubuğunun metni; kullanıcı yazar, gezinme sonrası URL ile tazelenir.
    var addressText: String = ""

    private(set) var pageTitle: String?
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var loadError: String?
    /// Kişisel profil içe aktarma durumu: ilk taramada "…" yerine sonuç yazar.
    private(set) var profileStatus: String?
    /// İndirme bildirimi: biten ya da düşen indirme panelde tek satır gösterir,
    /// kullanıcı kapatana kadar durur.
    private(set) var downloadNotice: String?
    private var pendingDownloadName: String?

    /// Web görünümünün güncel adresi. `webView.url` gözlem çerçevesine
    /// görünmez; KVO ile buraya yansıtılır ki başlangıç ipucu ve sekme
    /// başlıkları SPA gezinmesinde (`pushState`, hash) de tazelensin.
    private(set) var currentURL: URL?

    /// Henüz bir sayfaya gidilmedi mi? Panel başlangıç ipucunu buna göre çizer.
    var hasPage: Bool {
        currentURL != nil
    }

    /// "Chrome'da aç" düğmesinin hedeflediği kişisel profil adı; Chrome
    /// yoksa `nil` kalır, düğme ipucu buna göre yazılır.
    private(set) var chromeProfileName: String?

    /// Adres çubuğuna en son yansıtılan URL: başlık ya da geri/ileri
    /// değişiminde kullanıcının yazmakta olduğu metin ezilmez.
    @ObservationIgnored private var lastSyncedURL: URL?
    /// Web görünümü özelliklerinin KVO kayıtları; model yaşadıkça durur.
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// Sekme kapandı mı: geç biten profil aktarımı kapanmış sekmeye yükleme
    /// yapmasın.
    @ObservationIgnored private var isStopped = false

    override init() {
        // Kişisel profil: uygulamanın kalıcı deposu. İzole depo her açılışı
        // çıkış yapmış gösterirdi; varsayılan depo girişleri korur ve
        // `BrowserProfileImporter` kullanıcının gerçek tarayıcı çerezlerini
        // ilk açılışta buraya taşır.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // Sekmeler arası geçişte sayfa kaydırma konusu korunsun.
        webView.allowsMagnification = true
        observeWebView()

        Task { await loadPersonalProfile() }
    }

    /// Gezinme temsilcisi yalnız belge yüklemelerini bildirir; SPA gezinmesi
    /// (`pushState`, hash) ve arka plan yükleme değişimleri KVO'dan gelir.
    /// WebKit bu KVO'ları ana iş parçacığında yayınlar; yine de izolasyon
    /// varsayılmaz, senkron ana aktöre sıraya alınır.
    private func observeWebView() {
        let sync: @Sendable (WKWebView) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.syncFromWebView()
            }
        }
        observations = [
            webView.observe(\.url, options: [.new]) { view, _ in sync(view) },
            webView.observe(\.title, options: [.new]) { view, _ in sync(view) },
            webView.observe(\.canGoBack, options: [.new]) { view, _ in sync(view) },
            webView.observe(\.canGoForward, options: [.new]) { view, _ in sync(view) },
            webView.observe(\.isLoading, options: [.new]) { view, _ in sync(view) },
        ]
    }

    /// Başlangıç sayfası hemen yüklenir; kişisel çerez aktarımı arkada koşar.
    /// Aktarım Anahtar Zinciri onayı bekleyebilir — sayfayı ona bağlamak
    /// paneli onay gelene kadar boş bırakıyordu. Aktarım yeni çerez getirdiyse
    /// ve sekme hâlâ başlangıç sayfasındaysa sayfa bir kez tazelenir.
    private func loadPersonalProfile() async {
        let importer = BrowserProfileImporter.shared
        if let summary = await importer.completedSummary() {
            applyProfile(summary)
            if webView.url == nil {
                load(BrowserURLNormalizer.searchEngineURL)
            }
            return
        }
        if webView.url == nil {
            load(BrowserURLNormalizer.searchEngineURL)
        }
        let summary = await importer.ensureImported()
        guard !isStopped else {
            return
        }
        applyProfile(summary)
        if summary.imported > 0,
            webView.url?.host() == BrowserURLNormalizer.searchEngineURL.host()
        {
            webView.reload()
        }
    }

    private func applyProfile(_ summary: BrowserProfileImporter.Summary) {
        profileStatus = summary.displayText
        chromeProfileName = ChromeProfileResolver.personalProfileFromDisk()?.name
    }

    // MARK: - Eylemler

    func submitAddress() {
        guard let url = BrowserURLNormalizer.normalizedURL(from: addressText) else {
            return
        }
        load(url)
    }

    /// Yerel dosya `loadFileURL` ile açılır: düz `URLRequest` dosya okuma
    /// izni vermez ve sayfa boş kalır. Okuma izni dosyanın klasörüyle
    /// sınırlıdır, göreli CSS/JS yolları çalışır.
    func load(_ url: URL) {
        loadError = nil
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            return
        }
        webView.load(URLRequest(url: url))
    }

    func goBack() {
        guard webView.canGoBack else {
            return
        }
        webView.goBack()
    }

    func goForward() {
        guard webView.canGoForward else {
            return
        }
        webView.goForward()
    }

    /// Yüklenirken durdurur, dururken yeniden yükler.
    func reloadOrStop() {
        if isLoading {
            webView.stopLoading()
            isLoading = false
            return
        }
        if webView.url != nil {
            webView.reload()
        } else {
            submitAddress()
        }
    }

    /// Sekme kapanınca yükleme de durur; görünüm zaten bırakılır.
    func stop() {
        isStopped = true
        for observation in observations {
            observation.invalidate()
        }
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    func dismissDownloadNotice() {
        downloadNotice = nil
    }

    /// Geri/ileri listesinin anlık görüntüsü: en yakın geçmiş başta, güncel
    /// sayfa ortada işaretli, ileri liste sonda. Panel geçmiş menüsünü
    /// buradan kurar; liste boşsa menü de kurulmaz.
    func historySnapshot(limit: Int = 30) -> [BrowserHistoryEntry] {
        let list = webView.backForwardList
        var entries = list.backList.reversed().map {
            BrowserHistoryEntry(title: $0.title ?? $0.url.absoluteString, url: $0.url, isCurrent: false)
        }
        if let current = list.currentItem {
            entries.append(
                BrowserHistoryEntry(
                    title: current.title ?? current.url.absoluteString,
                    url: current.url,
                    isCurrent: true
                )
            )
        }
        entries += list.forwardList.map {
            BrowserHistoryEntry(title: $0.title ?? $0.url.absoluteString, url: $0.url, isCurrent: false)
        }
        return Array(entries.prefix(limit))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        loadError = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        syncFromWebView()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        syncFromWebView()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleFailure(error)
    }

    /// Web içerik süreci çöktü ya da bellek baskısıyla kapatıldı: görünüm boş
    /// beyaz kalırdı. Son adres yeniden yüklenir.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView.url != nil {
            webView.reload()
        } else if let lastSyncedURL {
            load(lastSyncedURL)
        }
    }

    /// Hata olmayan kesintiler sessiz geçer: kullanıcının başlattığı yeni
    /// yükleme eskisini iptal eder (-999), indirmeye dönen yanıt çerçeve
    /// yüklemesini keser (WebKit 102). Kesinti kontrolü yükleme durumuna
    /// dokunmadan yapılır; yoksa eski gezinmenin geç iptali yeni yüklemenin
    /// göstergesini söndürürdü.
    private func handleFailure(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return
        }
        if nsError.domain == Self.webKitErrorDomain, nsError.code == Self.frameLoadInterruptedCode {
            syncFromWebView()
            return
        }
        loadError = error.localizedDescription
        syncFromWebView()
    }

    /// `WebKitErrorFrameLoadInterruptedByPolicyChange`: Swift'e sabit olarak
    /// aktarılmaz. Etki alanı `WebKitErrorDomain`'dir (`WKError.errorDomain`
    /// yani `WKErrorDomain` değil).
    private static let frameLoadInterruptedCode = 102
    private static let webKitErrorDomain = "WebKitErrorDomain"

    private func syncFromWebView() {
        guard !isStopped else {
            return
        }
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        pageTitle = webView.title
        currentURL = webView.url
        if let url = webView.url, url != lastSyncedURL {
            lastSyncedURL = url
            addressText = url.absoluteString
        }
    }

    // MARK: - WKUIDelegate

    /// Yeni pencere yok: `target="_blank"` bağlantılar aynı görünümde açılır,
    /// böylece temel gezinme çalışır ve pencere yönetimi gerekmez.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    /// `alert()`: uygulanmadığında sayfa diyaloğu hiç göstermez.
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        let alert = Self.pageAlert(message: message, frame: frame)
        alert.addButton(withTitle: "OK")
        _ = await Self.present(alert, over: webView)
    }

    /// `confirm()`: uygulanmadığında her onay sessizce `false` dönerdi
    /// (ör. "silmek istediğine emin misin" düğmeleri hiç çalışmaz).
    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        let alert = Self.pageAlert(message: message, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await Self.present(alert, over: webView) == .alertFirstButtonReturn
    }

    /// `prompt()`: metin alanlı diyalog; vazgeçilirse `nil` döner.
    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        let alert = Self.pageAlert(message: prompt, frame: frame)
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let response = await Self.present(alert, over: webView)
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// `<input type="file">`: uygulanmadığında dosya seçici hiç açılmaz.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        // Gizli sekme (penceresiz) dosya seçici açamaz: uygulama çapında
        // kip, kullanıcının bakmadığı bir sayfadan fırlardı.
        guard let window = webView.window else {
            return nil
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.urls : nil
    }

    private static func pageAlert(message: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "This page says" : frame.securityOrigin.host
        alert.informativeText = message
        return alert
    }

    /// Diyalog, web görünümünün penceresine sayfa olarak bağlanır. Pencere
    /// yoksa (sekme gizli) diyalog gösterilmez ve "vazgeçildi" sayılır:
    /// uygulama çapında kip, kullanıcının bakmadığı bir sayfadan fırlardı.
    private static func present(_ alert: NSAlert, over webView: WKWebView) async -> NSApplication.ModalResponse {
        guard let window = webView.window else {
            return .cancel
        }
        return await alert.beginSheetModal(for: window)
    }

    // MARK: - İndirme (WKDownloadDelegate)

    /// Gösterilemeyen içerik (zip, dmg, pdf dışı…) indirmeye düşer; sayfa
    /// olduğu gibi kalır, indirme arka planda koşar.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if navigationResponse.canShowMIMEType {
            return .allow
        }
        return .download
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        pendingDownloadName = download.originalRequest?.url?.lastPathComponent
        download.delegate = self
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let name =
            pendingDownloadName?.isEmpty == false ? pendingDownloadName! : suggestedFilename
        pendingDownloadName = name
        return BrowserDownloadDestination.uniqueURL(
            suggestedFilename: name,
            in: BrowserDownloadDestination.downloadsDirectory()
        )
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloadNotice = "Downloaded “\(pendingDownloadName ?? "file")” to Downloads."
        pendingDownloadName = nil
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        downloadNotice = "Download failed: \(error.localizedDescription)"
        pendingDownloadName = nil
    }
}

/// Geçmiş menüsünün tek satırı.
struct BrowserHistoryEntry: Equatable, Sendable {
    let title: String
    let url: URL
    let isCurrent: Bool
}

/// İndirme hedefi: her zaman İndirilenler, çakışmada `-2`, `-3`… eklenir.
///
/// Saf çekirdek (`uniqueURL`) dosya varlığını dışarıdan alır, testte bellek
/// içi küme beslenir; üretim `FileManager` ile çağırır.
enum BrowserDownloadDestination {
    nonisolated static func downloadsDirectory() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    nonisolated static func uniqueURL(suggestedFilename: String, in directory: URL) -> URL {
        uniqueURL(
            suggestedFilename: suggestedFilename,
            in: directory,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    nonisolated static func uniqueURL(
        suggestedFilename: String,
        in directory: URL,
        fileExists: (String) -> Bool
    ) -> URL {
        let raw = suggestedFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = raw.isEmpty ? "download" : URL(fileURLWithPath: raw).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        let candidate = { (n: Int) -> String in
            if n <= 1 {
                return base
            }
            return ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
        }
        var n = 1
        while true {
            let url = directory.appendingPathComponent(candidate(n))
            if !fileExists(url.path) {
                return url
            }
            n += 1
        }
    }
}

/// Bölme başına tarayıcı sekmeleri: sayfa durumu görünümden bağımsız yaşar.
@MainActor
@Observable
final class BrowserServiceCenter {
    private var models: [String: BrowserTabModel] = [:]

    /// Inspector sekmesi başına açık web sayfalarının kimlikleri (sıralı).
    /// Panel şeridi burayı okur; ilk sayfa bölme kimliğini taşır (geriye
    /// uyumlu), sonrakiler `#2`, `#3`… sayacıyla gelir.
    private(set) var pageIDsByTab: [String: [String]] = [:]
    private var pageCounters: [String: Int] = [:]

    /// Sekme kimliğine ait model; yoksa kurulur. Görünüm gövdesinden
    /// çağrılmaz: gövdede çağırmak sözlüğü render sırasında değiştirir
    /// (`TerminalServiceCenter` ile aynı gerekçe); `onAppear` kullanır.
    func model(for id: String) -> BrowserTabModel {
        if let existing = models[id] {
            return existing
        }
        let created = BrowserTabModel()
        models[id] = created
        return created
    }

    /// Panel açıldı: sayfa listesi boşsa ilk sayfa kurulur, kimlikler döner.
    func ensurePages(tabID: String) -> [String] {
        if let existing = pageIDsByTab[tabID], !existing.isEmpty {
            return existing
        }
        _ = model(for: tabID)
        pageIDsByTab[tabID] = [tabID]
        pageCounters[tabID] = 1
        return [tabID]
    }

    /// Yeni boş sayfa açar, kimliğini döner. Başlangıç sayfası modelin
    /// kendi açılışında yüklenir.
    func newPage(tabID: String) -> String {
        var pages = ensurePages(tabID: tabID)
        let next = (pageCounters[tabID] ?? pages.count) + 1
        pageCounters[tabID] = next
        let id = "\(tabID)#\(next)"
        models[id] = BrowserTabModel()
        pages.append(id)
        pageIDsByTab[tabID] = pages
        return id
    }

    /// Web sayfasını kapatır; son sayfa kapanmaz, yerine tazesi açılır
    /// (tarayıcı paneli hiç sayfasız kalmaz).
    func closePage(_ id: String, tabID: String) {
        var pages = pageIDsByTab[tabID] ?? []
        pages.removeAll { $0 == id }
        models[id]?.stop()
        models.removeValue(forKey: id)
        if pages.isEmpty {
            pageCounters[tabID] = 1
            models[tabID] = BrowserTabModel()
            pages = [tabID]
        }
        pageIDsByTab[tabID] = pages
    }

    /// Gövde-içi kullanım için salt-okunur bakış.
    func existing(id: String) -> BrowserTabModel? {
        models[id]
    }

    func close(id: String) {
        models[id]?.stop()
        models.removeValue(forKey: id)
    }

    /// Inspector sekmesi kapandı: öneki taşıyan tüm web sayfaları durur
    /// (ilk sayfa önekin kendisidir, sonrakiler `#N` uzantılıdır).
    func closeAll(withPrefix prefix: String) {
        for id in models.keys where id == prefix || id.hasPrefix(prefix + "#") {
            models[id]?.stop()
            models.removeValue(forKey: id)
        }
        pageIDsByTab.removeValue(forKey: prefix)
        pageCounters.removeValue(forKey: prefix)
    }

    func closeAll() {
        for id in models.keys {
            models[id]?.stop()
        }
        models.removeAll()
        pageIDsByTab.removeAll()
        pageCounters.removeAll()
    }
}

// MARK: - Kişisel Chrome profili

/// Kullanıcının kişisel Chrome profilini `Local State` dosyasından çözer.
///
/// Saf: dosya okumaz, yalnız verilen JSON'dan profil seçer. Chrome kurulu
/// değilse ya da dosya okunamazsa diskten okuyan taraf `nil` döner, arayan
/// varsayılan tarayıcıya düşer.
enum ChromeProfileResolver {
    struct Profile: Sendable, Equatable {
        /// `--profile-directory=` değeridir (`Default`, `Profile 1`…).
        let directory: String
        /// Chrome'un gösterdiği profil adı (`Kişisel`, `Person 1`…).
        let name: String
    }

    private struct LocalState: Decodable {
        struct ProfileSection: Decodable {
            let infoCache: [String: InfoEntry]?

            enum CodingKeys: String, CodingKey {
                case infoCache = "info_cache"
            }
        }

        struct InfoEntry: Decodable {
            let name: String?
        }

        let profile: ProfileSection?
    }

    nonisolated static func localStateURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return URL(
            fileURLWithPath:
                "\(home)/Library/Application Support/Google/Chrome/Local State"
        )
    }

    /// Test edilebilir çekirdek: `Default` varsa onu, yoksa adı alfabetik ilk
    /// profili seçer (sözlük sırası tanımsızdır, kura çekilmez).
    static func personalProfile(localStateData: Data) -> Profile? {
        guard
            let state = try? JSONDecoder().decode(LocalState.self, from: localStateData),
            let cache = state.profile?.infoCache,
            !cache.isEmpty
        else {
            return nil
        }
        if let entry = cache["Default"] {
            return Profile(directory: "Default", name: entry.name ?? "Default")
        }
        guard let directory = cache.keys.sorted().first else {
            return nil
        }
        return Profile(directory: directory, name: cache[directory]?.name ?? directory)
    }

    /// Diskten okur; Chrome yoksa ya da dosya bozuksa `nil` döner.
    nonisolated static func personalProfileFromDisk() -> Profile? {
        guard
            let data = try? Data(contentsOf: localStateURL())
        else {
            return nil
        }
        return personalProfile(localStateData: data)
    }
}

/// Geçerli sayfayı kullanıcının gerçek Chrome profilinde açar.
///
/// Uygulama içi görünüm `WKWebView` (WebKit) motorudur; Chrome profili
/// (oturumlar, şifreler, uzantılar) WebKit'e taşınamaz. Çerez içe aktarma
/// (`BrowserProfileImporter`) yalnız okunabilen çerezleri taşır; Google girişi
/// gibi gerçek oturumlar yalnız Chrome'un kendisinde yaşar. Bu yüzden
/// "Chrome'da aç" düğmesi sayfayı `--profile-directory=` ile kullanıcının
/// kişisel profilinde çalışan gerçek Chrome'a verir; Chrome yoksa varsayılan
/// tarayıcıya düşülür.
enum PersonalChromeOpener {
    nonisolated static func chromeApplicationURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
    }

    @MainActor
    static func open(_ url: URL) {
        guard let chromeURL = chromeApplicationURL() else {
            NSWorkspace.shared.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // Çalışan Chrome'a URL verilirken profil bayrağı da taşınır: son
        // açılan (ör. İş) profili yerine kişisel profil kazanır.
        if let profile = ChromeProfileResolver.personalProfileFromDisk() {
            configuration.arguments = ["--profile-directory=\(profile.directory)"]
        }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: chromeURL,
            configuration: configuration,
            completionHandler: nil
        )
    }
}
