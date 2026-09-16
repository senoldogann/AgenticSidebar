# Computer Use entegrasyonu (2026-09-16)

AgenticSidebar, bilgisayar kontrolünü **chatgpt-system** projesine hiç dokunmadan,
onun MCP sunucusunu yönetilen OpenCode sunucusuna bağlayarak kullanır. Bu belge
uygulanan sözleşmeyi ve gerçek host doğrulamasını kaydeder.

## Mimari

```
AgenticSidebar (Swift)
  └─ ManagedOpenCodeServerManager
       ├─ OPENCODE_CONFIG = ~/Library/Application Support/AgenticSidebar/OpenCode/computer-use.json
       └─ opencode serve --pure            (mevcut davranış)
            └─ POST /mcp { name: "chatgpt-system", config: { type: "local", command: [...] } }
                 └─ node <repo>/dist/cli.js stdio
                      --root <AgenticSidebar Application Support>/OpenCode
                      --personal-admin --enable-computer-use
```

- chatgpt-system deposuna **yazılmaz**; yalnızca `dist/cli.js` okunur ve süreç
  OpenCode tarafından başlatılır.
- Kullanıcının `opencode.json` dosyası **değiştirilmez**. İzin kuralları ve model
  talimatları uygulamanın sahip olduğu `computer-use.json` +
  `computer-use-instructions.md` dosyalarında tutulur ve OpenCode'a
  `OPENCODE_CONFIG` ortam değişkeniyle verilir (OpenCode yapılandırmaları birleştirir).
- MCP kaydı çalışma anında `POST /mcp` ile yapılır; sunucu yeniden başlatıldığında
  kayıt otomatik yenilenir.

## İzin modeli (OpenCode 1.18.31)

OpenCode izin kurallarında **son eşleşen kural kazanır**; bu yüzden dosyadaki sıra
sözleşmenin parçasıdır:

| Sıra | Kural | Etki |
| --- | --- | --- |
| 1 | `chatgpt-system_*` → deny | fs/git/terminal/browser vb. araçlar modele hiç gösterilmez |
| 2 | `chatgpt-system_computer_*` → ask | her bilgisayar eylemi kullanıcı onayı bekler |
| 3 | `chatgpt-system_session_authority_*` → ask | Admin lease alma/yenileme de onay ister |
| 4 | `chatgpt-system_computer_health` → allow | salt-okunur hazırlık kontrolü sorulmaz |
| 5 | `chatgpt-system_computer_run_js` → deny | full-host JS kapalı (sunucu bayrağı da verilmez) |

- Sunucu `--personal-admin --enable-computer-use` ile başlar; **`--enable-full-host-js`
  ve `--enable-owner-runtime` verilmez**.
- Yetki, chatgpt-system'in Admin lease'i ile sınırlıdır (en fazla 1 saat, her
  `computer_*` çağrısında `authorityLeaseId` zorunlu, denetim kaydı
  `~/.chatgpt-system/audit.jsonl`).
- Onay bekleyen istekler ana pencerede satır içi onay çubuğunda gösterilir:
  **Deny / Allow once / Always allow** (OpenCode sözleşmesi: `reject`/`once`/`always`).
- Tur iptal edilirse bekleyen izinler reddedilir; uygulama kapanışında tümü temizlenir.

## Onay modları (Settings → Computer Use)

Kalıcı `computerUseApprovalMode` ayarı üç politika sunar; yalnız
`chatgpt-system_*` araçlarını kapsar, diğer MCP sunucuları ve yerleşik araçlar
normal izin akışından geçer:

| Mod | Davranış |
| --- | --- |
| `ask` (varsayılan) | Her eylem ve yetki isteği onay çubuğuna düşer. |
| `autoApproveActions` | `computer_*` eylemleri sormadan çalışır; Admin lease alma/yenileme yine kullanıcıya sorulur. |
| `fullAccess` | Hiçbir istek sorulmaz; ajan kullanıcı onayı olmadan bilgisayarı kullanır (kapatılana kadar). |

Otomatik yanıt kararı `ComputerUseApprovalMode.automaticReply(for:)` saf
fonksiyonundadır ve `PermissionApprovalCenter`'a enjekte edilen
`automaticReplyProvider` üzerinden uygulanır; otomatik yanıt kuyruğa hiç girmez.

## Uygulama tarafı değişiklikleri

