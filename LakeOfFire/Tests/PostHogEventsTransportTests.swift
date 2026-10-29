import Foundation
import Testing
@testable import PostHogEvents

@Suite(.serialized)
struct PostHogEventsTransportTests {
    @Test func uploadUsesOnlyBatchEndpointAndIgnoresResponseConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try PostHogEventsConfiguration(projectToken: "phc_test", host: URL(string: "https://events.example.test")!,
                                                   storageDirectory: directory, flushAt: 1)
        BatchProtocol.reset(status: 200, headers: ["Set-Cookie": "tracking=unexpected"],
                            data: Data("{\"sessionRecording\":true,\"surveys\":[],\"featureFlags\":{}}".utf8))
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [BatchProtocol.self]
        let transport = PostHogEventsTransport(configuration: config, sessionConfiguration: settings)
        let client = try PostHogEventsClient(configuration: config, transport: transport, send: transport.send)
        #expect(client.capture("reader_opened", properties: ["chapter": 2]))
        try await wait { BatchProtocol.requests.count == 1 && client.pendingEventCount == 0 }
        let request = try #require(BatchProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://events.example.test/batch/")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(JSONSerialization.jsonObject(with: bodyData(request)) as? [String: Any])
        #expect(body["api_key"] as? String == "phc_test")
        let batch = try #require(body["batch"] as? [[String: Any]])
        #expect(batch.count == 1)
        #expect(batch.first?["event"] as? String == "reader_opened")
        #expect(batch.first?["distinct_id"] as? String == client.anonymousID)
        #expect(UUID(uuidString: batch.first?["uuid"] as? String ?? "") != nil)
        #expect(client.capture("second"))
        // Disk acknowledgement can precede release of the queue's in-flight
        // flag. Explicit flush is idempotent and may be requested again.
        try await wait { client.flush(); return BatchProtocol.requests.count == 2 && client.pendingEventCount == 0 }
        #expect(BatchProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
        #expect(BatchProtocol.requests.allSatisfy { $0.url?.absoluteString == "https://events.example.test/batch/" })
        client.close()
    }

    @Test func redirectDoesNotForwardTokenOrBodyToAnotherHost() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try PostHogEventsConfiguration(projectToken: "phc_test", host: URL(string: "https://events.example.test")!, storageDirectory: directory)
        BatchProtocol.reset(status: 302, headers: ["Location": "https://other.example.test/stolen"], data: Data())
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [BatchProtocol.self]
        let transport = PostHogEventsTransport(configuration: config, sessionConfiguration: settings)
        let response = UploadResult()
        let event = PostHogCapturedEvent(event: "opened", distinctId: UUID().uuidString)
        transport.send([event]) { result in response.set(result) }
        try await wait { response.value != nil }
        // URLProtocol can surface a refused redirect as cancellation without
        // an HTTP response. Neither outcome may acknowledge or forward it.
        #expect(response.value?.statusCode == 302 || response.value?.statusCode == nil)
        #expect(BatchProtocol.requests.count == 1)
        #expect(BatchProtocol.requests.first?.url?.host == "events.example.test")
        transport.close()
    }

    @Test func timerRestoresAndDeliversDurableBatchesWithOriginalEnvelopes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = URL(string: "https://events.example.test")!
        let initial = try PostHogEventsConfiguration(projectToken: "phc_test", host: host, storageDirectory: directory, flushAt: 50)
        let timestamp = try #require(toISO8601Date("2026-10-29T12:34:56.789Z"))
        var original: PostHogEventsClient? = try PostHogEventsClient(configuration: initial, clock: { timestamp }, send: { _, _ in
            Issue.record("Below-threshold persisted events must not be sent before reopen")
        })
        for index in 0..<3 { #expect(original!.capture("stored_\(index)", properties: ["chapter": index])) }
        let anonymousID = original!.anonymousID
        let queueDirectory = directory.appendingPathComponent("queue", isDirectory: true)
        let persisted = try FileManager.default.contentsOfDirectory(at: queueDirectory, includingPropertiesForKeys: nil).map {
            try #require(JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any])
        }
        original = nil

        BatchProtocol.reset(status: 200, headers: [:], data: Data())
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [BatchProtocol.self]
        let config = try PostHogEventsConfiguration(projectToken: "phc_test", host: host, storageDirectory: directory,
                                                   flushAt: 2, maxBatchSize: 2, flushInterval: 0.02)
        let transport = PostHogEventsTransport(configuration: config, sessionConfiguration: settings)
        let client = try PostHogEventsClient(configuration: config, transport: transport, startTimer: true, send: transport.send)
        defer { client.close() }
        // No capture or explicit flush on the restored client: the real timer
        // must send both the full batch and its below-threshold remainder.
        try await wait { BatchProtocol.requests.count == 2 && client.pendingEventCount == 0 }
        let batches = try BatchProtocol.requests.map { request in
            let body = try #require(JSONSerialization.jsonObject(with: bodyData(request)) as? [String: Any])
            #expect(body["api_key"] as? String == "phc_test")
            #expect(request.url?.absoluteString == "https://events.example.test/batch/")
            return try #require(body["batch"] as? [[String: Any]])
        }
        #expect(batches.map(\.count) == [2, 1])
        let delivered = batches.flatMap { $0 }
        #expect(delivered.compactMap { $0["event"] as? String } == ["stored_0", "stored_1", "stored_2"])
        for event in delivered {
            let prior = try #require(persisted.first { $0["uuid"] as? String == event["uuid"] as? String })
            #expect(NSDictionary(dictionary: event).isEqual(to: prior))
            #expect(event["timestamp"] as? String == "2026-10-29T12:34:56.789Z")
            #expect(event["distinct_id"] as? String == anonymousID)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: queueDirectory.path).isEmpty)
    }

    @Test func timerRetriesMockHTTPWithoutExplicitFlushAndKeepsSameBody() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try PostHogEventsConfiguration(projectToken: "phc_test", host: URL(string: "https://events.example.test")!,
                                                   storageDirectory: directory, flushAt: 50, flushInterval: 0.02)
        BatchProtocol.reset(status: 503, headers: ["Retry-After": "1.25"], data: Data())
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [BatchProtocol.self]
        let transport = PostHogEventsTransport(configuration: config, sessionConfiguration: settings)
        let client = try PostHogEventsClient(configuration: config, transport: transport, startTimer: true, send: transport.send)
        defer { client.close() }
        #expect(client.capture("retry_over_http", properties: ["chapter": 3]))
        try await wait { BatchProtocol.requests.count == 1 }
        BatchProtocol.respond(status: 200, headers: [:], data: Data())
        try await Task.sleep(nanoseconds: 1_050_000_000)
        #expect(BatchProtocol.requests.count == 1)
        #expect(client.pendingEventCount == 1)
        try await wait { BatchProtocol.requests.count == 2 && client.pendingEventCount == 0 }
        let first = try #require(JSONSerialization.jsonObject(with: bodyData(BatchProtocol.requests[0])) as? [String: Any])
        let retried = try #require(JSONSerialization.jsonObject(with: bodyData(BatchProtocol.requests[1])) as? [String: Any])
        #expect(NSDictionary(dictionary: first).isEqual(to: retried))
    }

    private func bodyData(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError! }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for mocked transport")
        throw NSError(domain: "PostHogEventsTransportTests", code: 1)
    }
}

private final class UploadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: PostHogUploadInfo?
    var value: PostHogUploadInfo? { lock.withLock { result } }
    func set(_ result: PostHogUploadInfo) { lock.withLock { self.result = result } }
}

private final class BatchProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var recorded = [URLRequest]()
    private static var status = 200
    private static var headers = [String: String]()
    private static var data = Data()
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset(status: Int, headers: [String: String], data: Data) {
        lock.withLock { recorded = []; self.status = status; self.headers = headers; self.data = data }
    }
    static func respond(status: Int, headers: [String: String], data: Data) {
        lock.withLock { self.status = status; self.headers = headers; self.data = data }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix("example.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, headers, data) = Self.lock.withLock { () -> (Int, [String: String], Data) in
            Self.recorded.append(request)
            return (Self.status, Self.headers, Self.data)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        if (300...399).contains(status), let location = headers["Location"], let target = URL(string: location) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        } else {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
