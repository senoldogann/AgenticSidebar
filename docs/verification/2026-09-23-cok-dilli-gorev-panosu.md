# 2026-09-23 — Görev panosu her projede her dilde

## Kapsam
Kayıt kapısındaki `Package.swift` şartı kalktı: `.git` olan her klasör
kaydedilir. Tür algısı (`ProjectKindDetector`) işaret önceliğiyle çalışır:
çalıştırılabilir ürünlü `Package.swift` → SwiftPM, `package.json` → Node,
`pyproject.toml`/`setup.py`/`setup.cfg`/`requirements.txt` → Python,
`go.mod` → Go, `Cargo.toml` → Rust, işaretsiz Git deposu → `generic`.
`generic` tarifesi (`generic:git`) yalnız `snapshot` adımıyla parmak izini
mühürler; kabul insan ölçütlerine kalır. Tüm tarifeler argv-only, mutlak
yollu, kabuksuzdur; depo betiği asla çalıştırılmaz.

## Kalıcılık
`CodingProject.kind` (`SQLite` v7 `kind` kolonu, eski satırlar `generic`
okunur), `evidence(taskID:)` okuması, süreç-içi defter boşaldığında
mağazadan onarım (`TaskEvidenceLedger` + `preflight` yedeği). Kabul kapısı
`AcceptanceGate.requiredSteps(for:)` ile dile göre değerlendirilir
(SwiftPM/Node/Python/Go/Rust: `build`+`test`, `generic`: boş + fail-closed).

## Test onarımları (kök neden)
- `testSwitchingSelection…`: kapı tüm `task` okumalarını tutuyordu, seçim
  değişiminin denetçi okuması da kapıya takılıp kilitleniyordu. Kapı artık
  görev kimliğine göre seçici (`gateTaskReads(_:for:)`); temiz ağaçta da
  asılı olduğu doğrulandı.
- `seedReviewTask`: tohuma `workspaceID` eklendi (gerçek koşuda zamanlayıcı
  bağlar); `testInspectorWarnsWhenRanTaskEvidenceCannotLoad` ancak böyle
  anlamlı.
- `testUnavailableRuntime…Disables…`: geçici `unavailable` retleri karta
  sabitlenmez (karar ağaçtaki `perform` davranışı), test yeniden-dene
  açıklığıyla uyumlu hale getirildi.

## Doğrulama
- `swift build --product AgenticSidebar -Xswiftc -warnings-as-errors` → exit 0
- Pano + doğrulama süitleri (174 test) → 0 failure
- Tam süit: 1687 test, 4 skipped (faturalı canlı E2E), 3 failure — üçü de
  `ExtensionStoreTests` (MCP kayıt alanı, pano dışı iş; bu işin kapsamı dışı).
- `swift-format lint --strict` (pano/doğrulama/test dosyaları) → temiz;
  `git diff --check` → temiz.
