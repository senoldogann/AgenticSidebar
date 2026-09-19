import SwiftUI

/// The messages waiting behind the running turn.
///
/// They live here, above the input, rather than in the transcript: a queued
/// prompt has not been answered yet, so it is not part of the conversation. The
/// order they appear in *is* the order the turns will run in, which is why the
/// rows can be dragged — while the agent is still busy with the current turn,
/// this strip is the only place that decision can be made. Editing happens in
/// the composer: the pencil hands the row's text back to the input, where the
/// full field (and its attachments) is available.
struct QueuedPromptsStrip: View {
    let prompts: [QueuedPrompt]
    /// Hands a row back to the composer for editing there.
    let onEditInComposer: (UUID) -> Void
    /// Moves a message to the position of the row it was dropped on.
    let onMove: (UUID, Int) -> Bool
    let onRemove: (UUID) -> Void
    let onClear: () -> Void
    /// Stops the running turn and sends this message right away.
    let onSendNow: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header

            ForEach(Array(prompts.enumerated()), id: \.element.id) { index, prompt in
                QueuedPromptRow(
                    index: index,
                    prompt: prompt,
                    onEditInComposer: { onEditInComposer(prompt.id) },
                    onRemove: { onRemove(prompt.id) },
                    onSendNow: { onSendNow(prompt.id) },
                    onMove: { draggedID in onMove(draggedID, index) }
                )
            }
        }
        .padding(.horizontal, 4)
    }

    @Environment(\.paneWidth) private var paneWidth

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("Queued (\(prompts.count))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if !PaneResponsive.isCompact(width: paneWidth) {
                Text("sent in order when this turn finishes")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Button("Clear") {
                onClear()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .interactiveHoverPill(cornerRadius: 5)
            .help("Discard every queued message")
        }
    }
}

private struct QueuedPromptRow: View {
    let index: Int
    let prompt: QueuedPrompt
    let onEditInComposer: () -> Void
    let onRemove: () -> Void
    let onSendNow: () -> Void
    let onMove: (UUID) -> Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            grip

            Text("\(index + 1)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing)

            summary
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Color.primary.opacity(isHovering ? 0.09 : 0.05),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
        .dropDestination(for: String.self) { items, _ in
            guard
                let raw = items.first,
                let draggedID = UUID(uuidString: raw)
            else {
                return false
            }

            return onMove(draggedID)
        }
    }

    /// The grab handle, and the only part of the row that starts a drag: making
    /// the whole row draggable would fight the text selection inside it.
    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(isHovering ? .secondary : .tertiary)
            .frame(width: 12, height: 14)
            .contentShape(Rectangle())
            .draggable(prompt.id.uuidString) {
                Text(prompt.text)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
            }
            .pointingHandCursor()
            .help("Drag to change the order these messages are sent in")
            .accessibilityLabel("Reorder queued message \(index + 1)")
    }

    private var summary: some View {
        HStack(spacing: 6) {
            // Satırın esnek elemanı yalnız metindir: kalan genişliği o alır,
            // sığmayanı kuyruktan kırpar. `Spacer` ile rekabet ederse ideali
            // tam metin olan `Text` sabit düğmeleri panel dışına iterdi.
            Text(prompt.text)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(prompt.text)

            if !prompt.attachmentPaths.isEmpty {
                Image(systemName: "paperclip")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            // Kuyruktaki her mesaj gönderildiği andaki modla çalışır (review
            // seçiliyken giren review, build seçiliyken giren build olur):
            // satırdaki rozet o seçimin kaybolmadığının görünür kanıtıdır.
            HStack(spacing: 3) {
                AgentModeGlyph(mode: prompt.mode, size: 9)
                Text(prompt.mode.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .help("Sent with \(prompt.mode.displayName) mode — runs as a \(prompt.mode.displayName.lowercased()) turn")
            .accessibilityLabel("Queued in \(prompt.mode.displayName) mode")

            Button(action: onEditInComposer) {
                Image(systemName: "pencil")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(3)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .interactiveHoverCircle()
            .help("Move this message back to the composer to edit it there")

            Button(action: onSendNow) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(3)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .interactiveHoverCircle()
            .help("Stop the running turn and send this message right away")

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(3)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .interactiveHoverCircle()
            .help("Remove this message from the queue")
        }
    }
}
