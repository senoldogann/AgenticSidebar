import Foundation

/// Kaydırma ölçümlerini toplayan, gövdeyi yeniden çizmeyen durum.
///
/// Ölçümü yapan geri çağrılar (`.onScrollGeometryChange`, `.onGeometryChange`)
/// bir ekran döngüsünün içinde çalışır. Oradan doğrudan `@State` yazmak, aynı
/// döngüde yeni bir yerleşim turu ister; o tur yeni bir ölçüm üretir. Zincir
/// kendi kendini beslediğinde AppKit tek bir döngüde yüzlerce "update
/// constraints" turu sayar ve sonunda istisna atar — uygulama tam olarak bu
/// yüzden çöktü: sayılan 368 tur, limit 367, `_postWindowNeedsUpdateConstraints`.
///
/// Bu yüzden geri çağrılar yalnız buraya yazar. Gövdeye yazma işi ekran
/// döngüsünün dışında, `publishInterval` aralığıyla ve yalnız değer gerçekten
/// değiştiğinde yapılır.
///
/// İkinci kural, "yukarıdayken aşağı inmek" hissi: kaydırma konusunun sahibi
/// kullanıcıdır. Sahiplik iki bağımsız sinyalle verilir — SwiftUI'nin bildirdiği
/// jest aşaması ve **ölçülen konumun düşmesi**. İkincisi cihazdan bağımsızdır:
/// altta büyüyen içerik konumu asla düşürmez, dolayısıyla düşüş hiçbir zaman
/// büyüme sanılamaz. Fare tekerleği, trackpad ya da kaydırma çubuğu — hangisiyle
/// kaydırırsa kaydırsın, kullanıcı en az bir adım yukarı çektiği anda takip
/// modu kapanır ve akan yanıt onu geri çekmez.
@MainActor
final class ScrollFollowState {
    /// Ölçümlerin gövdeye yayınlanma aralığı. Bir ekran döngüsünün çok üstünde,
    /// insan gözünün ayırt edemeyeceği kadar kısa.
    static let publishInterval: Duration = .milliseconds(90)

    /// Auto-follow'un en sık kaydırma aralığı.
    static let followInterval: TimeInterval = 0.12

    /// "Dipte" sayılmanın sınırı (takip modunun geri verilmesi için).
    static let bottomThreshold: CGFloat = 80

    /// "Scroll to end" butonunun görünmesi için en alttan gereken asgari mesafe.
    /// Kullanıcı dipten yeterince yukarı kaydırmadan (en az 180 pt) buton görünmez.
    static let buttonVisibilityThreshold: CGFloat = 180

    /// Bir ölçümün "yukarı hareket" sayılması için konumun bu kadar düşmesi
    /// gerekir. 4 pt'lik ölçüm adımının bir katından fazlası, yani gürültü değil
    /// gerçek bir yukarı çekiş.
    static let upwardStep: CGFloat = 8

    /// Yayınlanmayı bekleyen kararlar.
    struct Pending: Equatable {
        var awayFromBottom: Bool?
        var activePromptID: UUID?
    }

    /// Kullanıcının jesti sürüyor mu. Takip modu bu sürede kaydırmaz.
    private(set) var isUserScrolling = false

    /// Konumun sahibi kullanıcı mı? Kullanıcı yukarı çektiği anda doğru,
    /// yeniden dibe döndüğünde (ya da yeni tur başladığında) yanlış.
    private(set) var isUserPosition = false

    private var pendingAwayFromBottom: Bool?
    private var pendingActivePromptID: UUID?
    private var lastAutoScrollTime: Date = .distantPast

    /// En son ölçülen konum — yayınlanmış olsun ya da yayını beklesin.
    ///
    /// Yayın 90 ms gecikebildiği için takip kararı yalnız bu değere bakar:
    /// aksi halde kullanıcı yukarı kaydırıp bıraktıktan sonraki o kısa aralıkta
    /// akan yanıt görünümü dibe çekerdi.
    private var awayFromBottom = false

    /// Yukarı hareketi fark etmek için önceki ölçüm.
    private var lastOffsetY: CGFloat?

    /// Suppresses spurious offset drops during turn startup / settling so programmatic
    /// layout estimations do not falsely disable auto-follow or trigger blank screens.
    /// Monotonik saat: duvar saati değişimi (NTP, uyku) pencereyi uzatıp
    /// kısaltmamalı.
    private var suppressOffsetDropUntil: ContinuousClock.Instant?

