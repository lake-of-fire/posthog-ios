import Foundation

/// Thread-safe explicit events with upstream's durable batching and retry queue.
/// No screen/device inspection, remote configuration, or automatic events run.
public final class PostHogEventsClient: @unchecked Sendable {
    private struct Identity: Codable {
        let projectToken: String
        let host: URL
        let anonymousID: String
    }

    private static let ownershipLock = NSLock()
    private static var ownedDirectories = Set<URL>()
    private let stateLock = NSLock()
    private let directory: URL
    private let queue: PostHogQueue<PostHogEvent>
    private let transport: PostHogEventsTransport?
    private var closed = false
    private var sessionID = UUID.v7String()
    private var lastEventAt: Date?
    private let clock: () -> Date
    public let anonymousID: String

    /// Opens a single-process queue. Throws if another live client owns this directory,
    /// its persisted token/host differs, or identity cannot be persisted safely.
    /// Storage directories must not be shared across processes or app extensions.
    public convenience init(configuration: PostHogEventsConfiguration) throws {
        let transport = PostHogEventsTransport(configuration: configuration)
        try self.init(configuration: configuration, transport: transport, clock: Date.init,
                      startTimer: true, send: transport.send)
    }

    init(configuration: PostHogEventsConfiguration, transport: PostHogEventsTransport? = nil,
         clock: @escaping () -> Date = Date.init, startTimer: Bool = false,
         send: @escaping ([PostHogEvent], @escaping (PostHogUploadInfo) -> Void) -> Void) throws {
        let directory = configuration.storageDirectory
        self.directory = directory
        self.transport = transport
        self.clock = clock
        let claimed = Self.ownershipLock.withLock { Self.ownedDirectories.insert(directory).inserted }
        guard claimed else { throw PostHogEventsError.storageAlreadyInUse }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let identityURL = directory.appendingPathComponent("identity.json")
            let identity: Identity
            if FileManager.default.fileExists(atPath: identityURL.path) {
                identity = try JSONDecoder().decode(Identity.self, from: Data(contentsOf: identityURL))
                guard identity.projectToken == configuration.projectToken, identity.host == configuration.host else {
                    throw PostHogEventsError.storageConfigurationMismatch
                }
                guard UUID(uuidString: identity.anonymousID) != nil else { throw PostHogEventsError.invalidStoredIdentity }
            } else {
                identity = Identity(projectToken: configuration.projectToken, host: configuration.host,
                                    anonymousID: configuration.bootstrapAnonymousID ?? UUID.v7String())
                try JSONEncoder().encode(identity).write(to: identityURL, options: .atomic)
            }
            anonymousID = identity.anonymousID
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var storageDirectory = directory
            try storageDirectory.setResourceValues(values)
            let config = PostHogConfig()
            let storage = PostHogStorage(directory: directory)
            // Enforce a smaller configured capacity on restored files before
            // the upstream queue takes ownership of its in-memory index.
            _ = PostHogFileBackedQueue(queue: storage.url(forKey: .queue), maxSize: configuration.maxQueueSize)
            let endpoint = QueueEndpoint<PostHogEvent>(
                storageKey: .queue, oldStorageKeys: [], dispatchQueueLabel: "com.lake-of-fire.PostHogEvents",
                initialCap: { _ in configuration.maxBatchSize }, initialFlushAt: { _ in configuration.flushAt },
                maxQueueSize: { _ in configuration.maxQueueSize }, flushIntervalSeconds: { _ in configuration.flushInterval },
                rateCapMax: { _ in 0 }, rateCapWindowSeconds: { _ in 0 },
                encode: { toJSONData($0.toJSON()) }, decode: { PostHogEvent.fromJSON($0) }, describe: { _ in "event" },
                send: send, isRetriableStatusCode: { $0 == 408 || $0 == 429 || (500...599).contains($0) || (300...399).contains($0) }
            )
#if os(watchOS)
            queue = PostHogQueue(config, storage, endpoint)
#else
            queue = PostHogQueue(config, storage, endpoint, nil)
#endif
            // URLSession errors drive retry. No reachability observer or background task is installed.
            queue.start(disableReachabilityForTesting: true, disableQueueTimerForTesting: !startTimer)
        } catch {
            Self.ownershipLock.withLock { _ = Self.ownedDirectories.remove(directory) }
            throw error
        }
    }

    /// Persists an event before returning. False means invalid input, closed client,
    /// an event larger than 16 KiB, or a storage failure. Delivery is asynchronous.
    /// Person profiles are always disabled; only explicit caller properties are added.
    @discardableResult
    public func capture(_ event: String, properties: [String: Any] = [:]) -> Bool {
        stateLock.withLock {
            guard !closed, !event.isEmpty, event.count <= 200, !event.hasPrefix("$") else { return false }
            let date = clock()
            if let lastEventAt, date.timeIntervalSince(lastEventAt) > 30 * 60 || date < lastEventAt {
                sessionID = UUID.v7String()
            }
            lastEventAt = date
            var properties = properties
            properties["$process_person_profile"] = false
            properties["$is_identified"] = false
            properties["$session_id"] = sessionID
            properties["$lib"] = "posthog-ios-events"
            properties["$lib_version"] = postHogVersion
            let record = PostHogEvent(event: event, distinctId: anonymousID, properties: properties, timestamp: date)
            guard let data = toJSONData(record.toJSON()), data.count <= 16_384,
                  let frozen = PostHogEvent.fromJSON(data) else { return false }
            return queue.add(frozen)
        }
    }

    /// Requests a flush. Returns immediately; failed delivery stays on disk for a later retry.
    public func flush() { stateLock.withLock { if !closed { queue.flush() } } }

    /// Stops timers and uploads. Pending events remain on disk. The directory stays
    /// reserved until this instance deinitializes, preventing overlap with a retiring upload.
    public func close() {
        stateLock.withLock {
            guard !closed else { return }
            closed = true
            queue.stop()
            transport?.close()
        }
    }

    deinit {
        queue.stop()
        transport?.close()
        Self.ownershipLock.withLock { _ = Self.ownedDirectories.remove(directory) }
    }

    var pendingEventCount: Int { queue.depth }
}
