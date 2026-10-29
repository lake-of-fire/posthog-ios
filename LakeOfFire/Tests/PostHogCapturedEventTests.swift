import Foundation
import Testing
@testable import PostHogEvents

struct PostHogCapturedEventTests {
    @Test func jsonRoundtripPreservesIDTimestampAndNestedProperties() throws {
        let id = UUID()
        let timestamp = try #require(toISO8601Date("2026-10-29T12:34:56.789Z"))
        let original = PostHogCapturedEvent(event: "opened", distinctId: "anonymous-id",
                                          properties: ["chapter": 3, "nested": ["items": ["a", "b"], "done": false], "empty": NSNull()],
                                          timestamp: timestamp, uuid: id)
        let data = try #require(toJSONData(original.toJSON()))
        let restored = try #require(PostHogCapturedEvent.fromJSON(data))
        #expect(restored.uuid == id)
        #expect(restored.timestamp == timestamp)
        #expect(restored.event == original.event)
        #expect(restored.distinctId == original.distinctId)
        #expect(NSDictionary(dictionary: restored.properties).isEqual(to: original.properties))
        #expect(restored.toJSON()["uuid"] as? String == id.uuidString.lowercased())
        #expect(restored.toJSON()["timestamp"] as? String == "2026-10-29T12:34:56.789Z")
    }

    @Test func restoresEnvelopeWrittenByPreviousForkWithEmptyProperties() throws {
        // The previous fork wrote this upstream-compatible envelope. Keeping
        // it readable avoids data migration or replacing its deduplication ID.
        let data = Data("""
        {"event":"opened","distinct_id":"anonymous-id","properties":{},
         "timestamp":"2026-10-29T12:34:56Z","uuid":"0199c3e8-4c7b-7e2e-9f21-2b6d5a1c9e04"}
        """.utf8)
        let event = try #require(PostHogCapturedEvent.fromJSON(data))
        #expect(event.properties.isEmpty)
        #expect(event.uuid.uuidString.lowercased() == "0199c3e8-4c7b-7e2e-9f21-2b6d5a1c9e04")
        #expect(event.timestamp == toISO8601Date("2026-10-29T12:34:56.000Z"))
        let encoded = try #require(toJSONData(event.toJSON()))
        let restored = try #require(PostHogCapturedEvent.fromJSON(encoded))
        #expect(restored.uuid == event.uuid)
        #expect(restored.timestamp == event.timestamp)
    }

    @Test func malformedStorageIsRejectedWithoutInventingIdentityOrTime() throws {
        for text in ["", "not JSON", "[]", "null", "{}"] {
            #expect(PostHogCapturedEvent.fromJSON(Data(text.utf8)) == nil)
        }
        let valid = PostHogCapturedEvent(event: "opened", distinctId: "anonymous-id").toJSON()
        for field in ["event", "distinct_id", "properties", "timestamp", "uuid"] {
            var missing = valid
            missing.removeValue(forKey: field)
            #expect(PostHogCapturedEvent.fromJSON(try #require(toJSONData(missing))) == nil)
            var wrongType = valid
            wrongType[field] = 42
            #expect(PostHogCapturedEvent.fromJSON(try #require(toJSONData(wrongType))) == nil)
        }
        for (field, value) in [("event", ""), ("event", "$snapshot"), ("distinct_id", ""),
                               ("timestamp", "invalid"), ("uuid", "invalid")] {
            var invalid = valid
            invalid[field] = value
            #expect(PostHogCapturedEvent.fromJSON(try #require(toJSONData(invalid))) == nil)
        }
    }
}
