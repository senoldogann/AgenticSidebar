import Foundation

/// Zaman çizelgesindeki düşünme satırının metni.
///
/// Ölçüm görünümün içindeyken test edilemiyordu; saf bir fonksiyona taşındı,
/// böylece "Thought for Ns" hesabı bir görünüm çalıştırmadan doğrulanabilir.
enum ThinkingDurationPresentation {
    /// Düşünme satırında gösterilecek metin.
    ///
    /// - `startedAt`: düşünmenin başladığı an.
    /// - `completedAt`: bittiği an; hâlâ sürüyorsa `nil`.
    /// - `hasRunningChildren`: düşünme bitti ama turun araçları hâlâ çalışıyor.
    /// - `now`: ölçümün yapıldığı an.
    static func text(
        startedAt: Date,
        completedAt: Date?,
        isRunning: Bool,
        hasRunningChildren: Bool,
        now: Date
    ) -> String {
        if isRunning {
            return "Thinking for \(seconds(from: startedAt, to: now))s..."
        }

        let thoughtSeconds = seconds(from: startedAt, to: completedAt ?? now)

        guard hasRunningChildren else {
            return "Thought for \(thoughtSeconds)s"
        }

        let totalSeconds = seconds(from: startedAt, to: now)
        return "Thought for \(thoughtSeconds)s · Working (\(totalSeconds)s)"
    }

    /// Geçen saniye. Saat geri alınmış olsa bile negatif bir süre gösterilmez ve
    /// bir saniyenin altı "0s" değil "1s" okunur.
    private static func seconds(from startedAt: Date, to endedAt: Date) -> Int {
        max(1, Int(endedAt.timeIntervalSince(startedAt)))
    }
}
