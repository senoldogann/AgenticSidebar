import AppKit
import SwiftUI

/// Sağ paneldeki canlı bilgisayar sekmesi: ajan bilgisayarı kullanırken
/// odaklı ekranın kareleri burada akar.
///
/// Kareler `ComputerLiveCaptureService` tarafında üretilir; panel yalnız
/// görünürken ve tur sürerken döngüyü açar. Tur bitince boş durum gösterilir —
/// son kareyi donmuş hâlde tutmak "hâlâ izleniyor" izlenimi verirdi.
struct ComputerLivePanelView: View {
    let service: ComputerLiveCaptureService
    let state: ComputerLiveState
    let preset: AppThemePreset
    let isDark: Bool
    let onDismiss: () -> Void

    private var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .opacity(0.4)

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(preset.surface(isDark: isDark).opacity(0.96))
        .onAppear {
            syncCaptureLoop()
        }
        .onDisappear {
            service.stop()
        }
        .onChange(of: state) { _, _ in
            syncCaptureLoop()
        }
        .onChange(of: service.isScreenRecordingGranted) { _, _ in
            syncCaptureLoop()
        }
    }

    // MARK: - Başlık

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isActive ? Color.green.opacity(0.85) : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
                .help(isActive ? "A computer-use turn is running" : "No computer-use turn is running")

            Text("Computer Use")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.primary)

            if case .active(let step) = state {
                Text(step.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(step.detail ?? step.title)
            }

            Spacer(minLength: 0)

            if service.isRunning {
                Text("live")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .interactiveHoverCircle()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Close the live view")
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
    }

    // MARK: - İçerik

    @ViewBuilder
    private var content: some View {
        switch state {
        case .active(let step):
            if service.isScreenRecordingGranted {
                liveSurface(step: step)
            } else {
                permissionState
            }
        case .idle:
            idleState
        }
    }

    private func liveSurface(step: ComputerLiveStep) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let frame = service.frame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(preset.border(isDark: isDark).opacity(0.8), lineWidth: 1)
                    )
                    .overlay {
                        GeometryReader { proxy in
                            if let pointer = service.pointerPosition {
                                AgentCursorMarker()
                                    .position(
                                        x: pointer.x * proxy.size.width,
                                        y: pointer.y * proxy.size.height
                                    )
                            }
                        }
                    }
                    .padding(12)
                    .accessibilityLabel("Live view of the screen the agent is using")
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for the first frame…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            stepPill(step: step)
                .padding(.leading, 26)
                .padding(.bottom, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let failureMessage = service.failureMessage {
                Text(failureMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .padding(.bottom, 6)
            }
        }
    }

    /// Ajanın işaretçisi: sistem imlecinden ayırt edilsin diye vurgu renginde
    /// halka ve gölgeli ok ucu; konum servisten normalize gelir, katman bunu
    /// görüntü boyuna çarpar. Ucun hedefe oturması için küçük bir kaydırma
    /// uygulanır.
    private struct AgentCursorMarker: View {
        var body: some View {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.28))
                    .frame(width: 24, height: 24)

                Circle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                    .frame(width: 24, height: 24)

                Image(systemName: "cursorarrow")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
            .offset(x: 6, y: 8)
            .accessibilityHidden(true)
        }
    }

    /// Kare üstündeki adım rozeti: referans yerleşimdeki gibi koyu bir kapsül,
    /// ajanın o an ne yaptığını söyler.
    private func stepPill(step: ComputerLiveStep) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(step.isRunning ? Color.green : Color.orange)
                .frame(width: 6, height: 6)

            Text(step.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.72), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        .help(step.detail ?? step.title)
        .accessibilityLabel("Current computer step: \(step.title)")
    }

    private var idleState: some View {
        VStack(spacing: 10) {
            Image(systemName: "computermouse")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)

            Text("No computer-use session")
                .font(.system(size: 12.5, weight: .semibold))

            Text(
                "While the agent drives the computer, the screen it is working on appears here live. Ask for something like “open Notes and write five random numbers” to start one."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)

            if !service.isScreenRecordingGranted {
                permissionNotice
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var permissionState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 22))
                .foregroundStyle(.orange)

            Text("Screen Recording is off")
                .font(.system(size: 12.5, weight: .semibold))

            Text(
                "macOS gives this app the screen it may capture. Grant Screen Recording and the live view starts on its own — the agent keeps working meanwhile."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)

            permissionNotice
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var permissionNotice: some View {
        HStack(spacing: 8) {
            if service.isRequestingScreenRecording {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    service.requestScreenRecording()
                } label: {
                    Label("Grant Screen Recording…", systemImage: "hand.raised.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointingHandCursor()
            }

            Button {
                if let url = ComputerUseSettingsPane.screenCapture.url {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Open System Settings", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointingHandCursor()
        }
    }

    private func syncCaptureLoop() {
        if isActive, service.isScreenRecordingGranted {
            service.start()
        } else {
            service.stop()
        }
    }
}
