# AgenticSidebar — V2 öncesi temel incelemesi (tamamlandı)

## Baseline Doğrulama ve Dondurma Tamamlandı — 2026-09-19 17:35 TRT

Tüm temel güvenlik açıkları (AS-V2-BASE-01 .. AS-V2-BASE-05), orta-koşu persistence fail-closed korumaları ve CI gating gereksinimleri başarıyla doğrulanmış ve dondurulmuştur:

1. **Tam Test Paketi (Hermetic Test Suite):**
   - `swift test`: **1094 test çalıştırıldı, 2 atlandı, 0 hata (0 unexpected failures)**, çıkış kodu 0 (14.26s).
   - `swift test -Xswiftc -warnings-as-errors`: **1094 test, 0 failure, 0 unexpected**, çıkış kodu 0.
   - Tüm regresyon testleri (`GoalStoreTests`, `GoalOrchestratorTests`, `ToolApprovalPolicyTests`, `ToolApprovalSymlinkRegressionTests`, `ClipboardMonitorServiceTests`, `GoalRunnersTests`, `SettingsOrganizationTests`, `ToolApprovalRoutingRegressionTests`) eksiksiz YEŞİL.

2. **Derleme ve CI Warnings-as-Errors Gate:**
   - `swift build --product AgenticSidebar`: exit 0.
   - `swift build --product AgenticSidebar -Xswiftc -warnings-as-errors`: **exit 0, 0 warning, 0 error** (204 kaynak derlendi ve bağlandı).

3. **Pinned Strict swift-format Gate:**
   - Homebrew pinned version: `/opt/homebrew/bin/swift-format --version` -> `604.0.0` (CI `.github/workflows/ci.yml` `SWIFT_FORMAT_VERSION: 604.0.0` ile tam eşleşiyor).
   - Biçimlendirme gereksinimleri (`Sources/AgenticSidebar/ProviderGateway/ProviderTypes.swift`, `ToolApprovalPolicy.swift`, `ComputerUseReadiness.swift`, `ConversationDetailView.swift`, `ContextRingView.swift`) düzeltildi.
   - `/opt/homebrew/bin/swift-format lint -r --strict Sources Tests`: **exit 0, tertemiz (0 lint violation)**.

4. **Git ve Çalışma Ağacı Hijyeni:**
   - `git diff --check`: exit 0 (sıfır whitespace / conflict hatası).
   - 204 değiştirilen ve 66 takip edilmeyen dosya incelendi; silinen `TODO_code-reviewer.md` dosyasının `2026-09-17-code-review.md` içine entegre edildiği teyit edildi.
   - Hiçbir derleme kalıntısı, geçici binary veya sır/credential sızıntısı bulunmadığı doğrulandı.

5. **Phase 0 / Baseline Geçişi:**
   - AS-V2-BASE-01 .. 05 açıkları kapatıldı.
   - V2 Çoklu-Ajan Kodlama Platformu (Multi-Agent Coding Platform V2 - Faz 1 / Görev 2) geliştirmelerine başlamak için zemin tamamen hazırdır.

## Devam — onaylanan orta-koşu kayıt hatası onarımı, 05:40 TRT

Kullanıcı sınırlı fail-closed tasarımını açıkça onayladı. `GoalOrchestratorTests/testFailedMidRunSaveStopsAutomaticContinuationAndPreservesLastSnapshot` önce RED exit 1 / 3 assertion; `.build` turu gönderildi, durum `.verifying` kaldı ve polling devam etti. `persist` hata yolunda bellekte `.failed`, bekleyen iş ve tur bağını temizleme, generation artırma, polling durdurma ve diskte son sağlam kayıt üzerine yazmadan dönme uygulandı; aynı test GREEN exit 0. Panelin `dismiss` yolu sağlam kurtarma kaydını silebiliyordu: ikinci `testDismissAfterSaveFailurePreservesRecoverableSnapshot` önce RED exit 1 / eksik dosya, onarımdan sonra GREEN exit 0. Zaten gönderilmiş harici ajan turunun iptal edildiği iddia edilmez.

