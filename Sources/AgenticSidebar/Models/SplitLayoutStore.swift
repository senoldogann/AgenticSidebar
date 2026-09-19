import Foundation
import Observation

/// 2×2 sohbet ızgarasının durumu: tekli, yan yana ikili ya da dörtlü düzen.
///
/// Birincil yuva (`primary`, sol-üst) sabitlenmez; her zaman aktif oturumu
/// izler. Diğer üç yuva sabitlenmiş oturum ya da boştur. İki yuva asla aynı
/// oturumu göstermez; silinen oturum yuvada kalamaz. Düzen kipi, yuvalar ve
/// ayraç oranları `UserDefaults` ile yeniden başlatmada korunur. Odaklanan
/// yuva (HUD takibi) geçicidir, saklanmaz.
///
/// Eski ikili API (`secondarySessionID`, `openSecondary` …) yeni modelin
/// üstünde çalışır: ikincil yuva birebir aynı anlamı taşır, o yüzden eski
/// davranış ve eski testler değişmez.
@MainActor
@Observable
final class SplitLayoutStore {
    // MARK: - Izgara modeli

    /// Sabitlenmiş yuvalar; birincil asla burada değildir.
    private(set) var slots: [PaneSlot: UUID] = [:]
    private(set) var layoutMode: PaneLayoutMode = .single
    /// Izgarada sol/sağ oranı; 0.25 ile 0.75 arası tutulur.
    private(set) var columnFraction: Double = 0.5
    /// Izgarada üst/alt oranı; 0.25 ile 0.75 arası tutulur.
    private(set) var rowFraction: Double = 0.5
    /// HUD'un izlediği yuva; kalıcı değildir, her açılışta birincildir.
    var focusedSlot: PaneSlot = .primary

    private let userDefaults: UserDefaults
    private let secondaryKey: String
    private let fractionKey: String

    private static let slotsKey = "SplitLayout.slots"
    private static let modeKey = "SplitLayout.mode"
    private static let columnKey = "SplitLayout.columnFraction"
    private static let rowKey = "SplitLayout.rowFraction"

    /// Sabitlenebilir yuvalar, atama önceliği sırasıyla.
    private static let pinnableSlots: [PaneSlot] = [.secondary, .tertiary, .quaternary]

    init(
        userDefaults: UserDefaults = .standard,
        secondaryKey: String = "SplitLayout.secondarySessionID",
        fractionKey: String = "SplitLayout.splitFraction"
    ) {
        self.userDefaults = userDefaults
        self.secondaryKey = secondaryKey
        self.fractionKey = fractionKey
        restoreSlots()
        let storedFraction = userDefaults.double(forKey: fractionKey)
        if storedFraction > 0 {
            splitFraction = Self.clampedFraction(storedFraction)
        }
        if let rawMode = userDefaults.string(forKey: Self.modeKey),
            let mode = PaneLayoutMode(rawValue: rawMode)
        {
            layoutMode = mode
        }
        let storedColumn = userDefaults.double(forKey: Self.columnKey)
        if storedColumn > 0 {
            columnFraction = Self.clampedFraction(storedColumn)
        }
        let storedRow = userDefaults.double(forKey: Self.rowKey)
        if storedRow > 0 {
            rowFraction = Self.clampedFraction(storedRow)
        }
    }

    // MARK: - Yuva atamaları

    /// Yuvadaki sabitlenmiş oturum; birincil için `nil` (aktif izlenir).
    func sessionID(for slot: PaneSlot) -> UUID? {
        slots[slot]
    }

    /// Oturumun sabitlendiği yuva; birincilde izlenen aktif sayılmaz.
    func slot(containing id: UUID) -> PaneSlot? {
        Self.pinnableSlots.first { slots[$0] == id }
    }

    /// Sabitlenmiş oturum kimlikleri.
    var pinnedSessionIDs: Set<UUID> {
        Set(slots.values)
    }

