import Foundation

/// The wire event (docs/OBSERVER-SDK.md §"Event shape"). `ts` is ISO 8601;
/// `severity` is the OTel number; attrs is a flat object with
/// `service.name` / `deployment.environment` / `service.release` stamped on
/// every event; the trace ids are W3C (32-hex trace, 16-hex span).
struct LogEvent {
    var ts: String
    var severity: Int
    var message: String
    var attrs: [String: Any]
    var traceID: String
    var spanID: String
    var parentSpanID: String

    /// Wire size, for buffer accounting only (never serialized).
    var size: Int = 0
}

extension LogEvent {
    /// Serializes to the JSON shape the ingest reads. Sorting keys keeps
    /// batches deterministic, which the byte accounting relies on.
    func wireJSON() -> Data? {
        var obj: [String: Any] = [
            "ts": ts,
            "severity": severity,
            "message": message,
            "attrs": attrs,
        ]
        if !traceID.isEmpty { obj["traceId"] = traceID }
        if !spanID.isEmpty { obj["spanId"] = spanID }
        if !parentSpanID.isEmpty { obj["parentSpanId"] = parentSpanID }
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(
                  withJSONObject: obj,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              )
        else { return nil }
        return data
    }

    /// Full batch envelope: { "events": [...] }.
    static func envelope(_ events: [LogEvent]) -> Data? {
        let objs = events.compactMap { e -> [String: Any]? in
            var o: [String: Any] = [
                "ts": e.ts,
                "severity": e.severity,
                "message": e.message,
                "attrs": e.attrs,
            ]
            if !e.traceID.isEmpty { o["traceId"] = e.traceID }
            if !e.spanID.isEmpty { o["spanId"] = e.spanID }
            if !e.parentSpanID.isEmpty { o["parentSpanId"] = e.parentSpanID }
            return JSONSerialization.isValidJSONObject(o) ? o : nil
        }
        guard JSONSerialization.isValidJSONObject(["events": objs]),
              let data = try? JSONSerialization.data(
                  withJSONObject: ["events": objs],
                  options: [.sortedKeys, .withoutEscapingSlashes]
              )
        else { return nil }
        return data
    }
}

enum Clock {
    /// RFC3339 with millisecond precision, e.g. 2026-09-06T14:00:00.123Z.
    static func iso8601(_ date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
        let millis = (c.nanosecond ?? 0) / 1_000_000
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, millis
        )
    }
}