Son üretim kodu üzerinde normal `swift build --product AgenticSidebar` exit 0 ve `git diff --check` exit 0. On kaynak test sınıfının toplu yeniden koşusu güvenlik kontrolünce engellendi; alternatif test komutlarıyla dolanılmadı. Bu tur yalnız iki yeni odaklı testin ayrı ayrı GREEN çıktıkları kanıtlandı; tam paket ve toplu regresyon yeşil ilan edilmez. Önceki WAE 502, pinned strict lint ve yaklaşık 270 dirty dosyanın owner/secret/deletion denetimi açık. Index/commit/push/V2 değişmedi.

## Ek kaynak denetimi — 05:31 TRT

`GoalOrchestrator.swift` yeniden okundu: ilk `start` kaydını denetlese de `submitTurn`, `handleTurnFinished`, `finishVerification`, `resumeStoredRun`, `resume` ve `confirmReview` sonrasındaki `persist` hatası yalnız mesaj modelliyor; bir sonraki otomatik tur devam edebilir. Test-önce onarım için sınırlı tasarım onayı bekliyor: çalışan Goal'da kaydetme hatası olursa bellekte terminal duruma geç, bekleyen işi ve anketi kapat, yeni otomatik tur gönderme, zaten gönderilmiş turu iptal edildi diye tanımlama ve son sağlam disk kaydını koru. Henüz bu yeni hata yolu için kod veya test yazılmadı.

