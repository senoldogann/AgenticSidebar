import Foundation
import Vision

protocol ScreenshotTextRecognizing: Sendable {
    func recognizeText(at fileURL: URL) async -> String
    func recognizeText(inImageData data: Data) async -> String
}

/// Runs Vision text recognition on a private queue.
///
/// Vision's synchronous `perform` blocks its calling thread, so it must never run
/// on the main actor: doing so froze the whole UI for the duration of every
/// screenshot analysis.
actor VisionScreenshotTextRecognizer: ScreenshotTextRecognizing {
    private let queue = DispatchQueue(
        label: "\(AppIdentity.bundleIdentifier).screenshot-ocr",
        qos: .userInitiated
    )

    func recognizeText(at fileURL: URL) async -> String {
        await run { () -> String in
            guard let data = try? Data(contentsOf: fileURL) else {
                return ""
            }

            return Self.recognizeText(in: data)
        }
    }

    func recognizeText(inImageData data: Data) async -> String {
        await run { Self.recognizeText(in: data) }
    }

    private func run(_ work: @escaping @Sendable () -> String) async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }

    private static func recognizeText(in data: Data) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(data: data, options: [:])
        do {
            try handler.perform([request])
        } catch {
            AppLog.automation.error(
                "Screenshot text recognition failed: \(error.localizedDescription, privacy: .public)"
            )
            return ""
        }

        let observations = request.results ?? []
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
