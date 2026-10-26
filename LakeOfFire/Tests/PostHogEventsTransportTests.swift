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
        let event = PostHogEvent(event: "opened", distinctId: UUID().uuidString)
        transport.send([event]) { result in response.set(result) }
        try await wait { response.value != nil }
        // URLProtocol can surface a refused redirect as cancellation without
        // an HTTP response. Neither outcome may acknowledge or forward it.
        #expect(response.value?.statusCode == 302 || response.value?.statusCode == nil)
        #expect(BatchProtocol.requests.count == 1)
        #expect(BatchProtocol.requests.first?.url?.host == "events.example.test")
        transport.close()
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
