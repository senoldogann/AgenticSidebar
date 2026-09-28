import Foundation

/// Serializes writes and descriptor closure. Closing a FileHandle directly while
/// a previously enqueued write is pending raises an Objective-C exception that
/// Swift `try?` cannot catch. The lock covers the stop flag; the queue owns I/O.
final class TerminalQueuedInput: @unchecked Sendable {
    private let handle: FileHandle
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var isClosed = false
    /// İlk G/Ç hatası bir kez loglanır ve yapışır: boru kırıldığında
    /// (kabuk öldü) yazılar sessizce yutulmaz, terminale not düşer.
    private var didReportIOError = false

    init(handle: FileHandle, queue: DispatchQueue) {
        self.handle = handle
        self.queue = queue
    }

    func write(_ data: Data) {
        lock.lock()
        let accepting = !isClosed
        lock.unlock()
        guard accepting else { return }
        queue.async { [self] in
            lock.lock()
            let shouldWrite = !isClosed
            lock.unlock()
            guard shouldWrite else { return }
            do {
                try handle.write(contentsOf: data)
            } catch {
                reportIOErrorOnce("Terminal input could not be written: \(error.localizedDescription)")
            }
        }
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        lock.unlock()
        queue.async { [self] in
            do {
                try handle.close()
            } catch {
                reportIOErrorOnce("Terminal input could not be closed: \(error.localizedDescription)")
            }
        }
    }

    private func reportIOErrorOnce(_ message: String) {
        lock.lock()
        let shouldReport = !didReportIOError
        didReportIOError = true
        lock.unlock()
        guard shouldReport else { return }
        AppLog.panels.error("\(message, privacy: .public)")
    }
}
