import AppKit
import SwiftUI

/// Fotoğraf ekleri için kare küçük resim + tıklayınca açılan önizleme.
///
/// Besteci ve transkript aynı parçayı kullanır: fotoğraflar yan yana kareler
/// olarak durur, tıklayınca büyük önizleme popup olarak açılır. Büyük
/// fotoğraf kartları sohbeti doldurduğu için bu görünüme geçildi.
struct ImageSquareThumbnail: View {
    let url: URL
    var size: CGFloat = 56
    /// Verilirse karenin sağ üstünde çarpı rozeti çıkar; verilmezse (transkript)
    /// kare yalnız önizleme açar.
    var onRemove: (() -> Void)? = nil
    let onTap: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onTap) {
                if let image = AttachmentPreviewCache.shared.imageThumbnail(for: url, maxPixelSize: 128) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                } else {
                    ZStack {
                        Color.primary.opacity(0.06)
                        Image(systemName: "photo")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Click to preview \(url.lastPathComponent)")

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Remove attachment")
                .accessibilityLabel("Remove attachment \(url.lastPathComponent)")
                .offset(x: 6, y: -6)
            }
        }
    }
}

/// `popover(item:)` ile kullanılan kimlikli önizleme hedefi.
struct PreviewableImageAttachment: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    /// Bestecide silme düğmesi gösterilir, transkriptte gösterilmez.
    var allowsRemove = false
}

/// Kareye tıklayınca açılan büyük önizleme popup içeriği.
struct ImagePreviewPopoverContent: View {
    let url: URL
    var onRemove: (() -> Void)? = nil
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Close preview")
            }

            if let image = AttachmentPreviewCache.shared.imageThumbnail(for: url, maxPixelSize: 1200) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 520, maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Text("Preview is not available for this file.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }

            if let onRemove {
                HStack {
                    Spacer(minLength: 0)

                    Button(action: onRemove) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 10, weight: .medium))
                            Text("Remove attachment")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
        }
        .padding(12)
        .frame(minWidth: 280)
    }
}
