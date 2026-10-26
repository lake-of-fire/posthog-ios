import Foundation

/// A batch-only transport. Redirects never forward project tokens or event bodies.
final class PostHogEventsTransport: @unchecked Sendable {
    private let configuration: PostHogEventsConfiguration
    private let session: URLSession

    init(configuration: PostHogEventsConfiguration, sessionConfiguration: URLSessionConfiguration? = nil) {
        self.configuration = configuration
        let settings = (sessionConfiguration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        settings.httpShouldSetCookies = false
        settings.httpCookieStorage = nil
        settings.urlCache = nil
        settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: settings, delegate: PostHogEventsRedirectPolicy(), delegateQueue: nil)
    }

    func send(_ events: [PostHogEvent], completion: @escaping (PostHogUploadInfo) -> Void) {
        guard let body = toJSONData(["api_key": configuration.projectToken, "batch": events.map { $0.toJSON() }]) else {
            completion(PostHogUploadInfo(statusCode: 400, error: nil))
            return
        }
        var request = URLRequest(url: configuration.host.appendingPathComponent("batch", isDirectory: true))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("posthog-ios-events/\(postHogVersion)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { _, response, error in
            let response = response as? HTTPURLResponse
            completion(PostHogUploadInfo(statusCode: response?.statusCode, error: error,
                                        retryAfter: response?.value(forHTTPHeaderField: "Retry-After").flatMap(parseRetryAfter)))
        }.resume()
    }

    func close() { session.invalidateAndCancel() }

    deinit { session.invalidateAndCancel() }
}

private final class PostHogEventsRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
