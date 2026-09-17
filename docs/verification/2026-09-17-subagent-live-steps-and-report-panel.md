# Alt ajan canlı adımları ve rapor paneli — 2026-09-17

## Sorun

1. Bir alt ajan koşarken kart yalnızca "Subagent initializing and preparing
   tools…" gösteriyordu. Neden iki katmanlıydı:
   - `task` parçasının `state.metadata.summary` alanı yönetilen OpenCode
     1.18.31'de hiç üretilmiyor (depodaki 439 task parçasının tamamında yok),
     dolayısıyla metadata'dan adım okuma yolu ölüydü.
   - Çocuk oturumun gerçek araç olayları global `/event` akışında geliyor ama
     normalizer bunları oturum filtresine takıp düşürüyordu.
2. Ayrıca canlı içerik değişimleri UI'a hiç ulaşmıyordu: `TranscriptIndexCache`
   anahtarı yalnız aktivite sayısı ve fazlara bakıyordu; `updateActivity`
   yalnız başlık/detay/çıktı yazdığı için anahtar değişmiyor ve satır
   önbellekteki eski grupla çiziliyordu (iki bağımsız denetçinin P1 bulgusu).
3. Biten alt ajanın raporu kartın gövdesine ham metin olarak basılıyordu;
   düzgün okunacak bir yüzey yoktu.

## Değişiklikler

### Canlı adımlar (`OpenCodeStreamNormalizer`)

- `task` parçasının `state.metadata.sessionId` alanı çocuk oturumu bildirir;
  eşleme öğrenilir (`subagentOwnerByChildSession`).
- Eşlemesi öğrenilmiş çocuk oturumların **yalnız araç** parçaları üstteki
  `task` aktivitesine `.activityUpdated` olarak yazılır. Metin/akıl yürütme
  asla taşınmaz. Eşleme gelmeden görülen adımlar sınırlı tamponda bekler
  (8 oturum × 64 adım) ve eşleme gelince tek güncellemeyle boşalır.
- Adım satırı biçimi mevcut kart ayrıştırıcısıyla uyumludur:
  `✓ Read — Analyzed Session.swift`, `… Bash — Running swift build`,
  `✗ Edit — foo.swift` (en fazla 20 satır + "… N earlier steps").
- Bitişte `output` artık **yalnız nihai rapordur**; adım listesi kartta kalır,
  rapor sağ panelde okunur.
- `metadata.summary` yolunu kullanan eski fonksiyonlar
  (`subagentRunningOutput`, `subagentResultOutput`, `subagentInnerSteps`)
  kaldırıldı.

### Bayat önbellek (`TranscriptIndex` + `AgentSession`)

- `AgentSessionState.activityRevision` sayacı eklendi; `startActivity`,
  `updateActivity`, `finishActivity` içerik değişiminde artırır.
- `TranscriptIndexCache.GroupKey` sayaca bakar; içerik değişince satır
  taze grupla çizilir. Sayaç arşive yazılmaz.

### Kart ve rapor paneli (`AgentActivityTimelineView`, `SubagentReportPanelView`)

- Kart başlığı önce `title` gösterir; "Completed" rozeti süreyi de söyler
  (`Completed · 3m 12s`).
- Koşarken canlı araç satırları; koşan alt ajan satırı otomatik açılır.
- Bitince özet satırı + **Read report** düğmesi. Düğme, sağda açılan
  `SubagentReportPanelView`'ı doldurur: markdown, seçilebilir, kopyalanabilir.
- Gövde listesi `LazyVStack`'e çekildi (denetim bulgusu).

## Doğrulama

- `swift build --product AgenticSidebar -Xswiftc -warnings-as-errors` → temiz.
- `RUN_KEYCHAIN_TESTS=0 swift test -Xswiftc -warnings-as-errors` →
  **589 test, 2 skip, 0 hata** (15:15). Önceki tur 588'di; +1 yeni test.
- Yeni/güncellenen testler (`OpenCodeStreamNormalizerTests`, `PerformanceTests`):
  - Çocuk araç olayı canlı güncelleme üretir; durum geçişi satırı ✓/… yapar.
  - Eşleme gelmeden görülen adım tamponlanır ve metadata gelince boşalır.
  - Bitişte rapor tek başına taşınır, adımlar raporda tekrarlanmaz.
  - İlgisiz oturumun olayı karta yazılmaz.
  - `activityRevision` değişimi grup önbelleğini tazeler (kart donması testi).

## Bilinen sınırlar

- Canlı adımlar uygulama açıkken tamdır; arşivde rapor 4 000 karakterle
  sınırlıdır (`SessionArchive.maximumActivityOutputLength`), yeniden açılışta
  rapor bu sınırla görünür.
- İç içe alt ajan (alt ajanın alt ajan çağırması) tek seviye olarak
  gösterilir: çocuk oturumdaki `task` parçası bir adım satırı olur.
