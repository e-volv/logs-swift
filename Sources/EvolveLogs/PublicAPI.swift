import Foundation

/// Entry point: `EvolveLogs.initialize(options)` installs the shared client
/// that the `Logs` namespace delegates to. Call it from
/// `UIApplicationDelegate.application(_:didFinishLaunchingWithOptions:)` (or
/// your SwiftUI app's `.init`) before any `Logs` call.
public enum EvolveLogs {
    nonisolated(unsafe) private static var shared: LogsClient?

    /// Installs the package-level client built from options and returns it.
    /// A later call replaces the previous default; the old client keeps its
    /// disk queue, so call its `shutdown()` when retiring it.
    @discardableResult
    public static func initialize(_ options: EvolveLogsOptions) -> LogsClient {
        let client = LogsClient(options: options)
        shared = client
        return client
    }

    /// The client installed by `initialize`, or nil before it.
    public static func client() -> LogsClient? {
        shared
    }

    /// The Launch flags client of the installed client. Before
    /// `initialize` (or with flags disabled in options) this is a disabled
    /// instance: reads return defaults and no network or disk I/O happens.
    public static var flags: Flags {
        shared?.flags ?? Flags.disabled()
    }
}

/// The logging surface — one enum of statics, matching the Node, Python and
/// Go SDKs. Everything is fail-silent: before `initialize` (or with a
/// refused key) the calls are no-ops.
public enum Logs {
    private static func current() -> LogsClient? { EvolveLogs.client() }

    // MARK: levels (OTel severities: trace 1, debug 5, info 9, warn 13,
    // error 17, fatal 21)

    public static func trace(_ message: String, attrs: [String: Any] = [:]) {
        current()?.log(severity: Constants.otelTrace, message: message, attrs: attrs)
    }

    public static func debug(_ message: String, attrs: [String: Any] = [:]) {
        current()?.log(severity: Constants.otelDebug, message: message, attrs: attrs)
    }

    public static func info(_ message: String, attrs: [String: Any] = [:]) {
        current()?.log(severity: Constants.otelInfo, message: message, attrs: attrs)
    }

    public static func warn(_ message: String, attrs: [String: Any] = [:]) {
        current()?.log(severity: Constants.otelWarn, message: message, attrs: attrs)
    }

    public static func error(_ message: String, attrs: [String: Any] = [:]) {
        current()?.log(severity: Constants.otelError, message: message, attrs: attrs)
    }

    public static func fatal(_ message: String, attrs: [String: Any] = [:]) {
        current()?.log(severity: Constants.otelFatal, message: message, attrs: attrs)
    }

    // MARK: errors and spans

    /// Logs error as an error occurrence: severity 17 with
    /// exception.type / exception.message / exception.stack.
    public static func exception(_ error: Error, attrs: [String: Any] = [:]) {
        current()?.exception(error, attrs: attrs)
    }

    /// Runs body inside a span; a thrown error ends the span as failed and
    /// is rethrown.
    public static func span<T>(
        _ name: String,
        attrs: [String: Any] = [:],
        _ body: () throws -> T
    ) rethrows -> T {
        guard let client = current() else { return try body() }
        return try client.span(name, attrs: attrs, body)
    }

    // MARK: trace context

    /// The W3C traceparent of the current task-local trace, or "".
    public static func traceparent() -> String {
        current()?.traceparent() ?? ""
    }

    /// Continues an inbound traceparent (queue consumer, inbound request):
    /// everything logged inside body joins the caller's trace. A malformed
    /// header starts a fresh trace.
    public static func runWithTraceparent<T>(_ header: String, _ body: () throws -> T) rethrows -> T {
        guard let client = current() else { return try body() }
        return try client.runWithTraceparent(header, body)
    }

    /// Sends what is pending. Safe to call repeatedly; never throws.
    public static func flush() {
        current()?.flush()
    }
}
