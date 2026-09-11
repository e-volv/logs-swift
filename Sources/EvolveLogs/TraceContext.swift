import Foundation

/// One position in a trace. Carried on a `@TaskLocal` (Traces.current) so it
/// flows across `await` and into child tasks — the Swift analogue of the Node
/// SDK's AsyncLocalStorage and the Python SDK's contextvars.
struct TraceContext {
    let traceID: String // 32 lowercase hex
    let spanID: String // 16 lowercase hex
    let parentSpanID: String // 16 lowercase hex, empty at a trace root

    var traceparent: String {
        "00-\(traceID)-\(spanID)-01"
    }
}

enum Traces {
    @TaskLocal
    static var current: TraceContext?

    /// New root trace.
    static func root() -> TraceContext {
        TraceContext(traceID: HexID.make(16), spanID: HexID.make(8), parentSpanID: "")
    }

    /// Next hop of `parent` — same trace id, new span id, parent's span id as
    /// parent. A nil parent starts a fresh root trace.
    static func child(of parent: TraceContext?) -> TraceContext {
        guard let parent else { return root() }
        return TraceContext(traceID: parent.traceID, spanID: HexID.make(8), parentSpanID: parent.spanID)
    }
}

/// Lowercase-hex random ids (32 hex = trace id, 16 = span). SystemRandom is a
/// CSPRNG; byte-by-byte formatting keeps the code trivially correct and is
/// not on the hot path.
enum HexID {
    static func make(_ byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        var out = String()
        out.reserveCapacity(byteCount * 2)
        for _ in 0 ..< byteCount {
            out.append(String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)))
        }
        return out
    }
}
