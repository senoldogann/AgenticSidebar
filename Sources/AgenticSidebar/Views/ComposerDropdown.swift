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

    let isEnabled: Bool
    let helpText: String
    let accessibilityText: String
    let label: Label
    let content: Content

    init(
        isEnabled: Bool,
        helpText: String,
        accessibilityText: String,
        @ViewBuilder label: () -> Label,
        @ViewBuilder content: () -> Content
    ) {
        self.isEnabled = isEnabled
        self.helpText = helpText
        self.accessibilityText = accessibilityText
        self.label = label()
        self.content = content()
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            label
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            // Uzun listeler (özellikle model listesi) ekrandan taşıyordu ve
            // popover kırpıldığı için tekerlekle kaydırılamıyordu. İçerik bir
            // ScrollView içinde ve yüksekliği sınırlı: menü kısa olduğunda
            // görünüm değişmez, uzun olduğunda yukarı-aşağı kaydırılır.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    content
                }
                .padding(6)
                .frame(minWidth: 216, alignment: .leading)
            }
            .frame(maxHeight: 380)
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
            dismissPopover()
            action()
        } label: {
            HStack(spacing: 8) {
                icon
                    .frame(width: 14, alignment: .center)

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 14)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .interactiveHoverPill(cornerRadius: 6)
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