CI `brew install swift-format`, tam `swift-format --version == 604.0.0` ve `swift-format lint -r --strict Sources Tests` istiyor. Homebrew formula sayfası 2026-09-19 itibarıyla stable 604.0.0 bildiriyor (https://formulae.brew.sh/formula/swift-format). Önceki 'brew latest pin uyumsuz' kaygısı kanıtlanmış bir CI hatası değildir; yerel `swift format --version` 6.3.0 ise aynı pinned lint kanıtı değildir. `git_log` yerel HEAD'in uzak SHA'dan altı commit ileride olduğunu teyit etti, ancak 270 civarı kirli dosyanın sahipliği ve silinen TODO'nun niyeti kanıtlanmadı. `.gitignore` build artefakt yollarını dışlıyor, bu tam sır/binary denetimi değildir. Yeni commit/push/V2 veya repo dışı uygulama eylemi yok.

## Devam — kalıcılık güvenli başlatma ve güncel seçili testler, 05:24 TRT

`GoalOrchestrator.persist` kaydetme hatasını `try?` ile sessizce yutuyor, `start` buna rağmen ilk ajan turunu gönderiyordu. Yazılamayan yol fikstürüyle `testStartRefusesToSubmitWhenGoalCannotBePersisted` RED exit 1 / 4 assertion failure gösterdi; ilk kaydı doğrulayıp başarısızlıkta motoru ve oturum bağını temizleyerek prompt göndermeyen küçük değişiklikten sonra GREEN exit 0 / 1 test. Hata mesajı kullanıcıya gösteriliyor. Aktif bir turun daha sonra kayıt başarısızlığıyla durdurulması ayrıca tasarlanmalı; bu test yalnız ilk başlatma yolunu kanıtlar.

En son değişiklikle aynı ağaçta 10 ilgili XCTest sınıfı 105 test / 0 failure / exit 0 (05:23:46), `swift build --product AgenticSidebar` exit 0, `git diff --check` exit 0. Önceki FD-mirasçısı testi bu birleşik koşuda da geçti; geçmişte zamanlama kaynaklı iki başarısızlık nedeniyle kesin süre garantisi iddia edilmez. Yerel `swift format --version` 6.3.0, CI pin'i `swift-format 604.0.0`; pinned strict lint yapılmış sayılmaz. Bir erken yayın girişimi `WORKTREE_NOT_CLEAN` nedeniyle fail-closed reddedildi; commit veya uzak değişiklik yok. Tam suite önceki güvenlik engeli, warnings-as-errors 502, tüm kirli dosyaların sahiplik/sır/artefakt/silme denetimi ve canlı backend bütünleşmesi hâlâ açık. Dolayısıyla push/V2 kapısı kapalıdır.

## Devam — alt süreç açık FD regresyonu, 05:15 TRT

`GoalRunnersTests/testExitedParentDoesNotWaitForBackgroundChildHoldingOutputPipe` fixture'ı başlangıçta iki koşuda 4,198 ve 4,223 saniyelik gecikmeyle RED (exit 1) oldu. `/bin/sh` doğrudan `Process.waitUntilExit()` hem null sink hem Pipe ile yaklaşık 0,24/0,23 saniyede tamamlandı; gecikme yalnız shell parent'ına bağlanamaz. Geçici diagnostik eklenip kaldırıldı; diagnostikli test 0,180 saniyede, çıkarıldıktan sonra tek test 0,195 saniyede ve bütün `GoalRunnersTests` (12 test) 0 hata / exit 0 ile geçti. İlk iki RED nedeniyle zamanlama kararsızlığı ve genel kesin timeout garantisi hâlâ izlenmeli. Son normal ürün derlemesi ve `git diff --check` exit 0. Önceden engellenen full suite ve iki defa 502 dönen warnings-as-errors yeniden denenmedi; pinned lint ve tüm kirli ağaç güvenlik/sahiplik denetimi bekliyor. Git index, commit, push ve V2 değişmedi.

## Devam — uygulamayı atlayan edit izinleri, 04:46 TRT

Ek güvenlik açığına RED regresyon eklendi: backend `edit/write/patch/multiedit: allow` yapılandırması `permission.asked` üretmediğinden uygulamadaki symlink/kapsam kararı çağrılmıyordu; ayrıca `ask` seviyesi güvenle klasör içi edite cevap veremiyor, `approveSafe` boş/yolu belirsiz isteği onaylıyordu. `ToolApprovalRoutingRegressionTests` önce 2 test / 12 assertion failure / exit 1. Dört mutasyon kuralı `ask` olarak uygulamaya yönlendirildi; `ask` yalnız yol belirtilmiş ve klasör içi olduğu doğrulanmış düzenlemeyi `.once` onaylıyor; `approveSafe` belirsiz yolu artık onaylamıyor. Eski testlerin beklediği in-folder akış korunacak şekilde beklentiler güncellendi. Yalnız ilgili onay testleri 48/0, ardından Goal, clipboard, izin, ayarlar dahil 10 ilgili sınıf birlikte 103 test/0 hata/exit 0; son değişiklik sonrası normal ürün derlemesi exit 0. Bu yapılandırma düzeyinde onarımdır: OpenCode'un canlı event üretimi veya kullanıcının haricî konfigürasyonuyla birleşimi uçtan uca doğrulanmadı. Güncel tam paket testinin önceki güvenlik engeli ve CI warnings-as-errors 502'si çözülmedi; pinned lint, tüm kirli dosyaların sahiplik ve sır taraması ve silme gerekçesi eksik. Stage/commit/push/V2 yapılmadı.

## Devam — yalnız kanonik Desktop deposu, 04:37 TRT

Kullanıcı çalışma hedefini yineledi: yalnız `/Users/dogan/Desktop/AgenticSidebar`; Freebuff ve macOS izin penceresiyle etkileşim yok. `GoalRunners` timeout çıktısının argümanları (olası sırları) aynen yazdığı ayrıca RED regresyonuyla kanıtlandı: `testTimeoutDiagnosticDoesNotExposeCommandArguments` önce exit 1 / 1 assertion failure, çıktıdan argümanları kaldıran minimal onarımdan sonra exit 0. Ardından `GoalRunnersTests` sınıfı 11 test, 0 hata, exit 0. Bu güvenlik onarımı sonrasında **69-testlik önceki birleşik koşu artık güncel dosya parmak izine ait değildir**; yeniden yalnız `GoalRunnersTests` çalıştı. `swift build -Xswiftc -warnings-as-errors` bağlantısı 502 döndürdü, build sonucu yok. Güncel tam paket testi, pinned strict lint, yaklaşık 270 dosyalık sır/artefakt/sahiplik ve silme denetimi tamamlanmadı. Git index, commit, push ve V2 değişmedi. Kalan kritik backend `edit/write/patch` ön-izin ve child FD timeout sorunu çözülmeden genel güvenlik garantisi verilmez.

## Güncel onarım ve kanıt ek kaydı — 2026-09-19 04:10 TRT

**Son durum (04:17 TRT):** Ek bozuk symlink (var olmayan dış hedef) RED→GREEN testi de tamamlandı; yedi odaklı test sınıfı birlikte yeniden çalıştırıldı: 69 test, 0 hata, exit 0. Son dosya değişikliğinden sonra normal ürün derlemesi exit 0 ve `git diff --check` exit 0. Aşağıdaki önceki 68-test sayısı ilk birleşik koşunun kaydıdır; tam Swift paketi testi değildir.

Önceki «henüz düzeltilmedi» ifadeleri ilk geçişe aittir. Kanonik Desktop AgenticSidebar deposunda RED→GREEN doğrulanan kaynak yolları: AS-V2-BASE-01 `GoalRunners.swift` çocuk çalışırken eşzamanlı sınırlandırılmış pipe boşaltımı (128 KB çıktı testi); AS-V2-BASE-02 `ClipboardMonitorService.swift` yakalanan oturuma kimlik bağıyla gönderim (A→B regresyonu); AS-V2-BASE-03 `GoalStore.swift` bozuk/future dosyayı üzerine yazmadan UUID karantinasına taşıma ve `GoalOrchestrator.swift` resume esnasında bozulan veriyi silmeme; AS-V2-BASE-04 `SettingsAITab.swift` ve `ToolApprovalPolicy.swift` izin değişikliği zamanlamasını "sonraki tur" olarak doğru belirtme; AS-V2-BASE-05 `ToolApprovalPolicy.swift` henüz var olmayan dosyada en yakın mevcut symlink ebeveynini çözerek kapsam denetleme. Bunlar genel uygulama güvenliği veya canlı OpenCode backend erişim garantisi değildir.

Her yeni regresyon öncesi ilgili davranış kırmızı, minimal onarım sonrası yeşildi. İlgili yedi XCTest sınıfı birlikte `swift test --filter 'GoalStoreTests|GoalOrchestratorTests|ToolApprovalPolicyTests|ToolApprovalSymlinkRegressionTests|ClipboardMonitorServiceTests|GoalRunnersTests|SettingsOrganizationTests'`: çıkış 0, 68 test, 0 hata; normal `swift build --product AgenticSidebar`: çıkış 0; `git diff --check`: çıkış 0. Aynı tur warnings-as-errors build denemesi bağlantı 502 döndürdü, derleme çıkış kodu bilinmiyor. Güvenlikçe engellenmiş tam suite alternatif komut/araçla çalıştırılmadı ve güncel tam-suite, pinned lint, sır/PII/artefakt/silme/sahiplik denetimi tamamlanmadı. Index boş, commit/push/V2 yapılmadı.

Kalan teknik riskler: `GoalRunners` pipe FD mirasçısı ve `work.value` timeout dönüş garantisi ayrıca sınanmadı, timeout hata metninde uzun argümanların sansürlenmemiş aktarımı görüldü; OpenCode yapılandırmasındaki yerleşik `edit/write/patch: allow` kararları uygulamanın otomatik izin filtresinden geçmeden uygulanabilir, canlı backend güvenlik garantisi ölçülmedi. `GoalOrchestrator.persist` kaydetme hatasını `try?` ile yutuyor. Bu sorunlar ve bütün dirty dosya sahipliği çözülmeden yayımlama kapısı kapanmış durumda.

## Devam kaydı: yayın ve uygulama engeli (2026-09-19)

Kullanıcı beş sorunun giderilmesini, bütün kirli deponun GitHub'a gönderilmesini ve V2 başlangıcını istedi. Yeni `project_resume` aynı kanonik dal/HEAD (`plan/review-fixes-2026-09-17`, `cc4f07d`), boş indeks, uzak dala göre altı yerel commit ve değişmemiş kirli envanteri doğruladı. Bu tur `git diff --check` çıkış kodu 0; tam test/build/lint veya sır taraması değildir. V2 spec/plan Phase 0 temiz, sahibi belirli ve doğrulanmış baseline gerektiriyor.

`GoalRunners`da süreç çıkışı pipe boşaltımından önce bekleniyor; timeout sonunda sınırsız `work.value` var. `ClipboardMonitorService` bekleyen metne oturum kimliği eklemiyor; mevcut `AgentSessionService.session(for:)` hedef oturuma doğrudan erişim sunuyor, dolayısıyla aktif oturumu değiştirmeden hedefe gönderme tasarlanabilir. `GoalStore.load` bozuk dosya için `nil` dönüyor ve `GoalOrchestrator.start` sonraki kayıtta onu üzerine yazabilir. Her üçüne RED regresyon ve sırasıyla eşzamanlı sınırlı çıktı tüketimi, oturuma sabit gönderim, kurtarma karantinası gerekir; henüz uygulanmadı.

`ToolApprovalPolicy`de var olmayan symlink-alt hedef `fileExists` kapısından geçebilir; ancak backend konfigürasyonu yerleşik `edit`/`write`/`patch` için `allow` yazıyor. Bu yüzden yalnız `automaticReply` düzeltmesiyle bütün düzenleme yollarının korunduğu iddia edilemez; önce hangi isteğin uygulamaya gerçekten ulaştığı ölçülmeli. İzin açıklamasının 'sonraki araç çağrısı' / 'sonraki tur' çelişkisi de güncel kaynakta sürüyor.

Bilgisayar sağlık kontrolünde erişilebilirlik, ekran kaydı ve olay izinleri olumlu; Freebuff önünde AgenticSidebar'ın 'diğer uygulamalardaki verilere erişmek istiyor' macOS TCC izin penceresi hâlâ açık. Pencereye dokunulmadı ve eski engellenmiş test/inceleme başka kanaldan çalıştırılmadı. Bu tur kaynak/test kodu, Git indeksi, commit, uzak depo veya V2 değiştirilmedi. Kullanıcının sistem izin penceresine kendi seçimiyle yanıt vermesi, sahiplik/silme denetimi ve güncel RED→GREEN/yayın kapıları gereklidir.

---

Tarih: 2026-09-19. Kapsam: kanonik AgenticSidebar çalışma ağacı, `plan/review-fixes-2026-09-17`, HEAD `cc4f07daae83eb1bc1016bd2a41a923a97e32d29`. Bu belge **tamamlanmış bir tam-depo denetimi veya yayın onayı değildir**; güncel dosyalar üzerinde doğrudan okunarak doğrulanan ilk bulguları ve eksik kapıları kaydeder. Önceki `2026-09-17-code-review.md` tarihsel kayıttır. Buradaki statik bulgular çalıştırılmış regresyon testi olarak sunulmaz.

## Değişiklik ve yayın envanteri

- Yeni `project_resume` ile kanonik çalışma ağacı, dal ve HEAD yeniden doğrulandı. Dal `origin/plan/review-fixes-2026-09-17` karşısında 6 commit ileride; uzak dalın doğrulanmış SHA'sı `1bda7c753ca8c7c04e2666565265e0fbf9c591a9`.
- `git status`: 204 değiştirilmiş, 66 takip edilmeyen, 1 silinmiş dosya (`TODO_code-reviewer.md`), indeks boş. Sahiplik dağılımı ve silmenin gerekçesi henüz kanıtlanmadı; `git add -A` uygun değil.
- Bu inceleme sırasında `git diff --check` çıkış kodu 0. Bu kontrol test, derleme, sır taraması veya dosya sahipliği incelemesinin yerine geçmez.
- Freebuff'ta diğer ajanın tamamlandığını bildiren rapor görüldü; rapordaki 11 düzeltme ve başarı iddiaları güncel kaynak parmak izi ile bağımsız olarak yeniden doğrulanmadı. macOS 'diğer uygulamalardaki verilere erişim' izni modalı önceki oturumda açık kaldı. Güvenlik izni zorlanmadı.
- Önceki tam Swift testi 1010 test / 2 skip / 0 failure / exit 0 döndürdü; test başladıktan sonra `SpeechDictationService.swift` ve testi değiştiği için **güncel çalışma ağacına ait eksiksiz kanıt değil**. Önceden güvenlikçe engellenen test/inceleme komutları alternatif araçla çalıştırılmadı. Son warnings-as-errors derleme denemesinde bağlantı 502 döndü; çıkış kodu bilinmiyor. Bu geçişte yeni build, full suite ve pinned lint çalıştırılmadı.

## Güncel kaynak üzerinden ilk bulgular

### AS-V2-BASE-01 — Goal doğrulama süreci pipe dolduğunda takılabilir (önemli)

**Kanıt:** `Sources/AgenticSidebar/AgentCore/GoalRunners.swift`, `runThroughProcess`: çocuk süreç `standardOutput` ve `standardError` için aynı `Pipe`'ı kullanıyor; iş görevi önce `process.waitUntilExit()` çağırıyor, ancak daha sonra `pipe.fileHandleForReading.readDataToEndOfFile()` ile okumaya başlıyor. Çocuk pipe kapasitesinden fazla çıktı üretirse yazma sırasında bloke olabilir; üst görev çocuğun çıkmasını beklediği için karşılıklı bekleme oluşur. Ayrıca `GoalProcessBox.set(nil)` okuma tamamlanmadan yapılıyor: `pollForExit` tamamlandı sanıp `work.value` üzerinde bekleyebilir. Timeout yolunun `work.value` beklemesi de, pipe'ı açık tutan alt süreç varsa garanti edilmiş süre sınırı sağlamaz.

**Test boşluğu:** `Tests/AgenticSidebarTests/GoalRunnersTests.swift` gerçek süreç testleri yalnız `echo`, `false`, `sleep` ve eksik yürütülebilir senaryolarını kapsıyor; pipe kapasitesini aşan üretici ve açık fd mirasçısı senaryoları yok. **Önerilen kırmızı test:** izinli geçici fixture ile stdout/stderr'den kapasiteyi aşan çıktı üreten çocuk süreç, makul kısa deadline içinde `timedOut` ya da gerçek çıkış koduyla dönmeli ve çıktı kuyruğu raporda bulunmalı. **Düzeltme yönü:** çıktı çocuk çalışırken eşzamanlı/kapasitesi sınırlı boşaltılsın, ardından çıkış beklensin; timeout'ta süreç ağacı/fd kapanışı ve kesin dönüş ayrı test edilsin. Henüz düzeltme/test uygulanmadı.

### AS-V2-BASE-02 — Otomatik pano kuyruğu yakalama oturumunu kaybetmektedir (oturum izolasyonu)

**Kanıt:** `Sources/AgenticSidebar/Services/ClipboardMonitorService.swift` içindeki `PendingClipboardSubmission` yalnız `text`, `mode`, `speedMode` içeriyor. `capture` aktif oturumun modunu anlık alıyor fakat `activeSessionID` saklamıyor. `flushPendingSubmissions` daha sonra `sessionService.canAcceptPrompt` ve `sessionService.send` kullanıyor; `Sources/AgenticSidebar/AgentCore/AgentSessionService.swift` bu iki işlemi *o anda* aktif olan oturuma yönlendiriyor. Yakalama ile gönderim arasında oturum değişirse bekleyen metin yeni oturuma gönderilebilir.

**Test boşluğu:** `ClipboardMonitorServiceTests` bekleme ve mod korumayı sınar, ancak beklemede oturum değiştirme veya yakalama oturumu silme durumunu sınamaz. **Önerilen kırmızı test:** A oturumunda yakala, gönderim engellenmişken B'ye geç, kuyruğu boşalt; içerik A'ya bağlı kalmalı veya açıkça düşürülmeli, B'ye gitmemeli. Oturum kimliği pending entry'ye bağlansın; hedef oturum varlığı ve kabulü kimlik üzerinden sınansın. Henüz düzeltme/test uygulanmadı.

### AS-V2-BASE-03 — Bozuk goal kaydı yeni hedef başlatılırken üzerine yazılabilir (kalıcılık)

**Kanıt:** `Sources/AgenticSidebar/Services/GoalStore.swift` `load` geçersiz JSON/sürüm için `nil` döndürür, fakat bozuk dosyayı ayırmaz. `Sources/AgenticSidebar/AgentCore/GoalOrchestrator.swift` `start` içinde `load == nil` durumunda yeni çalışmayı kabul edip `persist` → `GoalStore.save` ile aynı URL'ye atomik yazabilir. `resumeStoredRun` geçersiz kayıt için `GoalStore.clear` çağırabilir. Önceki arşiv/registry kurtarma ilkelerinin aksine bozulmuş hedefin tek kopyası korunmayabilir.

**Test boşluğu:** `GoalStoreTests.testCorruptFileLoadsNil` yalnız `nil` sonucunu doğruluyor; dosyanın kurtarma amaçlı korunmasını sınamıyor. **Önerilen kırmızı test:** bozuk ama mevcut kaydı yükleyip yeni hedef başlatınca ilk baytlar `.corrupt` karantina dosyasında korunmalı veya yeni başlatma açık hata ile reddedilmeli. Hata yazımı `try?` ile sessizce yutulmamalı. Henüz düzeltme/test uygulanmadı.

### AS-V2-BASE-04 — İzin seviyesi açıklamaları uygulama davranışıyla çelişiyor (UI/doğruluk)

**Kanıt:** `Sources/AgenticSidebar/Views/Settings/SettingsAITab.swift`, `toolApprovalCardBody` alt açıklaması değişikliğin koşan ajanın sonraki araç çağrısında uygulanacağını belirtiyor. `Sources/AgenticSidebar/OpenCodeProvider/PermissionApprovalCenter.swift`, `beginTurn` politika anlık görüntüsünü tutuyor; `automaticReply` tur boyunca bu görüntüyü kullanıyor; `endTurn` sonunda çıkarıyor. `Sources/AgenticSidebar/ProviderGateway/ToolApprovalPolicy.swift` ayrıntı metinleri sonraki turu doğru söylüyor, fakat tip başı açıklaması da sonraki araç çağrısını iddia ediyor. Bu, izin düşürüldüğünde kullanıcıya verilmiş güvenlik beklentisini yanlış ifade eder.

**Önerilen düzeltme:** Gerçek karar tur-başında kalacaksa bütün kullanıcı metinleri ve kod belgeleri tutarlı biçimde 'sonraki tur' demeli; aksi davranış isteniyorsa tur politikası yeniden tasarlanmalı ve senaryo testi eklenmeli. Mevcut oturum sahipliği netleşmeden ortak dosyalara müdahale edilmedi.

### AS-V2-BASE-05 — Symlink altında var olmayan hedef kontrolü fail-open olabilir (ek güvenlik testi gerekli)

**Kanıt:** `ToolApprovalPolicy.reachesOutsideWorkingDirectory` göreli yolun çözülmüş sonucunun kapsamını yalnız `fileExists(targetURL)` veya `fileExists(resolvedTarget)` doğruysa denetliyor. Çalışma dizinindeki sembolik bağlantı dış dizine işaret ederken bağlantının altındaki **henüz var olmayan** dosya bu iki varlık kontrolünden geçmeyebilir; `edit`/`write` için `.approveSafe` kararı `.once` verebilir. `testInFolderSymlinkPointingOutsideAsks` yalnız var olan hedefe işaret eden dosya symlink'ini denetliyor. Doğrudan backend izinleri ve `external_directory` davranışı ayrıca ölçülmeden üretimde kesin izin atlatması ilan edilmez.

**Önerilen kırmızı test:** İzinli geçici dizinde `root/link -> outside/`, `outside/new.txt` henüz yokken `link/new.txt` düzenlemesi için otomatik cevap `nil` olmalı. Var olmayan son bileşene rağmen var olan ebeveyn symlink'lerini çözerek kanonik kök kapsamı sınansın; boş pattern fail-closed kararı ayrıca tasarlansın.

## Yayın kapısı ve sonraki çalışma

1. Ajanın son sahiplik raporunu tam erişilebilir biçimde karşılaştır; 204 M, 66 untracked ve `TODO_code-reviewer.md` silmesinin sahibi ve gerekçesi dosya bazında belirlenmeli.
2. Önce bu belgedeki statik bulgular için gerçek RED regresyonları ve küçük düzeltmeler; ortak sahipliğe dokunmadan önce sahipliği çöz. Hiçbiri henüz düzeltilmiş veya test edilmiş değildir.
3. Aynı güncel içerik parmak izinde **tam** `swift test`, normal `swift build`, `-warnings-as-errors` CI build ve test, `swift-format 604.0.0 --strict` lint, `git diff --check`, secret/kişisel veri/artefakt/binary/dosya silme taramasının çıkış kodları kaydedilmeli. Güvenlik tarafından engellenen işlem başka araçla dolanılmamalı; engel çözülmeden yayın yok.
4. Yalnız bu kapılar ve sahiplik geçerse açık dosya listesiyle stage, anlamlı commit, mevcut non-main dalda normal push ve uzak SHA karşılaştırması. Kirli mevcut ağaç veya eski test sonucu kullanılarak 6 yerel commit de gönderilmiş sayılmaz.
5. V2 planı `Phase 0 / Task 1` temiz ve yetkili baseline kapısı geçilmeden V2 üretim koduna başlanmaz.

Bu kayıt yalnız inceleme bulgularını ekler; kaynak kod, test kodu, Git indeksi veya uzak depo bu belgeyle değiştirilmedi.
