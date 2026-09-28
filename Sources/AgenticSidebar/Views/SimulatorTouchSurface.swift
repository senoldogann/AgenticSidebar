import AppKit
import SwiftUI

/// Cihaz ekran görüntüsünün üstündeki saydam dokunma katmanı.
///
/// Katman görüntüyle aynı boyda olduğu için konum doğrudan normalize
/// koordinata bölünür; tek eşleme noktası `SimulatorTouchMapper.normalized`
/// fonksiyonudur. Tek `DragGesture(minimumDistance: 0)` parmak indirme,
/// taşıma ve kaldırmayı sırayla bildirir; ayrı `onTapGesture` yoktur, bu
/// yüzden dokunma ile sürükleme birbirinin elinden olayı kapmaz. Kısa
/// dokunuş parmak indirme+kaldırma çifti olarak gider.
/// Basılıyken yüzey yüzde otuz kararır ve uyumlu izleme dörtgenlerinde
/// dokunsal tık verilir.
struct SimulatorTouchSurface: View {
    /// Parmak indirildi; oranlar 0..1 aralığındadır.
    let onPressDown: (Double, Double) -> Void
    /// Parmak basılıyken yeni konuma taşındı; oranlar 0..1 aralığındadır.
    let onPressMove: (Double, Double) -> Void
    /// Parmak kaldırıldı; oranlar 0..1 aralığındadır.
    let onPressUp: (Double, Double) -> Void

    /// Sürüklemenin ilk `onChanged` çağrısında parmak indirilir, sonrakiler
    /// taşıma olur; bayrak ikisini ayırır ve basma karartmasını sürer.
    @State private var isPressing: Bool = false

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .overlay {
                    if isPressing {
                        Color.black.opacity(0.3)
                            .allowsHitTesting(false)
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isPressing {
                                isPressing = true
                                Self.hapticTick()
                                let down = SimulatorTouchMapper.normalized(
                                    location: value.startLocation,
                                    in: proxy.size
                                )
                                onPressDown(down.x, down.y)
                            }
                            let move = SimulatorTouchMapper.normalized(
                                location: value.location,
                                in: proxy.size
                            )
                            onPressMove(move.x, move.y)
                        }
                        .onEnded { value in
                            isPressing = false
                            let up = SimulatorTouchMapper.normalized(
                                location: value.location,
                                in: proxy.size
                            )
                            onPressUp(up.x, up.y)
                        }
                )
                .pointingHandCursor()
        }
        .accessibilityLabel("Simulator screen. Press and drag to interact with the device.")
    }

    /// Parmak indiğinde dokunsal tık verir; donanım desteklemiyorsa sessizce
    /// geçilir, dokunuşun kendisi bundan etkilenmez.
    private static func hapticTick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}
