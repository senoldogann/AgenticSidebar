import SwiftUI

/// Uygulama genelinde tek saniye saati.
///
/// Her satırın kendi `TimelineView(.periodic)` saati yerine geçer: N satır =
/// N ayrı 1Hz zamanlayıcı ve N ayrı görünüm güncellemesi yerine tek
/// zamanlayıcı çalışır. Kimse dinlemiyorken saat durur, pil harcamaz.
@MainActor
@Observable
final class SharedSecondClock {
    static let shared = SharedSecondClock()

    private(set) var now = Date()

    private var retainCount = 0
    private var task: Task<Void, Never>?

    /// Dinleyici kaydı; son dinleyici ayrılınca zamanlayıcı durur.
    func retain() {
        retainCount += 1
        guard retainCount == 1 else {
            return
        }
        now = Date()
        task = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else {
                    return
                }
                self.now = Date()
            }
        }
    }

    /// Dinleyici bırakma; sayaç sıfırlanınca zamanlayıcı iptal edilir.
    func release() {
        retainCount = max(0, retainCount - 1)
        if retainCount == 0 {
            task?.cancel()
            task = nil
        }
    }
}

/// Saniye saatiyle beslenen içerik: satır başına `TimelineView`
/// zamanlayıcısı kurmaz, paylaşılan tek saati dinler.
///
/// `now` okunduğu için görünüm saniyede bir yeniden değerlendirilir;
/// görünüm ekrandayken saate kayıtlıdır, kaybolunca kaydı bırakır.
struct SecondTick<Content: View>: View {
    @State private var clock = SharedSecondClock.shared
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        content(clock.now)
            .onAppear {
                clock.retain()
            }
            .onDisappear {
                clock.release()
            }
    }
}
