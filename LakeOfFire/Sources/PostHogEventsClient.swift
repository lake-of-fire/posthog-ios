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
    private let deliveryGate: PostHogEventsDeliveryGate
    private final class DirectoryOwnership {
        let directory: URL
        private var ownsDirectory = false
        init(_ directory: URL) throws {
            self.directory = directory
            let claimed = ownershipLock.withLock { ownedDirectories.insert(directory).inserted }
            guard claimed else { throw PostHogEventsError.storageAlreadyInUse }
            ownsDirectory = true
        }
        deinit {
            if ownsDirectory { ownershipLock.withLock { _ = ownedDirectories.remove(directory) } }
        }
    }

    private let directory: URL
    private let directoryOwnership: DirectoryOwnership
    private let queueLifetime = PostHogEventsQueueLifetime()
    private var queue: PostHogQueue<PostHogEvent>?
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
        let gate = PostHogEventsDeliveryGate()
        self.deliveryGate = gate
        let ownership = try DirectoryOwnership(directory)
        self.directoryOwnership = ownership
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
                send: { records, completion in
                    gate.send(records, using: send, completion: completion)
                }, isRetriableStatusCode: { $0 == 408 || $0 == 429 || (500...599).contains($0) || (300...399).contains($0) }
            )
#if os(watchOS)
            let queue = PostHogEventsQueue(config, storage, endpoint)
#else
            let queue = PostHogEventsQueue(config, storage, endpoint, nil)
#endif
            let lifetime = queueLifetime
            queue.onDeinit = {
                // Retain directory ownership until all queue work is gone, even
                // if the client itself has already been released.
                withExtendedLifetime(ownership) { lifetime.finish() }
            }
            self.queue = queue
            // URLSession errors drive retry. No reachability observer or background task is installed.
            queue.start(disableReachabilityForTesting: true, disableQueueTimerForTesting: !startTimer)
        } catch {
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
            return queue?.add(frozen) ?? false
        }
    }

    /// Requests a flush. Returns immediately; failed delivery stays on disk for a later retry.
    public func flush() { stateLock.withLock { if !closed { queue?.flush() } } }

    /// Stops timers and uploads. Pending events remain on disk. The directory stays
    /// reserved until this instance deinitializes, preventing overlap with a retiring upload.
    public func close() {
        stateLock.withLock {
            guard !closed else { return }
            closed = true
            deliveryGate.close()
            queue?.stop()
            transport?.close()
        }
    }

    /// Stops capture/delivery, joins queued work, then deletes this client's owned
    /// identity and pending events. Does not send a final flush or erase server data.
    /// Release this closed instance before opening a replacement in the same directory.
    public func closeAndDeleteStorage() async throws {
        close()
        stateLock.withLock { queue = nil }
        // Queued flush closures retain the old queue until their disk reads
        // finish. Its destruction joins that work without changing upstream.
        await queueLifetime.wait()
        try Self.deleteDirectoryIfPresent(directory)
    }

    /// Deletes a dedicated queue without constructing a client or starting uploads.
    /// Refuses to erase storage owned by a live client in this process.
    public static func deleteStorage(configuration: PostHogEventsConfiguration) throws {
        let directory = configuration.storageDirectory
        try ownershipLock.withLock {
            guard !ownedDirectories.contains(directory) else { throw PostHogEventsError.storageAlreadyInUse }
            try deleteDirectoryIfPresent(directory)
        }
    }

    private static func deleteDirectoryIfPresent(_ directory: URL) throws {
        do { try FileManager.default.removeItem(at: directory) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {}
    }

    deinit {
        deliveryGate.close()
        queue?.stop()
        transport?.close()
    }

    var pendingEventCount: Int { stateLock.withLock { queue?.depth ?? 0 } }
}
