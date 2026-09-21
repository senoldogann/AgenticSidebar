import SwiftUI

/// Besteci mikrofon düğmesi (Faz 0: tıklayarak aç/kapa).
///
/// Düğme yalnızca görünüm durumunu yansıtır: kayıt/bırakma ve metin akışı
/// `SpeechDictationService` tarafındadır, `ComposerView` besler.
struct ComposerDictationButton: View {
    let isRecording: Bool
    let size: CGFloat
    let onToggle: () -> Void

    var body: some View {
        Button {
            onToggle()
        } label: {
            Image(systemName: isRecording ? "mic.fill" : "mic")
                .font(.system(size: size <= 22 ? 11 : 12, weight: .medium))
                .foregroundStyle(isRecording ? .red : .secondary)
                .frame(width: size, height: size)
                .interactiveHoverCircle()
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(isRecording ? "Stop dictation" : "Dictate with microphone")
        .accessibilityLabel(isRecording ? "Stop dictation" : "Start dictation")
    }
}
