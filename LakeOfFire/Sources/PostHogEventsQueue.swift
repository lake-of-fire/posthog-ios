import Foundation

/// Capture-only scheduling over the unchanged upstream durable FIFO. Compare
/// PostHogQueue.swift when merging upstream; see README's merge boundary.
/// No SDK configuration, endpoint registry, reachability, or test-mode startup
/// is needed. URLSession failures are handled by the ordinary retry policy.
final class PostHogEventsQueue {
    private struct Batch {
        let id = UUID()
        let entryIDs: [String]
        let records: [PostHogCapturedEvent]
    }

    private let fileQueue: PostHogFileBackedQueue
    private let maxQueueSize: Int
    private let interval: TimeInterval
    private let send: ([PostHogCapturedEvent], @escaping (PostHogUploadInfo) -> Void) -> Void
    private let worker = DispatchQueue(label: "com.lake-of-fire.PostHogEvents", target: .global(qos: .utility))
    private let lock = NSLock()
    private let deliveryGate = PostHogEventsDeliveryGate()
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var inFlight: UUID?
    private var cap: Int
    private var flushAt: Int
    private var retryCount = 0
    private var pausedUntil: Date?
    var onDeinit: (() -> Void)?

    init(configuration: PostHogEventsConfiguration, directory: URL,
         send: @escaping ([PostHogCapturedEvent], @escaping (PostHogUploadInfo) -> Void) -> Void) {
        fileQueue = PostHogFileBackedQueue(queue: directory, maxSize: configuration.maxQueueSize)
        maxQueueSize = configuration.maxQueueSize
        interval = configuration.flushInterval
        cap = configuration.maxBatchSize
        flushAt = configuration.flushAt
        self.send = send
    }

    var depth: Int { fileQueue.depth }

    /// Starts the maintained production timer on the queue's worker. Starting
    /// twice is harmless; stopping is final, including before the first tick.
    func start() {
        lock.withLock {
            guard !stopped, timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: worker)
            source.schedule(deadline: .now() + interval, repeating: interval)
            source.setEventHandler { [weak self] in self?.deliverBatch() }
            timer = source
            source.resume()
        }
    }

    /// Synchronous persistence preserves capture's crash-durability boundary.
    @discardableResult
    func add(_ record: PostHogCapturedEvent) -> Bool {
        guard let data = toJSONData(record.toJSON()) else { return false }
        let accepted = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            let result = fileQueue.add(data, maxSize: maxQueueSize)
            if result.evicted != nil { hedgeLog("Queue is full, dropping oldest record") }
            return result.success
        }
        if accepted, lock.withLock({ !stopped && fileQueue.depth >= flushAt }) { flush() }
        return accepted
    }

    func flush() {
        worker.async { [weak self] in self?.deliverBatch() }
    }

    /// Fences sends and completions before stopping the timer. All disk work
    /// holds `lock`; a running worker retains this queue until that work ends.
    func stop() {
        deliveryGate.close()
        lock.withLock {
            stopped = true
            timer?.cancel()
            timer = nil
            inFlight = nil
        }
    }

    // Called only on worker; the lock coordinates disk work with add/stop.
    private func deliverBatch() {
        let batch = lock.withLock { () -> Batch? in
            guard !stopped, inFlight == nil,
                  pausedUntil.map({ $0 <= Date() }) ?? true else { return nil }
            let entries = fileQueue.peekEntries(cap)
            guard !entries.isEmpty else { return nil }
            let records = entries.compactMap { PostHogCapturedEvent.fromJSON($0.data) }
            guard !records.isEmpty else {
                fileQueue.remove(ids: entries.map(\.id))
                return nil
            }
            let batch = Batch(entryIDs: entries.map(\.id), records: records)
            inFlight = batch.id
            return batch
        }
        guard let batch else { return }
        deliveryGate.send(batch.records, using: send) { [weak self] result in
            self?.worker.async { [weak self] in self?.complete(batch, result: result) }
        }
    }

    private func complete(_ batch: Batch, result: PostHogUploadInfo) {
        lock.withLock {
            guard !stopped, inFlight == batch.id else { return }
            defer { inFlight = nil }
            let status = result.statusCode ?? -1
            if status == -1 || status == 408 || status == 429 || (300...399).contains(status) || (500...599).contains(status) {
                // Match upstream's bounded linear backoff. A server-supplied
                // Retry-After remains a floor; no retry budget erases storage.
                retryCount = min(retryCount + 1, 30)
                let retryAfter = result.retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
                pausedUntil = Date().addingTimeInterval(max(Double(retryCount), retryAfter))
                return
            }
            if status == 413, cap > 1, batch.records.count > 1 {
                cap = max(1, min(cap, batch.records.count) / 2)
                flushAt = max(1, min(flushAt / 2, cap))
                return
            }
            // Success, terminal errors, and singleton 413 remove only the
            // snapshotted identities, never replacement events at capacity.
            retryCount = 0
            pausedUntil = nil
            fileQueue.remove(ids: batch.entryIDs)
        }
    }

    deinit {
        deliveryGate.close()
        timer?.cancel()
        onDeinit?()
    }
}

// Suppress queued sends and late completions before retiring a queue. Holding
// the recursive lock through callbacks also joins a callback already in progress.
private final class PostHogEventsDeliveryGate {
    private let lock = NSRecursiveLock()
    private var closed = false
    private var completions = [UUID: (PostHogUploadInfo) -> Void]()

    func send(_ records: [PostHogCapturedEvent], using send: ([PostHogCapturedEvent], @escaping (PostHogUploadInfo) -> Void) -> Void,
              completion: @escaping (PostHogUploadInfo) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        let id = UUID()
        completions[id] = completion
        // The transport retains an ID and gate, never the durable batch.
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

/// Running disk work holds the queue alive. Transport callbacks use weak queue
/// references; destruction is therefore a barrier before local storage erasure.
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
