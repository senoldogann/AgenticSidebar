import SwiftUI

/// Bölme genişliğini alt ağaca taşıyan ortam anahtarı.
///
/// Kök ızgara her bölmeyi sabit çerçeveyle çizer; genişlik buradan okunup
/// ortama yazılır. Alt görünümler pencereyi değil kendi bölmesini baz alır,
/// böylece 2'li ve 4'lü düzende her bölme bağımsız uyum sağlar.
struct PaneWidthKey: EnvironmentKey {
    static let paneDefaultWidth: CGFloat = 1000
    static var defaultValue: CGFloat {
        paneDefaultWidth
    }
}

extension EnvironmentValues {
    var paneWidth: CGFloat {
        get { self[PaneWidthKey.self] }
        set { self[PaneWidthKey.self] = newValue }
    }
}

/// Bölme genişliğine göre seçilen sade boyut sınıfı.
enum PaneSizeClass: Equatable, Sendable {
    case compact
    case medium
    case regular
}

/// Dar bölmelerde taşmayı önleyen saf düzen yardımcıları.
///
/// Tüm kararlar genişlikten türetilir; görünüm durumu tutulmaz.
enum PaneResponsive {
    /// Dar bölme eşiği: 4'lü ızgarada tipik bölme genişliği.
    static let compactThreshold: CGFloat = 460
    /// Orta bölme eşiği: 2'li düzende daraltılmış pencere.
    static let mediumThreshold: CGFloat = 680

    static func sizeClass(forWidth width: CGFloat) -> PaneSizeClass {
        if width < compactThreshold {
            return .compact
        }
        if width < mediumThreshold {
            return .medium
        }
        return .regular
    }

    static func isCompact(width: CGFloat) -> Bool {
        sizeClass(forWidth: width) == .compact
    }

    static func isMediumOrSmaller(width: CGFloat) -> Bool {
        sizeClass(forWidth: width) != .regular
    }

    /// Besteci minimal mi: 2'li ve 4'lü düzende alan daralır.
    ///
    /// Orta ve kompakt bölmeler aynı minimal besteciyi kullanır; tekli
    /// düzenli görünüm etkilenmez. Saf karar, durum tutulmaz.
    static func isMinimalComposer(width: CGFloat) -> Bool {
        isMediumOrSmaller(width: width)
    }

    /// Besteci dış yatay boşluğu; dar ızgarada içerik genişliği korunur.
    static func composerOuterHorizontal(forWidth width: CGFloat) -> CGFloat {
        switch sizeClass(forWidth: width) {
        case .compact:
            return 4
        case .medium:
            return 4
        case .regular:
            return 20
        }
    }

    /// Besteci dış dikey boşluğu; 4'lü ızgarada transkripte yer açar.
    static func composerOuterVertical(forWidth width: CGFloat) -> CGFloat {
        switch sizeClass(forWidth: width) {
        case .compact:
            return 2
        case .medium:
            return 2
        case .regular:
            return 6
        }
    }

    /// Besteci kutu iç yatay dolgusu; dar bölmede yazı alanı genişler.
    static func composerBoxHorizontal(forWidth width: CGFloat) -> CGFloat {
        switch sizeClass(forWidth: width) {
        case .compact:
            return 5
        case .medium:
            return 6
        case .regular:
            return 14
        }
    }

    /// Besteci kutu iç dikey dolgusu; yükseklik buradan kısalır.
    static func composerBoxVertical(forWidth width: CGFloat) -> CGFloat {
        switch sizeClass(forWidth: width) {
        case .compact:
            return 4
        case .medium:
            return 4
        case .regular:
            return 8
        }
    }

    /// Besteci dikey yığın aralığı; paneller ve kutu arası boşluk.
    static func composerStackSpacing(forWidth width: CGFloat) -> CGFloat {
        switch sizeClass(forWidth: width) {
        case .compact:
            return 3
        case .medium:
            return 3
        case .regular:
            return 8
        }
    }

    /// Besteci kutu içi dikey aralık; satırlar arası boşluk.
    static func composerBoxSpacing(forWidth width: CGFloat) -> CGFloat {
        switch sizeClass(forWidth: width) {
        case .compact:
            return 3
        case .medium:
            return 3
        case .regular:
            return 8
        }
    }

    /// Besteci metin alanı en küçük yüksekliği.
    static func composerEditorMinHeight(forWidth width: CGFloat) -> CGFloat {
        switch sizeClass(forWidth: width) {
        case .compact:
            return 18
        case .medium:
            return 20
        case .regular:
            return 26
        }
    }

