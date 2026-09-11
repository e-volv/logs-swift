import Foundation

/// A handle to a started span. `end()` is idempotent. The span end is
/// recorded as an event with `span.name` and `durationMs` attributes — the
/// ingest turns it into a span row, which is how `span()` reaches the
/// trace graph without OTLP. The span's trace and span ids ride on the
/// event, with parent linkage to the span it was created under.
public final class Span {
    private let client: LogsClient
    let name: String
    private let attrs: [String: Any]
    let context: TraceContext
    private let start: Date
    private var ended = false
    private let endLock = NSLock()

    init(client: LogsClient, name: String, attrs: [String: Any], context: TraceContext, start: Date) {
        self.client = client
        self.name = name
        self.attrs = attrs
        self.context = context
        self.start = start
    }

    /// The span's identity.
    public var traceID: String { context.traceID }
    public var spanID: String { context.spanID }

    /// Records the span end. A nil error records "span <name> completed" at
    /// severity 9; a non-nil error records "span <name> failed" at severity
    /// 17 with exception.type and exception.message attributes.
    public func end(_ error: Error? = nil) {
        endLock.lock()
        guard !ended else { endLock.unlock(); return }
        ended = true
        endLock.unlock()

        var spanAttrs = attrs
        spanAttrs["span.name"] = name
        spanAttrs["durationMs"] = Int(Date().timeIntervalSince(start) * 1000)
        if let error {
            if Swift.type(of: error) is NSError.Type {
                spanAttrs["exception.type"] = (error as NSError).domain
            } else {
                spanAttrs["exception.type"] = String(reflecting: Swift.type(of: error))
                    .components(separatedBy: ".").last ?? "Error"
            }
            spanAttrs["exception.message"] = error.localizedDescription
            client.enqueue(
                severity: Constants.otelError,
                message: "span \(name) failed",
                attrs: spanAttrs,
                explicitContext: context
            )
            return
        }
        client.enqueue(
            severity: Constants.otelInfo,
            message: "span \(name) completed",
            attrs: spanAttrs,
            explicitContext: context
        )
    }
}