    /// Oturumu yuvaya sabitler. Oturum başka yuvadaysa içerikler takas olur;
    /// hedef doluysa yerinden edilen ilk boş yuvaya geçer, boş yoksa düşer.
    /// Birincil yuva sabitlenemez (aktif oturumu izler), istek yok sayılır.
    /// Oturum zaten hedef yuvadaysa bir şey değişmez.
    func pin(_ id: UUID, to slot: PaneSlot) {
        guard slot != .primary else {
            return
        }
        guard slots[slot] != id else {
            return
        }
        let displaced = slots[slot]
        if let source = self.slot(containing: id) {
            if let occupant = displaced {
                slots[source] = occupant
            } else {
                slots.removeValue(forKey: source)
            }
        } else if let occupant = displaced,
            let free = Self.pinnableSlots.first(where: { $0 != slot && slots[$0] == nil })
        {
            slots[free] = occupant
        }
        slots[slot] = id
        persistSlots()
        persistSecondary()
    }

    /// Yan menüden "yan tarafta aç": sabitse çözer, değilse ilk boş yuvaya
    /// sabitler (tekli kipte ikiliye geçirir). Boş yuva yoksa istek yok
    /// sayılır. Etkilenen yuvayı döner, çözmede ya da dolulukta `nil`.
    @discardableResult
    func togglePin(_ id: UUID) -> PaneSlot? {
        if let slot = slot(containing: id) {
            slots.removeValue(forKey: slot)
            if slot == .secondary, layoutMode == .dual {
                layoutMode = .single
                persistMode()
            }
            persistSlots()
            persistSecondary()
            return nil
        }
        guard let free = Self.pinnableSlots.first(where: { slots[$0] == nil }) else {
            return nil
        }
        slots[free] = id
        if layoutMode == .single {
            layoutMode = .dual
            persistMode()
        }
        persistSlots()
        persistSecondary()
        return free
    }

    /// Oturumu hangi yuvadaysa çözer.
    func unpin(_ id: UUID) {
        guard let slot = slot(containing: id) else {
            return
        }
        unpinSlot(slot)
    }

    /// Yuvayı boşaltır. İkili kipte ikincil çözülünce tekliye dönülür;
    /// dörtlü kipte yuvalar korunur (gizlenen değil, boşalan vardır).
    func unpinSlot(_ slot: PaneSlot) {
        guard slot != .primary, slots[slot] != nil else {
            return
        }
        slots.removeValue(forKey: slot)
        if slot == .secondary, layoutMode == .dual {
            layoutMode = .single
            persistMode()
        }
        persistSlots()
        persistSecondary()
    }

    func setLayoutMode(_ mode: PaneLayoutMode) {
        layoutMode = mode
        persistMode()
    }

    func focus(_ slot: PaneSlot) {
        focusedSlot = slot
    }

    /// HUD'un izleyeceği oturum: odaklı yuvadaki canlı oturum, yoksa aktif.
    func resolvedFocusSessionID(activeID: UUID, liveIDs: Set<UUID>) -> UUID {
        if focusedSlot != .primary,
            let pinned = slots[focusedSlot],
            liveIDs.contains(pinned)
        {
            return pinned
        }
        return activeID
    }

    // MARK: - Ayraç oranları

    /// Birincil bölmenin toplam genişliğe oranı; 0.25 ile 0.75 arası tutulur.
    private(set) var splitFraction: Double = 0.5

    /// Sürüklenen ayraçtan gelen oranı sınırlar ve saklar.
    func setSplitFraction(_ fraction: Double) {
        splitFraction = Self.clampedFraction(fraction)
        userDefaults.set(splitFraction, forKey: fractionKey)
    }

    /// Izgara sol/sağ oranı.
    func setColumnFraction(_ fraction: Double) {
        columnFraction = Self.clampedFraction(fraction)
        userDefaults.set(columnFraction, forKey: Self.columnKey)
    }

    /// Izgara üst/alt oranı.
    func setRowFraction(_ fraction: Double) {
        rowFraction = Self.clampedFraction(fraction)
        userDefaults.set(rowFraction, forKey: Self.rowKey)
    }

    /// Sürükleme sırasında oranı YALNIZ bellekte günceller.
    ///
    /// Ayraç sürüklemesi tek bir kullanıcı kararıdır; fare/izleme yüzeyi olay
    /// başına bir `UserDefaults` yazımı üretmek yerine görünüm sürükleme
    /// boyunca buradan beslenir ve kalıcılık parmak kalkınca `commitFractions()`
    /// ile tek seferde olur.
    func previewSplitFraction(_ fraction: Double) {
        splitFraction = Self.clampedFraction(fraction)
    }

    func previewColumnFraction(_ fraction: Double) {
        columnFraction = Self.clampedFraction(fraction)
    }

