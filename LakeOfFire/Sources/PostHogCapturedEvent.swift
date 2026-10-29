import Foundation

/// The capture wire/storage envelope. This value has no SDK callback, replay,
/// routing-token, or known-event responsibilities. Properties are frozen by a
/// JSON roundtrip before admission to the durable queue.
struct PostHogCapturedEvent {
    let event: String
    let distinctId: String
    let properties: [String: Any]
    let timestamp: Date
    let uuid: UUID

    init(event: String, distinctId: String, properties: [String: Any] = [:],
         timestamp: Date = Date(), uuid: UUID = UUID.v7()) {
        self.event = event
        self.distinctId = distinctId
        self.properties = properties
        self.timestamp = timestamp
        self.uuid = uuid
    }

    static func fromJSON(_ data: Data) -> PostHogCapturedEvent? {
        // Every record written by this fork contains these fields. Reject a
        // damaged envelope instead of inventing a new ID/time on each retry.
        guard let json = fromJSONData(data),
              let event = json["event"] as? String, !event.isEmpty, event.count <= 200, !event.hasPrefix("$"),
              let distinctId = json["distinct_id"] as? String, !distinctId.isEmpty,
              let properties = json["properties"] as? [String: Any],
              let timestamp = json["timestamp"] as? String, let date = toISO8601Date(timestamp),
              let id = json["uuid"] as? String, let uuid = UUID(uuidString: id) else { return nil }
        return PostHogCapturedEvent(event: event, distinctId: distinctId, properties: properties,
                                   timestamp: date, uuid: uuid)
    }

    func toJSON() -> [String: Any] {
        ["event": event, "distinct_id": distinctId, "properties": properties,
         "timestamp": toISO8601String(timestamp), "uuid": uuid.postHogUuidString]
    }
}
