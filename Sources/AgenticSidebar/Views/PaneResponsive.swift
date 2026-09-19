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
