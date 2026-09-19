import Foundation

/// Serializes writes and descriptor closure. Closing a FileHandle directly while
/// a previously enqueued write is pending raises an Objective-C exception that
/// Swift `try?` cannot catch. The lock covers the stop flag; the queue owns I/O.
final class TerminalQueuedInput: @unchecked Sendable {
    private let handle: FileHandle
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var isClosed = false

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
            try? handle.write(contentsOf: data)
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
            try? handle.close()
        }
    }
}