    /// Besteci metin alanı en büyük yüksekliği; dar ızgarada transkript ezilmesin.
    static func composerEditorMaxHeight(forWidth width: CGFloat) -> CGFloat {
        switch sizeClass(forWidth: width) {
        case .compact:
            return 32
        case .medium:
            return 40
        case .regular:
            return 96
        }
    }

    /// Besteci kutu köşe yarıçapı; minimalde görsel ağırlık azalır.
    static func composerCornerRadius(forWidth width: CGFloat) -> CGFloat {
        switch sizeClass(forWidth: width) {
        case .compact:
            return 8
        case .medium:
            return 8
        case .regular:
            return 16
        }
    }

    /// Besteci işlem düğmesi çapı; gönder/durdur/ek aynı boyda durur.
    static func composerControlButtonSize(forWidth width: CGFloat) -> CGFloat {
        if isMinimalComposer(width: width) {
            return 22
        }
        return 28
    }

    /// Besteci hap iç yatay dolgusu; dar bölmede hap sırası kısalır.
    static func composerPillHorizontal(forWidth width: CGFloat) -> CGFloat {
        switch sizeClass(forWidth: width) {
        case .compact:
            return 4
        case .medium:
            return 5
        case .regular:
            return 9
        }
    }

    /// Besteci hap iç dikey dolgusu.
    static func composerPillVertical(forWidth width: CGFloat) -> CGFloat {
        switch sizeClass(forWidth: width) {
        case .compact:
            return 2
        case .medium:
            return 3
        case .regular:
            return 5
        }
    }

    /// Denetim satırı yatay aralığı.
    static func composerControlSpacing(forWidth width: CGFloat) -> CGFloat {
        if isMinimalComposer(width: width) {
            return 3
        }
        return 6
    }

    /// Denetim satırı üst boşluğu; minimalde sıfırlanır.
    static func composerControlTopPadding(forWidth width: CGFloat) -> CGFloat {
        if isMinimalComposer(width: width) {
            return 0
        }
        return 2
    }

    /// Transkript ve besteci dış kenar boşluğu.
    static func outerPadding(forWidth width: CGFloat) -> CGFloat {
        switch sizeClass(forWidth: width) {
        case .compact:
            return 10
        case .medium:
            return 14
        case .regular:
            return 20
        }
    }

    /// Satır içi kartların iç yatay dolgusu.
    static func innerPadding(forWidth width: CGFloat) -> CGFloat {
        switch sizeClass(forWidth: width) {
        case .compact:
            return 10
        case .medium:
            return 12
        case .regular:
            return 14
        }
    }

    /// Kullanıcı balonu önündeki boşluk; dar bölmede içerik ezilmesin.
    static func userBubbleLeadingSpacer(forWidth width: CGFloat) -> CGFloat {
        switch sizeClass(forWidth: width) {
        case .compact:
            return 8
        case .medium:
            return 32
        case .regular:
            return 60
        }
    }

    /// Asistan satırı sonundaki boşluk.
    static func assistantTrailingSpacer(forWidth width: CGFloat) -> CGFloat {
        switch sizeClass(forWidth: width) {
        case .compact:
            return 8
        case .medium:
            return 20
        case .regular:
            return 40
        }
    }

    /// Transkript sol girintisi; dar bölmede ray gizlendiği için küçülür.
    static func transcriptLeading(forWidth width: CGFloat, hasRail: Bool) -> CGFloat {
        if isCompact(width: width) {
            return 8
        }
        if hasRail {
            return PromptRailMetrics.columnWidth
        }
        return 20
    }

    /// Sağ çekmece genişliği; dar bölmede bölmenin üstünü tamamen kaplamaz.
    static func inspectorWidth(
        requested: CGFloat,
        available: CGFloat,
        isExpanded: Bool
    ) -> CGFloat {
        if isExpanded {
            let target: CGFloat = available - 32
            let floored: CGFloat = max(280, target)
            return max(280, min(requested, floored))
        }
        let cap: CGFloat = max(280, available - 32)
        return min(requested, cap)
    }
}

/// Bölme genişliğini ortama yazan ince sarmalayıcı.
///
/// `GeometryReader` dış çerçeveden boyu okur, içeriğe ortam olarak verir.
/// Ortam değişimi yukarı akmadığı için yerleşim döngüsü oluşmaz.
struct PaneWidthReader<Content: View>: View {
    let content: Content

    init(content: Content) {
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            content
                .environment(\.paneWidth, proxy.size.width)
        }
    }
}

extension View {
    /// Bu görünümün alt ağacına bölme genişliğini sağlar.
    func paneWidthEnvironment() -> some View {
        PaneWidthReader(content: self)
    }
}
