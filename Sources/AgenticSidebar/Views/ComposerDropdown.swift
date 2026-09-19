import SwiftUI

/// Composer pill'indeki açılır menü.
///
/// SwiftUI `Menu` bir NSMenu açar: satırları sistem çizer, uygulamanın hover
/// dili satırlara uygulanamaz ve satır ikonu sistem sembolü olmak zorundadır —
/// çizilen plan işareti menüde düştüğü için Plan satırı pill'deki kontrolden
/// farklı görünüyordu. Bu kontrol bunun yerine bir `popover` açar ve satırlarını
/// kendisi çizer: her satır diğer kontrollerle aynı hover zeminini ve el
/// imlecini taşır, ikon olarak da kendisine ne verilirse onu gösterir.
struct ComposerDropdown<Label: View, Content: View>: View {
    @State private var isPresented: Bool = false
    @FocusState private var isSearchFocused: Bool

    let isEnabled: Bool
    let helpText: String
    let accessibilityText: String
    /// `nil` iken arama alanı çizilmez; doluyken menünün üstünde sabit durur.
    /// Süzme işi çağıranındır: sorgu aynı bağlamayla okunup satırlar elenir.
    let searchText: Binding<String>?
    let searchPlaceholder: String
    /// Satırlar `init` anında değil popover açıldığında kurulur.
    ///
    /// Önceki hâlde `content()` init içinde çağrılıp hazır görünüm
    /// saklanıyordu: besteci her yeniden çizildiğinde (tuş vuruşu, akan
    /// yanıt, kenar çubuğu animasyonunun her karesi) yüzlerce model satırı
    /// baştan kuruluyordu. Kapanış dersleri bestecinin gövdesinde saklanır,
    /// açılışta bir kez kurulur.
    private let label: () -> Label
    private let content: () -> Content

    init(
        isEnabled: Bool,
        helpText: String,
        accessibilityText: String,
        searchText: Binding<String>? = nil,
        searchPlaceholder: String = "Search",
        @ViewBuilder label: @escaping () -> Label,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isEnabled = isEnabled
        self.helpText = helpText
        self.accessibilityText = accessibilityText
        self.searchText = searchText
        self.searchPlaceholder = searchPlaceholder
        self.label = label
        self.content = content
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            // Uzun listeler (özellikle model listesi) ekrandan taşıyordu ve
            // popover kırpıldığı için tekerlekle kaydırılamıyordu. İçerik bir
            // ScrollView içinde ve yüksekliği sınırlı: menü kısa olduğunda
            // görünüm değişmez, uzun olduğunda yukarı-aşağı kaydırılır.
            // Arama alanı kaydırmaz, üstte sabit durur.
            VStack(alignment: .leading, spacing: 0) {
                if let searchText {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField(searchPlaceholder, text: searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .focused($isSearchFocused)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                }
                ScrollView(.vertical) {
                    // Tembel yığın: yüzlerce model satırı açılışta tek turda
                    // ölçülmüyor, yalnız görünenler kuruluyor.
                    LazyVStack(alignment: .leading, spacing: 2) {
                        content()
                    }
                    .padding(6)
                    .frame(minWidth: 216, alignment: .leading)
                }
                .frame(maxHeight: 380)
            }
        }
        .onChange(of: isPresented) { _, presented in
            if presented {
                // Menü açılınca yazmaya hazırdır; arama yoksa odak değişmez.
                isSearchFocused = searchText != nil
            } else {
                searchText?.wrappedValue = ""
            }
        }
        .accessibilityLabel(accessibilityText)
        .help(helpText)
    }
}

/// `ComposerDropdown` içindeki tek satır.
///
/// Seçim yapılınca paneli kapatır: popover içeriği `dismiss` ortamını paylaşır,
/// satırlar da bu yüzden kapanışı kendileri çağırabilir.
struct ComposerDropdownRow<Icon: View>: View {
    @Environment(\.dismiss) private var dismissPopover

    let title: String
    let isSelected: Bool
    let helpText: String?
    let action: () -> Void
    let icon: Icon

    init(
        title: String,
        isSelected: Bool,
        helpText: String?,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) {
        self.title = title
        self.isSelected = isSelected
        self.helpText = helpText
        self.action = action
        self.icon = icon()
    }

    var body: some View {
        Button {
            action()
            dismissPopover()
        } label: {
            HStack(spacing: 8) {
                icon
                    .frame(width: 16, alignment: .center)

                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 14)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .interactiveHoverPill(cornerRadius: 7)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(helpText ?? title)
    }
}

/// `ComposerDropdown` içindeki grup başlığı.
struct ComposerDropdownSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 1)
    }
}
