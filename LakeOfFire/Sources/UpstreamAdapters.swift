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
