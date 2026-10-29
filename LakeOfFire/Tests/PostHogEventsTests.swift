import Foundation
import Testing
@testable import PostHogEvents

@Suite(.serialized)
struct PostHogEventsTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("posthog-events-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func configuration(_ directory: URL, capacity: Int = 1_000, batch: Int = 50) throws -> PostHogEventsConfiguration {
        try PostHogEventsConfiguration(projectToken: "phc_test", host: URL(string: "https://events.example.test")!,
                                      storageDirectory: directory, flushAt: 1_000, maxBatchSize: batch, maxQueueSize: capacity)
    }

    @Test func configurationRejectsCredentialsHTTPAndInvalidBounds() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for host in ["http://events.example.test", "https://user:password@events.example.test", "https://events.example.test/?secret=x"] {
            #expect(throws: PostHogEventsError.self) { try PostHogEventsConfiguration(projectToken: "phc_test", host: URL(string: host)!, storageDirectory: dir) }
        }
        #expect(throws: PostHogEventsError.self) { try PostHogEventsConfiguration(projectToken: "invalid", storageDirectory: dir) }
        #expect(throws: PostHogEventsError.self) { try PostHogEventsConfiguration(projectToken: "phc_test", storageDirectory: dir, maxQueueSize: 0) }
        #expect(throws: PostHogEventsError.self) { try PostHogEventsConfiguration(projectToken: "phc_test", storageDirectory: dir, flushInterval: .nan) }
    }

    @Test func blockedQueueFailsOpenAndCanRecoverWithoutLosingTheObstruction() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try configuration(dir)
        let queue = dir.appendingPathComponent("queue")
        let obstruction = Data("preserve this file".utf8)
        try obstruction.write(to: queue)

        #expect(throws: (any Error).self) {
            try PostHogEventsClient(configuration: config, send: { _, _ in })
        }
        #expect(try Data(contentsOf: queue) == obstruction)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("identity.json").path))

        // A failed initializer must release its ownership reservation, allowing
        // the app's bounded retry to open the same directory after repair.
        try FileManager.default.moveItem(at: queue, to: dir.appendingPathComponent("blocked-queue"))
        let recovered = try PostHogEventsClient(configuration: config, send: { _, _ in })
        #expect(recovered.capture("after_recovery"))
        #expect(recovered.pendingEventCount == 1)
        #expect(try persistedEvents(dir).first?["event"] as? String == "after_recovery")
    }

    @Test func persistsIdentityAndQueuedUUIDAcrossReopen() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try configuration(dir)
        var first: PostHogEventsClient? = try PostHogEventsClient(configuration: config, send: { _, _ in })
        let id = first!.anonymousID
        #expect(first!.capture("opened", properties: ["chapter": 1]))
        let before = try persistedEvents(dir)
        first = nil
        let second = try PostHogEventsClient(configuration: config, send: { _, _ in })
        #expect(second.anonymousID == id)
        #expect(second.pendingEventCount == 1)
        let after = try persistedEvents(dir)
        #expect(before.first?["uuid"] as? String == after.first?["uuid"] as? String)
    }

    @Test func directoryOwnershipAndTokenScopeAreEnforced() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var first: PostHogEventsClient? = try PostHogEventsClient(configuration: configuration(dir), send: { _, _ in })
        #expect(throws: PostHogEventsError.self) { try PostHogEventsClient(configuration: configuration(dir), send: { _, _ in }) }
        first?.close()
        #expect(throws: PostHogEventsError.self) { try PostHogEventsClient(configuration: configuration(dir), send: { _, _ in }) }
        first = nil
        let other = try PostHogEventsConfiguration(projectToken: "phc_other", storageDirectory: dir)
        #expect(throws: PostHogEventsError.self) { try PostHogEventsClient(configuration: other, send: { _, _ in }) }
    }

    @Test func bootstrapIdentityIsUsedOnlyForNewStorage() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seed = UUID().uuidString
        let initial = try PostHogEventsConfiguration(projectToken: "phc_test", storageDirectory: dir, bootstrapAnonymousID: seed)
        var first: PostHogEventsClient? = try PostHogEventsClient(configuration: initial, send: { _, _ in })
        #expect(first?.anonymousID == seed)
        first = nil
        let replacement = try PostHogEventsConfiguration(projectToken: "phc_test", storageDirectory: dir, bootstrapAnonymousID: UUID().uuidString)
        let second = try PostHogEventsClient(configuration: replacement, send: { _, _ in })
        #expect(second.anonymousID == seed)
        #expect(throws: PostHogEventsError.self) {
            try PostHogEventsConfiguration(projectToken: "phc_test", storageDirectory: dir, bootstrapAnonymousID: "not-a-uuid")
        }
    }

    @Test func onlyExplicitEventsAndAnonymousPropertiesArePersisted() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try PostHogEventsClient(configuration: configuration(dir), send: { _, _ in })
        #expect(client.pendingEventCount == 0)
        #expect(!client.capture("$identify"))
        #expect(!client.capture(""))
        #expect(!client.capture("oversized", properties: ["text": String(repeating: "x", count: 20_000)]))
        #expect(client.capture("opened", properties: ["$process_person_profile": true, "$is_identified": true, "path": URL(string: "https://example.test/book")!]))
        let event = try #require(persistedEvents(dir).first)
        let properties = try #require(event["properties"] as? [String: Any])
        #expect(properties["$process_person_profile"] as? Bool == false)
        #expect(properties["$is_identified"] as? Bool == false)
        #expect(properties["path"] as? String == "https://example.test/book")
        #expect(properties["$device_type"] == nil && properties["$screen_name"] == nil)
        client.close()
        #expect(!client.capture("after_close"))
    }

    @Test func restoredQueueHonorsReducedCapacity() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var first: PostHogEventsClient? = try PostHogEventsClient(configuration: configuration(dir, capacity: 10), send: { _, _ in })
        for index in 0..<5 { #expect(first!.capture("event_\(index)")) }
        first = nil
        let second = try PostHogEventsClient(configuration: configuration(dir, capacity: 2), send: { _, _ in })
        #expect(second.pendingEventCount == 2)
        #expect(Set(try persistedEvents(dir).compactMap { $0["event"] as? String }) == ["event_3", "event_4"])
    }

    @Test func captureIsSafeAcrossThreadsAndBoundsDiskQueue() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try PostHogEventsClient(configuration: configuration(dir, capacity: 20, batch: 1000), send: { _, _ in })
        DispatchQueue.concurrentPerform(iterations: 100) { index in _ = client.capture("event_\(index)") }
        #expect(client.pendingEventCount == 20)
        #expect(try persistedEvents(dir).count == 20)
    }

    @Test func captureFreezesMutablePropertiesBeforeReturning() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try PostHogEventsClient(configuration: configuration(dir), send: { _, _ in })
        let nested = NSMutableDictionary(dictionary: ["chapter": 1])
        #expect(client.capture("opened", properties: ["nested": nested]))
        nested["chapter"] = 2
        let properties = try #require(persistedEvents(dir).first?["properties"] as? [String: Any])
        #expect((properties["nested"] as? [String: Any])?["chapter"] as? Int == 1)
    }

    @Test func malformedStoredEntriesAreSkippedWithoutLosingValidEvents() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queueDir = dir.appendingPathComponent("queue", isDirectory: true)
        try FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        let storage = PostHogFileBackedQueue(queue: queueDir)
        let valid = PostHogCapturedEvent(event: "survivor", distinctId: UUID().uuidString, properties: ["chapter": 7])
        #expect(storage.add(Data("broken JSON".utf8)).success)
        #expect(storage.add(try #require(toJSONData(valid.toJSON()))).success)
        #expect(storage.add(Data("{\"event\":\"missing_envelope\"}".utf8)).success)
        let sent = SentBatches()
        let client = try PostHogEventsClient(configuration: configuration(dir), send: { sent.append($0, $1) })
        #expect(client.pendingEventCount == 3)
        client.flush()
        try await wait { sent.count == 1 }
        #expect(sent.uuids(0) == [valid.uuid.uuidString])
        sent.complete(0, status: 200)
        try await wait { client.pendingEventCount == 0 }
        #expect(try persistedEvents(dir).isEmpty)
    }

    @Test func entirelyMalformedStorageIsClearedWithoutAnUpload() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queueDir = dir.appendingPathComponent("queue", isDirectory: true)
        try FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        let storage = PostHogFileBackedQueue(queue: queueDir)
        #expect(storage.add(Data("null".utf8)).success)
        let sent = SentBatches()
        let client = try PostHogEventsClient(configuration: configuration(dir), send: { sent.append($0, $1) })
        client.flush()
        try await wait { client.pendingEventCount == 0 }
        #expect(sent.count == 0)
    }

    @Test func acknowledgementKeepsIdenticalReplacementPayloadsAtCapacity() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sent = SentBatches()
        let queue = PostHogEventsQueue(configuration: try configuration(dir, capacity: 3, batch: 3), directory: dir,
                                      send: { sent.append($0, $1) })
        defer { queue.stop() }
        let record = PostHogCapturedEvent(event: "identical", distinctId: UUID().uuidString)
        for _ in 0..<3 { #expect(queue.add(record)) }
        try await wait { sent.count == 1 }
        // Even event UUID and payload are identical; storage-entry identities
        // alone distinguish the replacement files from the in-flight batch.
        for _ in 0..<3 { #expect(queue.add(record)) }
        sent.complete(0, status: 200)
        try await wait { queue.flush(); return sent.count == 2 }
        #expect(queue.depth == 3)
        #expect(sent.uuids(1) == sent.uuids(0))
        sent.complete(1, status: 200)
        try await wait { queue.depth == 0 }
    }

    @Test(arguments: [503, -1])
    func timerRetriesHTTPAndTransportFailuresWithoutExplicitFlush(status: Int) async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try PostHogEventsConfiguration(projectToken: "phc_test", host: URL(string: "https://events.example.test")!,
                                                   storageDirectory: dir, flushAt: 50, flushInterval: 0.02)
        let sent = SentBatches()
        let client = try PostHogEventsClient(configuration: config, startTimer: true, send: { sent.append($0, $1) })
        defer { client.close() }
        #expect(client.capture("timer_retry"))
        try await wait { sent.count == 1 }
        let firstIDs = sent.uuids(0)
        sent.complete(0, result: PostHogUploadInfo(statusCode: status == -1 ? nil : status,
                                                error: status == -1 ? URLError(.notConnectedToInternet) : nil,
                                                retryAfter: 1.25))
        try await Task.sleep(nanoseconds: 1_050_000_000)
        #expect(sent.count == 1)
        #expect(client.pendingEventCount == 1)
        try await wait { sent.count == 2 }
        #expect(sent.uuids(1) == firstIDs)
        sent.complete(1, status: 200)
        try await wait { client.pendingEventCount == 0 }
        #expect(try persistedEvents(dir).isEmpty)
    }

    @Test func stopBeforeStartPreservesStorageAndCannotRestart() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sent = SentBatches()
        let config = try PostHogEventsConfiguration(projectToken: "phc_test", storageDirectory: dir, flushInterval: 0.05)
        let queue = PostHogEventsQueue(configuration: config, directory: dir, send: { sent.append($0, $1) })
        #expect(queue.add(PostHogCapturedEvent(event: "offline", distinctId: UUID().uuidString)))
        queue.stop()
        queue.start()
        queue.start()
        queue.flush()
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(sent.count == 0)
        #expect(queue.depth == 1)
        #expect(!queue.add(PostHogCapturedEvent(event: "closed", distinctId: UUID().uuidString)))
    }

    @Test func closePreservesInFlightStorageAndRejectsLateSuccess() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try PostHogEventsConfiguration(projectToken: "phc_test", storageDirectory: dir, flushInterval: 0.02)
        let sent = SentBatches()
        let client = try PostHogEventsClient(configuration: config, startTimer: true, send: { sent.append($0, $1) })
        #expect(client.capture("before_close"))
        try await wait { sent.count == 1 }
        let before = try persistedEvents(dir)
        client.close()
        sent.complete(0, status: 200)
        client.flush()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(sent.count == 1)
        #expect(client.pendingEventCount == 1)
        #expect(try persistedEvents(dir).first?["uuid"] as? String == before.first?["uuid"] as? String)
        #expect(!client.capture("after_close"))
    }

    @Test(arguments: [400, 413])
    func terminalSingletonRemovesOnlyItsOwnEntry(status: Int) async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sent = SentBatches()
        let client = try PostHogEventsClient(configuration: configuration(dir, batch: 1), send: { sent.append($0, $1) })
        #expect(client.capture("terminal"))
        try await wait { sent.count == 1 }
        #expect(client.capture("later"))
        sent.complete(0, status: status)
        try await wait { client.flush(); return sent.count == 2 }
        #expect(sent.uuids(1) != sent.uuids(0))
        #expect(client.pendingEventCount == 1)
        sent.complete(1, status: 200)
        try await wait { client.pendingEventCount == 0 }
    }

    @Test func retryRetainsExactEventsUntilAcknowledged() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sent = SentBatches()
        let client = try PostHogEventsClient(configuration: configuration(dir), send: { events, completion in sent.append(events, completion) })
        #expect(client.capture("first"))
        client.flush()
        try await wait { sent.count == 1 }
        let uuid = sent.uuids(0)
        sent.complete(0, status: 503)
        #expect(client.pendingEventCount == 1)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        client.flush()
        try await wait { sent.count == 2 }
        #expect(sent.uuids(1) == uuid)
        sent.complete(1, status: 200)
        try await wait { client.pendingEventCount == 0 }
    }

    @Test func oversizedBatchShrinksWithoutDroppingUnrelatedEvents() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sent = SentBatches()
        let client = try PostHogEventsClient(configuration: configuration(dir, batch: 4), send: { events, completion in sent.append(events, completion) })
        for index in 0..<3 { #expect(client.capture("event_\(index)")) }
        client.flush()
        try await wait { sent.count == 1 }
        sent.complete(0, status: 413)
        #expect(client.pendingEventCount == 3)
        client.flush()
        try await wait { sent.count == 2 }
        #expect(sent.uuids(1).count == 1)
        sent.complete(1, status: 200)
        try await wait { client.pendingEventCount == 2 }
        client.flush()
        try await wait { sent.count == 3 }
        sent.complete(2, status: 200)
        try await wait { client.pendingEventCount == 1 }
        client.flush()
        try await wait { sent.count == 4 }
        sent.complete(3, status: 200)
        try await wait { client.pendingEventCount == 0 }
    }

    @Test func purgeJoinsQueuedWorkAndRejectsLateResponses() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sent = SentBatches()
        let config = try PostHogEventsConfiguration(projectToken: "phc_test", storageDirectory: dir, flushInterval: 0.02)
        var client: PostHogEventsClient? = try PostHogEventsClient(configuration: config, startTimer: true, send: { events, completion in sent.append(events, completion) })
        let oldID = client!.anonymousID
        #expect(client!.capture("before_withdrawal"))
        client!.flush()
        try await wait { sent.count == 1 }
        for _ in 0..<100 { client!.flush() }
        try await client!.closeAndDeleteStorage()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(!client!.capture("after_withdrawal"))
        let count = sent.count
        sent.complete(0, status: 200)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(sent.count == count)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        client = nil
        let replacement = try PostHogEventsClient(configuration: configuration(dir), send: { _, _ in })
        #expect(replacement.anonymousID != oldID)
        #expect(replacement.pendingEventCount == 0)
        #expect(replacement.capture("after_reenable"))
        #expect(try persistedEvents(dir).count == 1)
    }

    @Test func unopenedQueueCanBeErasedWithoutStartingDelivery() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try configuration(dir)
        var client: PostHogEventsClient? = try PostHogEventsClient(configuration: config, send: { _, _ in })
        #expect(client!.capture("offline"))
        #expect(throws: PostHogEventsError.self) { try PostHogEventsClient.deleteStorage(configuration: config) }
        client = nil
        try PostHogEventsClient.deleteStorage(configuration: config)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        try PostHogEventsClient.deleteStorage(configuration: config)
    }

    @Test func concurrentCapturesCannotSurviveCompletedPurge() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try PostHogEventsClient(configuration: configuration(dir), send: { _, _ in })
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for _ in 0..<100 { client.capture("racing") } }
            group.addTask { try? await client.closeAndDeleteStorage() }
        }
        try await client.closeAndDeleteStorage()
        #expect(!client.capture("closed"))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func sessionRotatesOnlyAfterInactivityOrClockRollback() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var date = Date(timeIntervalSince1970: 1_000_000)
        let client = try PostHogEventsClient(configuration: configuration(dir), clock: { date }, send: { _, _ in })
        #expect(client.capture("first"))
        date += 60
        #expect(client.capture("second"))
        date += 1801
        #expect(client.capture("third"))
        let events = try persistedEvents(dir).sorted { ($0["timestamp"] as! String) < ($1["timestamp"] as! String) }
        let ids = events.map { ($0["properties"] as! [String: Any])["$session_id"] as! String }
        #expect(ids[0] == ids[1])
        #expect(ids[1] != ids[2])
    }

    private func persistedEvents(_ directory: URL) throws -> [[String: Any]] {
        let queue = directory.appendingPathComponent("queue")
        return try FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil).map {
            try #require(JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any])
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for queue transition")
        throw NSError(domain: "PostHogEventsTests", code: 1)
    }
}

private final class SentBatches: @unchecked Sendable {
    private let lock = NSLock()
    private var batches = [([String], (PostHogUploadInfo) -> Void)]()
    var count: Int { lock.withLock { batches.count } }
    func append(_ events: [PostHogCapturedEvent], _ completion: @escaping (PostHogUploadInfo) -> Void) {
        lock.withLock { batches.append((events.map { $0.uuid.uuidString }, completion)) }
    }
    func uuids(_ index: Int) -> [String] { lock.withLock { batches[index].0 } }
    func complete(_ index: Int, status: Int) {
        complete(index, result: PostHogUploadInfo(statusCode: status, error: nil))
    }
    func complete(_ index: Int, result: PostHogUploadInfo) {
        let completion = lock.withLock { batches[index].1 }
        completion(result)
    }
}
