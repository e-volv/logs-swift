import Foundation

/// Parses W3C traceparent headers and computes the "next hop" context for a
/// consumer that receives a traceparent (queue consumer, inbound request).
enum Traceparent {
    /// `00-<traceId>-<spanId>-01` of the trace in the task-local context,
    /// or "" outside a trace.
    static func current() -> String {
        Traces.current?.traceparent ?? ""
    }

    /// The context for the next hop of the trace named by a traceparent
    /// header — the consumer side of a queue, the callee side of an HTTP
    /// request. Same trace id, new span id, the header's span id as parent.
    /// A malformed or absent header starts a fresh root trace, so a producer
    /// that sends nothing still yields a trace of its own.
    static func hop(from header: String) -> TraceContext {
        Traces.child(of: parse(header))
    }

    /// Parses a W3C traceparent header, returning nil when it is absent,
    /// malformed, or carries all-zero ids.
    static func parse(_ header: String) -> TraceContext? {
        let parts = header.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0] == "00",
              parts[1].count == 32, parts[1].allSatisfy({ $0.isHexDigit }),
              parts[2].count == 16, parts[2].allSatisfy({ $0.isHexDigit })
        else { return nil }
        let traceID = String(parts[1])
        let spanID = String(parts[2])
        guard !allZeros(traceID), !allZeros(spanID) else { return nil }
        return TraceContext(traceID: traceID, spanID: spanID, parentSpanID: "")
    }

    private static func allZeros(_ hex: String) -> Bool {
        hex.allSatisfy { $0 == "0" }
    }
}
