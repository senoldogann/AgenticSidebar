# Görev Panosu: Otonom Korumalı-Dal + Kapatılabilir Detay + Denetçi Kablosu (2026-09-21)

## Kapsam
- Korumalı-dal (`master`/`main`) sürtünmesi kökten kaldırıldı: kullanıcıdan manuel dal değiştirmesi istenmez.
- Detay bölmesi kapatılabilir (X düğmesi + seçim temizliği).
- Denetçi girdisi (kanıt/bulgu/parmak izi/çalışma alanı) panoya bağlandı; boş-durum CTA, şablonlu oluşturma formu, aktör rehberliği, proje kayıt cümlesi eklendi.

## Kök neden (korumalı-dal)
`GitWorkspaceManager.createOwnedWorkspace`, worktree'yi `git worktree add --detach <hedef> <sha>` ile kurar
(`GitWorkspaceManager.swift`): kaynak checkout'a asla geçilmez, yazılmaz, merge edilmez; push/merge insan
onaylarının arkasındadır. Buna rağmen `preflight` oluşturma yolunda `verifyBranchIsWritable` ile kaynak
dalın yazılabilir olmasını şart koşuyordu — aynı taban commit, detached HEAD'te kabul edilip `master`'da
reddediliyordu. Kapı güvenlik değil sürtünmeydi; kaldırıldı. `WORKTREE_DIRTY` bilerek korundu: kirli
kaynakta worktree HEAD'ten kurulur ve commitlenmemiş iş ajanın tabanına sessizce girmezdi; commit/stash
kararı insana aittir, otomasyona bırakılamaz.

## Değişen dosyalar
- `Sources/AgenticSidebar/Workspace/GitWorkspaceManager.swift` — oluşturma yolunda dal denetimi kalktı,
  gerekçe yorumda; `verifyBranchIsWritable` silindi. `WorkspaceGuardError.protectedBranch` kodu ve
  `GoalSafety.mayWriteToBranch` API kararlılığı için duruyor.
- `Sources/AgenticSidebar/TaskBoard/CodingTaskService.swift` — `TaskInspectorInputs` + best-effort
  `inspectorInputs(taskID:)` (throw etmez; okuma yüzeyi bölmeyi başarısız yapmaz).
- `Sources/AgenticSidebar/TaskBoard/TaskBoardStore.swift` — seçim başına denetçi durumu
  (`selectedInspectorTaskID/Evidence/Fingerprint/Findings/WorkspaceID`), seçimde sıfırlama.
- `Sources/AgenticSidebar/Views/TaskBoard/TaskBoardView.swift` — `resolvedInspectorInput`, boş-durum CTA
  (`emptyCallToAction`), `TaskCreationForm` (doğrulama/öncelik/şablonlar), segmentli öncelik, detay kapatma (X).
- `Sources/AgenticSidebar/Views/TaskBoard/TaskDetailView.swift` — kanıt/bulgu boş metinleri ("henüz yok"
  dili), aktör rehber cümlesi.
- `Sources/AgenticSidebar/Views/RootChatView.swift` — proje kayıt rehber cümlesi.
- Testler: `GitWorkspaceManagerTests` (2 yeni/yerine), `TaskBoardStoreTests` (3 yeni),
  `TaskBoardCreationFormTests` (yeni dosya, 6 test).

## Doğrulama
- `swift build --product AgenticSidebar -Xswiftc -warnings-as-errors` → exit 0
- Hedefli filtreler (korumalı-dal x2, seçim-temizleme, oluşturma formu, denetçi yükleme) → 0 failure
- `swift-format lint -r --strict Sources Tests` (604.0.0) → exit 0; `git diff --check` → temiz
- `swift test -Xswiftc -warnings-as-errors` (tam süit) → aşağıda

## Açık kalan (bu ortamda kanıtlanamaz)
- V2 Task 14 Step 5: disposable depoda gerçek OpenCode E2E (faturalı model çağrısı gerekir).
- V2 Task 14 Step 6: imzalı app + GUI ile native regresyon (bu oturum headless).
- Canlı Keychain E2E: TCC promptu headless'ta bloklanır; imzalı app ile koşulmalı.