    func previewRowFraction(_ fraction: Double) {
        rowFraction = Self.clampedFraction(fraction)
    }

    /// Sürükleme bitti: o anki üç oranı kalıcılaştırır.
    func commitFractions() {
        userDefaults.set(splitFraction, forKey: fractionKey)
        userDefaults.set(columnFraction, forKey: Self.columnKey)
        userDefaults.set(rowFraction, forKey: Self.rowKey)
    }

    private static func clampedFraction(_ fraction: Double) -> Double {
        min(0.75, max(0.25, fraction))
    }

    // MARK: - Doğrulama

    /// Silinen ya da yinelenen oturum yuvada kalamaz (ilk yuva kazanır).
    /// Birincil olan oturum hiçbir sabit yuvada duramaz: iki bölme asla aynı
    /// sohbeti göstermez. Kenar çubuğundan seçilen sabitli oturum takas
    /// mantığıyla birincile taşınır, doğrulama onu ezmez.
    func validate(liveIDs: Set<UUID>, primary: UUID) {
        var seen = Set<UUID>()
        var didChange = false
        for slot in Self.pinnableSlots {
            guard let id = slots[slot] else {
                continue
            }
            if !liveIDs.contains(id) || !seen.insert(id).inserted {
                slots.removeValue(forKey: slot)
                didChange = true
                continue
            }
            if id == primary {
                slots.removeValue(forKey: slot)
                didChange = true
            }
        }
        // Doğrulama her oturum-listesi değişiminde koşar ve çoğu kez hiçbir şey
        // düşürmez; değişmediyse diske yazılmaz.
        guard didChange else {
            return
        }
        persistSlots()
        persistSecondary()
    }

    // MARK: - Eski ikili API (uyumluluk)

    /// İkincil bölmede sabitlenmiş oturum; `nil` iken tekli görünüm vardır.
    var secondarySessionID: UUID? {
        slots[.secondary]
    }

    var isSideBySide: Bool {
        secondarySessionID != nil
    }

    /// Bırakılan oturumu ikincil bölmeye sabitler. Birincil bölmeyle aynı
    /// oturum bırakılırsa istek yok sayılır: iki bölme asla aynı sohbeti
    /// göstermez.
    func openSecondary(_ id: UUID, primary: UUID) {
        guard id != primary else {
            return
        }
        pin(id, to: .secondary)
        if layoutMode == .single {
            layoutMode = .dual
            persistMode()
        }
    }

    /// İkincil bölmeyi kapatıp tekli görünüme döner.
    func closeSecondary() {
        unpinSlot(.secondary)
    }

    /// Yan menüden "yan tarafta aç": aynı oturumsa kapatır, değilse sabitler.
    func toggleSecondary(_ id: UUID, primary: UUID) {
        if slots[.secondary] == id {
            closeSecondary()
        } else {
            openSecondary(id, primary: primary)
        }
    }

    // MARK: - Kalıcılık

    private func restoreSlots() {
        if let stored = userDefaults.array(forKey: Self.slotsKey) as? [String] {
            for entry in stored {
                let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2,
                    let slot = PaneSlot(rawValue: parts[0]),
                    slot != .primary,
                    let id = UUID(uuidString: parts[1])
                else {
                    continue
                }
                slots[slot] = id
            }
            return
        }
        // Eski ikili kayıttan göç: ikincil yuva dolar, kip ikiliye döner.
        if let stored = userDefaults.string(forKey: secondaryKey),
            let id = UUID(uuidString: stored)
        {
            slots[.secondary] = id
            layoutMode = .dual
            persistSlots()
            persistMode()
        }
    }

    private func persistSlots() {
        let stored = Self.pinnableSlots.compactMap { slot -> String? in
            guard let id = slots[slot] else {
                return nil
            }
            return "\(slot.rawValue):\(id.uuidString)"
        }
        userDefaults.set(stored, forKey: Self.slotsKey)
    }

    private func persistMode() {
        userDefaults.set(layoutMode.rawValue, forKey: Self.modeKey)
    }

    private func persistSecondary() {
        if let secondarySessionID {
            userDefaults.set(secondarySessionID.uuidString, forKey: secondaryKey)
        } else {
            userDefaults.removeObject(forKey: secondaryKey)
        }
    }
}
