import Foundation

struct StreamingTextAppendResult: Equatable, Sendable {
    let accumulator: StreamingTextAccumulator
    let shouldScheduleFlush: Bool
}

struct StreamingTextDrainResult: Equatable, Sendable {
    let accumulator: StreamingTextAccumulator
    let text: String?
}

struct StreamingTextAccumulator: Equatable, Sendable {
    let pendingText: String
    let isFlushScheduled: Bool

    static let empty = StreamingTextAccumulator(
        pendingText: "",
        isFlushScheduled: false
    )

    func appending(_ delta: String) -> StreamingTextAppendResult {
        guard !delta.isEmpty else {
            return StreamingTextAppendResult(
                accumulator: self,
                shouldScheduleFlush: false
            )
        }

        return StreamingTextAppendResult(
            accumulator: StreamingTextAccumulator(
                pendingText: pendingText + delta,
                isFlushScheduled: true
            ),
            shouldScheduleFlush: !isFlushScheduled
        )
    }

    func draining() -> StreamingTextDrainResult {
        StreamingTextDrainResult(
            accumulator: .empty,
            text: pendingText.isEmpty ? nil : pendingText
        )
    }
}
