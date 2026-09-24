import AppKit
import Foundation

/// Dizin seçici ve klasör görünen-adı için tek kaynak.
///
/// Aynı `NSOpenPanel` yapılandırması ve aynı `lastPathComponent` türetimi
/// dört ayrı dosyada kopyalanmıştı; uç durumlar (`"/"`, boşluk yığını,
/// sondaki `/`) her sitede farklı davranıyordu.
enum DirectoryPicker {
    /// Yalnızca dizin kabul eden seçiciyi açar; vazgeçilirse `nil` döner.
    ///
    /// Modal çalışır (ana iş parçacığını bekletir): akış sırasında açılan
    /// seçicilerde donma bilinir kısıttır; bestecideki ek diyaloğu gibi
    /// sheet-tabanlı akışa geçiş ayrı bir iştir.
    @MainActor
    static func chooseDirectory(prompt: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = prompt
        panel.message = message
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

/// Klasör yolunun görünen adı için tek kaynak; boş/boşluk yolda `nil`.
///
/// `SessionSummary.workingDirectoryName`, kenar çubuğu etiketi ve bekleyen
/// taslak ipucu aynı kararı verir; ayrışma `"/"` gibi uçlarda farklı
/// etiket demekti.
enum WorkingDirectoryDisplay {
    static func name(for path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else {
            return nil
        }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return name.isEmpty ? nil : name
    }

    /// Sohbet başlığının proje önekli hali; klasörsüzde başlık aynen döner.
    ///
    /// Örnek: `AgenticSidebar > Merhaba`. Sol menü kartı, pencere başlığı ve
    /// bölme başlıkları aynı biçimi kullanır.
    static func qualifiedTitle(title: String, directoryPath: String?) -> String {
        guard let folder = name(for: directoryPath) else {
            return title
        }
        return "\(folder) > \(title)"
    }
}
