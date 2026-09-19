import AppKit
import SwiftUI

/// Sağ paneldeki terminal sekmesinin içeriği.
///
/// Kabuk `TerminalServiceCenter` tarafında yaşar; bu görünüm tek yüzeyli bir
/// uçbirimdir: nereye tıklanırsa tıklansın tuşlar doğrudan kabuğa gider
/// (`TerminalTTYView`), ayrı bir girdi satırı yoktur. Sekme değişiminde
/// görünüm gider ama kabuk çalışmaya devam eder, sekmeye dönülünce aynı
/// çıktı durur.
/// Terminal sekmesinin barındırıcısı: kabuğu gövde dışında çözer.
///
/// `terminalCenter.service(for:)` sözlüğe yazar; gövde içinde çağrılınca aynı
/// kimlikte iki ayrı kabuk doğuyordu (`onAppear` eski örnekte başlıyor,
/// yüzey yenisini gösteriyordu = boş ekran). Bu yüzden çözümleme `onAppear`
/// içindedir; o ana kadar bir bekleme göstergesi durur.
struct TerminalHostView: View {
    let center: TerminalServiceCenter
    let tabID: String
    let workingDirectoryPath: String
    let preset: AppThemePreset
    let isDark: Bool
    let onDismiss: () -> Void

    @State private var service: LocalTerminalService?

    var body: some View {
        Group {
            if let service {
                TerminalPanelView(
                    service: service,
                    preset: preset,
                    isDark: isDark,
                    onDismiss: onDismiss
                )
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Starting terminal…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Starting terminal")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            syncService()
        }
        .onChange(of: workingDirectoryPath) { _, _ in
            syncService()
        }
    }

    private func syncService() {
        let requested =
            workingDirectoryPath.isEmpty
            ? FileManager.default.temporaryDirectory
            : URL(fileURLWithPath: workingDirectoryPath, isDirectory: true)
        let resolved = center.service(
            for: tabID,
            workingDirectory: LocalTerminalService.effectiveWorkingDirectory(for: requested)
        )
        resolved.start()
        service = resolved
    }
}

struct TerminalPanelView: View {
    @Bindable var service: LocalTerminalService
    let preset: AppThemePreset
    let isDark: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .opacity(0.4)

            TerminalTTYView(
                styledOutput: service.styledOutput,
                background: NSColor(preset.codeBackground(isDark: isDark)),
                foreground: NSColor(preset.foreground(isDark: isDark)),
                onSend: { [service] data in
                    Task { @MainActor in
                        service.sendData(data)
                    }
                }
            )
            .accessibilityLabel("Terminal")
            .help("Click anywhere and type — keys go straight to the shell")

            Divider()
                .opacity(0.4)

            hintRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(preset.codeBackground(isDark: isDark))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(service.isRunning ? Color.green.opacity(0.85) : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
                .help(service.isRunning ? "Shell is running" : "Shell is stopped")

            Text(service.workingDirectory.lastPathComponent)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(service.workingDirectory.path)

            Spacer(minLength: 0)

            Button {
                service.interrupt()
            } label: {
                Text("Ctrl-C")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .interactiveHoverCircle()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .disabled(!service.isRunning)
            .help("Interrupt the foreground command")

            Button {
                service.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .interactiveHoverCircle()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Clear the screen")

            Button {
                service.restart()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .interactiveHoverCircle()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Restart the shell")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .interactiveHoverCircle()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Close the terminal")
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
    }

    private var hintRow: some View {
        HStack(spacing: 4) {
            Text("Click anywhere and type · Tab completes · ↑ ↓ history · ANSI colors")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .help("Keys go straight to the shell, like macOS Terminal")
    }
}
