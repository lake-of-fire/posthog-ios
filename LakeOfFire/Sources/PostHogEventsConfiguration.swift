import Foundation

/// The capture-only client's immutable configuration. No remote settings are fetched.
public struct PostHogEventsConfiguration: Sendable {
    public let projectToken: String
    public let host: URL
    public let storageDirectory: URL
    public let flushAt: Int
    public let maxBatchSize: Int
    public let maxQueueSize: Int
    public let flushInterval: TimeInterval
    public let bootstrapAnonymousID: String?

    /// Creates a client configuration. Use a dedicated directory for each token/host.
    /// Queue capacity is bounded; accepting a new event at capacity evicts the oldest.
    public init(projectToken: String, host: URL = URL(string: "https://eu.i.posthog.com")!,
                storageDirectory: URL, flushAt: Int = 5, maxBatchSize: Int = 50,
                maxQueueSize: Int = 1_000, flushInterval: TimeInterval = 10,
                bootstrapAnonymousID: String? = nil) throws {
        guard projectToken.hasPrefix("phc_"), projectToken.count > 4,
              projectToken.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-" )).contains($0) }),
              host.scheme == "https", host.host?.isEmpty == false,
              host.user == nil, host.password == nil, host.query == nil, host.fragment == nil,
              storageDirectory.isFileURL, flushAt > 0, maxBatchSize > 0, maxQueueSize > 0,
              flushInterval.isFinite, flushInterval > 0,
              bootstrapAnonymousID.map({ UUID(uuidString: $0) != nil }) ?? true else {
            throw PostHogEventsError.invalidConfiguration
        }
        self.projectToken = projectToken
        self.host = host
        self.storageDirectory = storageDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.flushAt = min(flushAt, maxBatchSize)
        self.maxBatchSize = maxBatchSize
        self.maxQueueSize = maxQueueSize
        self.flushInterval = flushInterval
        self.bootstrapAnonymousID = bootstrapAnonymousID
    }
}

public enum PostHogEventsError: Error {
    case invalidConfiguration
    case storageAlreadyInUse
    case storageConfigurationMismatch
    case invalidStoredIdentity
}
