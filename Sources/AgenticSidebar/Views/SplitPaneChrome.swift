import SwiftUI
import UniformTypeIdentifiers

/// Yan yana görünümde ikincil bölmenin ince başlığı.
///
/// Birincil bölme pencere başlığını kullanmaya devam eder; ikincil bölmenin
/// başlığı yoktur, o yüzden başlık, meşgul göstergesi ve bölme eylemleri
/// (odakla/değiştir/kapat) burada durur.
struct SplitPaneHeader: View {
    let title: String
    /// Bağlı klasörün tam yolu; başlık ipucu ve erişilebilirlik için kullanılır.
    var directoryPath: String? = nil
    let isBusy: Bool
    /// Birincil bölme zaten ana sohbettir: odakla/kapat düğmesi yoktur.
    var onFocus: (() -> Void)? = nil
    let onSwap: () -> Void
    /// Dörtlü ızgarada takas düğmesi çizilmez: iki bölmeli takasın karşılığı
    /// yoktur, bölmeler sürükle-bırakla düzenlenir.
    let showsSwap: Bool
    /// Birincil bölmede kapat yoktur (yan yana görünümü ikincil kapatır).
    var onClose: (() -> Void)? = nil
    /// İkincil bölmenin terminal düğmesi; pencere araç çubuğundaki düğme
    /// yalnız birincil bölmenindir, yoksa iki simge yan yana dizilir.
    var onOpenTerminal: (() -> Void)? = nil
    /// İkincil bölmenin diğer inspector sekmeleri: araç çubuğu yalnız birincil
    /// bölmeye düğme koyduğu için bu üçü bölme başlığından açılır.
    var onOpenComputerLive: (() -> Void)? = nil
    var onOpenSimulator: (() -> Void)? = nil
    var onOpenBrowser: (() -> Void)? = nil
    /// Bölmenin oturumundaki dosya değişikliklerini sağ panelde açar. Yalnız
    /// değişiklik varken bağlıdır; düğme ve menü öğesi o zaman çizilir.
    var onOpenSessionChanges: (() -> Void)? = nil
    /// Oturumda review edilecek dosya değişikliği var mı (nokta/düğme kapısı).
    var hasFileChanges: Bool = false

    @Environment(\.paneWidth) private var paneWidth

    /// Dar bölmede tek tek düğmeler sığmaz; eylemler taşma menüsüne toplanır.
    private var isCompactHeader: Bool {
        PaneResponsive.isCompact(width: paneWidth)
    }

    var body: some View {
        HStack(spacing: isCompactHeader ? 4 : 8) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(minWidth: 12, minHeight: 12)
                    .help("This session is running")
            } else {
                Circle()
                    .fill(Color.green.opacity(0.8))
                    .frame(width: 7, height: 7)
                    .help("This session is idle")
            }

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(directoryPath ?? title)

            Spacer(minLength: 0)

            if isCompactHeader {
                compactActions
            } else {
                if let onOpenTerminal {
                    Button(action: onOpenTerminal) {
                        Image(systemName: "terminal")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .interactiveHoverCircle()
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Open a terminal in this conversation's side panel")
                }

                if let onOpenSessionChanges, hasFileChanges {
                    Button(action: onOpenSessionChanges) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .interactiveHoverCircle()
                            .overlay(alignment: .topTrailing) {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 6, height: 6)
                                    .offset(x: -3, y: 3)
                            }
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Review this conversation's file changes in the side panel")
                    .accessibilityLabel("Review file changes")
                }

                if hasPanelActions {
                    Menu {
                        panelActionItems
                    } label: {
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .interactiveHoverCircle()
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .pointingHandCursor()
                    .help("Open a panel in this conversation's side panel")
                    .accessibilityLabel("Open panel")
                }

                if showsSwap {
                    Button(action: onSwap) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .interactiveHoverCircle()
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Swap the two conversations")
                }

                if let onFocus {
                    Button(action: onFocus) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .interactiveHoverCircle()
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Make this the main conversation")
                }

                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .interactiveHoverCircle()
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Close the side-by-side view")
                }
            }
        }
        .padding(.horizontal, isCompactHeader ? 8 : 10)
        .frame(height: isCompactHeader ? 28 : 30)
        .background(Color.primary.opacity(0.04))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Side-by-side conversation: \(title)")
    }

    /// Panel eylemlerinden en az biri bağlı mı? Menü düğmesi yoksa çizilmez.
    private var hasPanelActions: Bool {
        onOpenComputerLive != nil || onOpenSimulator != nil || onOpenBrowser != nil
            || (onOpenSessionChanges != nil && hasFileChanges)
    }

    /// Bölme başlığındaki panel eylemleri: hem geniş başlığın menüsünde hem
    /// dar başlığın taşma menüsünde aynı öğeler durur.
    @ViewBuilder
    private var panelActionItems: some View {
        if let onOpenSessionChanges, hasFileChanges {
            Button(action: onOpenSessionChanges) {
                Label("Review file changes", systemImage: "doc.badge.plus")
            }
        }
        if let onOpenComputerLive {
            Button(action: onOpenComputerLive) {
                Label("Watch computer use live", systemImage: "computermouse")
            }
        }
        if let onOpenSimulator {
            Button(action: onOpenSimulator) {
                Label("Open iOS Simulator", systemImage: "iphone")
            }
        }
        if let onOpenBrowser {
            Button(action: onOpenBrowser) {
                Label("Open browser", systemImage: "globe")
            }
        }
    }

    /// Dar başlıkta görünen tek satır: kapat düğmesi + taşma menüsü.
    private var compactActions: some View {
        HStack(spacing: 2) {
            Menu {
                if let onOpenTerminal {
                    Button(action: onOpenTerminal) {
                        Label("Open terminal in side panel", systemImage: "terminal")
                    }
                }
                panelActionItems
                if showsSwap {
                    Button(action: onSwap) {
                        Label("Swap the two conversations", systemImage: "arrow.left.arrow.right")
                    }
                }
                if let onFocus {
                    Button(action: onFocus) {
                        Label("Make this the main conversation", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
                if let onClose {
                    Button(action: onClose) {
                        Label("Close the side-by-side view", systemImage: "xmark")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .interactiveHoverCircle()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .pointingHandCursor()
            .help("Pane actions")
            .accessibilityLabel("Pane actions")

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .interactiveHoverCircle()
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Close the side-by-side view")
            }
        }
    }
}

/// Soldaki sohbet satırları `session.id.uuidString` taşır; bırakılan metin
/// buradan oturum kimliğine çözülür. Aynı sohbetin bırakılması üstte değil
/// çağıranda elenir (`SplitLayoutStore.openSecondary` yok sayar).
enum SplitDropSupport {
    static let dropTypes: [UTType] = [.text, .utf8PlainText]

    /// Bırakılan sağlayıcılardan geçerli oturum kimliklerini okur. Kenar
    /// çubuğu sürüklemesi tek öğelidir; her geçerli kimlik üst üste
    /// bildirilir, geçersiz metin sessizce atlanır.
    static func sessionID(
        from providers: [NSItemProvider],
        completion: @escaping @MainActor (UUID) -> Void
    ) -> Bool {
        let candidates = providers.filter {
            $0.canLoadObject(ofClass: NSString.self)
        }
        guard !candidates.isEmpty else {
            return false
        }
        for provider in candidates {
            _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                let raw = (text as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let id = UUID(uuidString: raw) else {
                    return
                }
                Task { @MainActor in
                    completion(id)
                }
            }
        }
        return true
    }
}