    /// Kaydırma ölçümü.
    ///
    /// Büyüme ile kullanıcı hareketini ayıran yer burasıdır: konum düştüyse
    /// sahiplik kullanıcıya geçer, ve yalnız sahip olduğu ölçümler takip modunu
    /// kapatabilir. Yanıt büyürken okunan konum "yukarı kaydırıldı" diye
    /// yorumlanamaz — büyüme konumu düşürmez.
    func record(snapshot: ChatScrollSnapshot) {
        let isSuppressed = suppressOffsetDropUntil.map { ContinuousClock.now < $0 } ?? false
        let movedUp = lastOffsetY.map { snapshot.offsetY < $0 - Self.upwardStep } ?? false
        lastOffsetY = snapshot.offsetY

        if movedUp && (!isSuppressed || isUserScrolling) {
            isUserPosition = true
        }

        // If the entire content fits within the viewport, the user cannot be scrolled away from bottom.
        if snapshot.contentHeight <= snapshot.containerHeight + 10 {
            isUserPosition = false
            if awayFromBottom {
                awayFromBottom = false
                pendingAwayFromBottom = false
            }
            return
        }

        let isAtBottom = snapshot.distanceFromBottom <= Self.bottomThreshold

        if isAtBottom {
            isUserPosition = false
            if awayFromBottom {
                awayFromBottom = false
                pendingAwayFromBottom = false
            }
            return
        }

        guard isUserPosition || isUserScrolling else {
            return
        }

        let isFarEnoughForButton = snapshot.distanceFromBottom >= Self.buttonVisibilityThreshold

        if isFarEnoughForButton {
            guard !awayFromBottom else { return }
            awayFromBottom = true
            pendingAwayFromBottom = true
        } else if awayFromBottom && snapshot.distanceFromBottom < Self.buttonVisibilityThreshold {
            awayFromBottom = false
            pendingAwayFromBottom = false
        }
    }

    /// Rayın etkin prompt'u; yayın sırasına girer.
    func recordActivePrompt(_ id: UUID) {
        pendingActivePromptID = id
    }

    /// Jest durumu. Yayın aralığı bir jestten kısa olduğu için son ölçüm
    /// genelde zaten yayınlanmış olur; olmadıysa da silinmez — jestin bittiği
    /// yer takip modunu belirler. Silmek, yukarı kaydırıp bırakan kullanıcıyı
    /// akan yanıtın dibe geri çekmesi demekti.
    ///
    /// Bu sinyal tek başına yeterli değildir: SwiftUI bazı kaydırma araçları için
    /// aşamayı hiç bildirmez, ki gördüğümüz takılmaların bir kaynağı buydu.
    /// Konumun düşmesi kuralı onu tamamlar.
    func setScrolling(_ scrolling: Bool) {
        isUserScrolling = scrolling
    }

    /// Yeni bir tur başladı: takip yeniden hemen kaydırabilsin.
    func resumeFollow() {
        awayFromBottom = false
        pendingAwayFromBottom = false
        lastAutoScrollTime = .distantPast
        lastOffsetY = nil
        isUserPosition = false
        suppressOffsetDropUntil = Self.deadline(seconds: 0.6)
    }

    /// Programatik yerleşim sarsıntısı: inspector açılıp kapanırken genişlik
    /// animasyonu konumda sahte düşüşler üretir. Burası `resumeFollow` gibi
    /// kullanıcı durumunu silmez — yalnız düşüş yorumunu susturur — o yüzden
    /// tarihte okuyan kullanıcı dipte sayılmaz, dipteki kullanıcı da yukarıda.
    func suppressTransientDrop(for seconds: TimeInterval = 0.8) {
        let next = Self.deadline(seconds: seconds)
        if let current = suppressOffsetDropUntil, current > next {
            return
        }
        suppressOffsetDropUntil = next
    }

    func reset() {
        awayFromBottom = false
        pendingAwayFromBottom = nil
        pendingActivePromptID = nil
        lastAutoScrollTime = .distantPast
        lastOffsetY = nil
        isUserPosition = false
        // Yeni sohbetin ilk yerleşim adımları konumda sahte düşüşler üretir;
        // bastırılmazsa takip modu haksız yere kapanır ve dibe inilmez.
        suppressOffsetDropUntil = Self.deadline(seconds: 0.4)
    }

    /// Monotonik saate göre bastırma bitişi.
    private static func deadline(seconds: TimeInterval) -> ContinuousClock.Instant {
        ContinuousClock.now.advanced(by: .milliseconds(Int((seconds * 1_000).rounded())))
    }

    /// Akan yanıt görünümü dibe çekmeli mi?
    ///
    /// Üç koşul birden: kullanıcı jesti yok, son ölçüm dipte ve kaydırma
    /// aralığı doldu.
    func shouldAutoFollow(now: Date) -> Bool {
        guard !isUserScrolling, !awayFromBottom else {
            return false
        }

        return shouldAutoScroll(now: now)
    }

    /// Auto-follow en fazla `followInterval` aralıkla kaydırır: akan metnin her
    /// parçası bir kaydırma turu değildir.
    func shouldAutoScroll(now: Date) -> Bool {
        guard now.timeIntervalSince(lastAutoScrollTime) >= Self.followInterval else {
            return false
        }

        lastAutoScrollTime = now
        return true
    }

    /// Programatik yerleşim değişimlerinde (collapse, inspector) karar anındaki
    /// canlı durum: kullanıcı jesti yok, konum kullanıcıda değil ve son ölçüm
    /// dipte. `@State` kopyası değil bu sınıfın kendisi okunur — `Equatable`
    /// alt görünümlerden gelen kapanımlar bayat değer taşıyamaz.
    var isFollowing: Bool {
        !isUserScrolling && !isUserPosition && !awayFromBottom
    }

    /// Bekleyen kararları verir ve temizler; aynı ölçüm iki kez yayınlanmaz.
    func takePending() -> Pending {
        let pending = Pending(
            awayFromBottom: pendingAwayFromBottom,
            activePromptID: pendingActivePromptID
        )
        pendingAwayFromBottom = nil
        pendingActivePromptID = nil
        return pending
    }
}
