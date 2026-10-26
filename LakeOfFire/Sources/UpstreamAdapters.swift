import Foundation

// Minimal internal adapters for the unchanged upstream queue. A future queue
// dependency must be admitted here explicitly, rather than importing the SDK.
final class PostHogConfig {
    enum DataMode { case any, wifi }
    let dataMode = DataMode.any
}

final class PostHogStorage {
    enum StorageKey: String { case queue }
    let directory: URL

    init(directory: URL) { self.directory = directory }
    func url(forKey key: StorageKey) -> URL { directory.appendingPathComponent(key.rawValue, isDirectory: true) }
}

let retryDelay = 1.0
let maxRetryDelay = 30.0

// Suppress queued sends and late completions before retiring a queue. Holding
// the recursive lock through callbacks also joins a callback already in progress.
final class PostHogEventsDeliveryGate {
    private let lock = NSRecursiveLock()
    private var closed = false
    private var completions = [UUID: (PostHogUploadInfo) -> Void]()

    func send(_ records: [PostHogEvent], using send: ([PostHogEvent], @escaping (PostHogUploadInfo) -> Void) -> Void,
              completion: @escaping (PostHogUploadInfo) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        let id = UUID()
        completions[id] = completion
        // Transport retains only an ID and the gate, not the upstream payload.
        // Closing can therefore release an uncompleted payload/queue immediately.
        send(records) { [self] result in
            lock.lock()
            defer { lock.unlock() }
            if let callback = completions.removeValue(forKey: id), !closed { callback(result) }
        }
    }

    func close() {
        lock.lock()
        closed = true
        completions.removeAll()
        lock.unlock()
    }
}

/// Queue destruction is a barrier: queued flush closures hold the queue alive;
/// transport completions use weak queue references and are fenced by DeliveryGate.
final class PostHogEventsQueue<Record>: PostHogQueue<Record> {
    var onDeinit: (() -> Void)?
    deinit { onDeinit?() }
}

final class PostHogEventsQueueLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func wait() async {
        await withCheckedContinuation { continuation in
            let complete = lock.withLock {
                if finished { return true }
                waiters.append(continuation)
                return false
            }
            if complete { continuation.resume() }
        }
    }

    func finish() {
        let pending = lock.withLock {
            finished = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume() }
    }
}