| Alan | Değişiklik |
| --- | --- |
| `ComputerUse/ComputerUseConfiguration.swift` | Depo yolu/Node çözümlemesi, MCP komutu, `~` genişletme, hata mesajları |
| `ComputerUse/ComputerUseFiles.swift` | `computer-use.json` + talimat dosyası üreticisi (sıra kontrollü JSON) |
| `OpenCodeProvider/OpenCodeClient.swift` | `GET /mcp`, `POST /mcp`, `POST /mcp/{name}/disconnect` |
| `OpenCodeProvider/OpenCodePermissionRequest.swift` | `permission.asked` olayının yapısal modeli + başlık eşlemesi |
| `OpenCodeProvider/OpenCodeStreamNormalizer.swift` | İzin olayını tam yüküyle iletir |
| `OpenCodeProvider/PermissionApprovalCenter.swift` | Onay kuyruğu; `once/always/reject` çözümü, oturum bazlı temizlik |
| `OpenCodeProvider/OpenCodeProviderRuntime.swift` | Onay merkezi enjeksiyonu; iptalde bekleyen izinleri reddetme |
| `OpenCodeProvider/OpenCodeServerManager.swift` | `start(computerUse:)`: config yazımı + `OPENCODE_CONFIG` |
| `Stores/OpenCodeSettings.swift` | MCP kaydı, durum takibi, yeniden başlatma akışı |
| `Views/Settings/SettingsComputerUseTab.swift` | Etkinleştirme, yol, ön koşul/durum satırları, güvenlik notları |
| `Views/ConversationDetailView.swift` | Satır içi onay çubuğu |

Önceki davranış olan `permission.asked` → koşulsuz `"always"` yanıtı kaldırıldı:
artık onay merkezi yoksa (testler/başsız kullanım) eski davranış korunur, uygulamada
ise her istek kullanıcıya gösterilir.

## Doğrulama

Otomatik:

- `swift build --product AgenticSidebar` → hatasız/uyarısız.
- `swift test` → **248 test, 0 hata** (bilgisayar kullanımı öncesi 218).
- Yeni kapsam: `ComputerUseConfigurationTests` (6), `ComputerUseFilesTests` (5),
  `PermissionApprovalCenterTests` (6, otomatik yanıt kısa devresi dahil),
  `ComputerUseApprovalModeTests` (4), `OpenCodeClientTests` MCP sözleşmesi,
  `OpenCodeSettingsTests` kayıt akışı (3), `OpenCodeProviderRuntimeTests` onay/iptal
  akışı (3), `SettingsStoreTests` kalıcılık (1), normalizer izin olayı (2).

Gerçek host (OpenCode 1.18.31, macOS 26):

- Uygulama `computer-use.json` ve `computer-use-instructions.md` dosyalarını yazdı;
  kullanıcının `opencode.json` dosyası değişmedi.
- `OPENCODE_CONFIG` ile başlatılan sunucunun `GET /config` yanıtında beş kural
  **sırasıyla** ve `instructions` içinde üretilen dosya göründü (birleştirme kanıtı).
- `POST /mcp` yanıtı `chatgpt-system: connected` döndürdü; süreç ağacında
  `node .../dist/cli.js stdio --root .../AgenticSidebar/OpenCode --personal-admin
  --enable-computer-use` alt süreci doğrulandı.
- Uygulama günlüğü: `Registered the chatgpt-system MCP server for computer use`.

Elle yapılması gerekenler (model çağrısı gerektirdiği için bu turda çalıştırılmadı):

1. Bir oturumda "bilgisayarıma bak / computer use ile X yap" isteyin; onay
   çubuğunun çıkması, `Allow once` sonrası `computer_observe` çıktısının aracı
   etkinliğinde görünmesi.
2. `computer_health` sonucunun `state: "running"` ve TCC boolean'larının `true`
   olması (bu makinede helper zaten kurulu ve çalışıyor).
3. `Always allow` seçiminin aynı oturumda benzer çağrıları tekrar sormaması.

## Gözlemler

- Bu makinede eski oturumlardan kalan, ebeveyni ölmüş (`ppid 1`) yaklaşık 25
  `opencode serve` süreci var; bilgisayar kullanımıyla ilgisi yok, temizlenebilir.
- `computer_run_js` ve `chatgpt-system`'in dosya/git/terminal araçları bilinçli
  olarak erişilemez; istenirse sunucu bayrakları ve izin kuralları ayrı bir
  değişiklikle açılabilir.
