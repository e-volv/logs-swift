import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// One line per condition, not one per evaluation — and on stderr, where
/// the conformance driver reads SDK diagnostics (Darwin's os.log would be
/// invisible to it).
final class FlagLog {
    private let lock = NSLock()
    private var seen = Set<String>()

    func once(_ id: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard seen.insert(id).inserted else { return }
        FileHandle.standardError.write(Data("e-volv flags: \(message)\n".utf8))
    }
}

/// Client values delivery over the Observer's URLSession: one fitted
/// `GET /bootstrap?context=…` per refresh, coalesced; a poll loop at
/// `pollIntervalSeconds`; the §2.6 status policy (401/404 and the
/// recognised origin/app-id 403 pause 5 minutes, any other 403 is an
/// outage that keeps polling, scope refusal disables, 429 honours
/// Retry-After). Client SDKs never stream (contract §2.3).
actor ClientFlagsDelivery {
    private let baseURL: URL
    private let key: String
    private let appID: String
    private let installID: String
    private let userAgent: String
    private let session: URLSession
    private let pollIntervalNanos: UInt64
    private let offline: Bool
    private let contextJSON: @Sendable () -> String
    private let onPayload: @Sendable ([String: Any]) -> Void
    private let log: FlagLog

    private var closed = false
    private var disabled = false
    private var pollTask: Task<Void, Never>?
    private var inflight: Task<Void, Never>?
    private var pausedUntil = Date.distantPast
    private var lastFetchAttempt: Date?

    /// A 401/404/403-app-id refusal backs off this long before asking again.
    private static let authRetrySeconds: TimeInterval = 300

    init?(
        observerUrl: String?,
        flagsUrl: String?,
        key: String,
        appID: String,
        installID: String,
        userAgent: String,
        session: URLSession,
        pollInterval: Double,
        offline: Bool,
        contextJSON: @escaping @Sendable () -> String,
        onPayload: @escaping @Sendable ([String: Any]) -> Void,
        log: FlagLog
    ) {
        guard let url = ClientFlagsDelivery.baseURL(flagsUrl: flagsUrl, observerUrl: observerUrl) else {
            return nil
        }
        baseURL = url
        self.key = key
        self.appID = appID
        self.installID = installID
        self.userAgent = userAgent
        self.session = session
        pollIntervalNanos = UInt64(max(0.05, pollInterval) * 1_000_000_000)
        self.offline = offline
        self.contextJSON = contextJSON
        self.onPayload = onPayload
        self.log = log
    }

    /// flags.url wins; else the origin of the Observer url plus the flags
    /// path; else production (docs/LAUNCH-SDK.md §2).
    static func baseURL(flagsUrl: String?, observerUrl: String?) -> URL? {
        if let flagsUrl, let url = URL(string: flagsUrl) { return url }
        if let observerUrl, let components = URLComponents(string: observerUrl),
           let scheme = components.scheme, let host = components.host {
            var origin = URLComponents()
            origin.scheme = scheme
            origin.host = host
            origin.port = components.port
            origin.path = "/api/public/v1/flags"
            return origin.url
        }
        return URL(string: "https://api.e-volv.io/api/public/v1/flags")
    }

    /// First fetch immediately, then every poll interval. Offline mode
    /// never contacts the control plane.
    func start() {
        guard !offline, !closed, !disabled else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(nanoseconds: self.pollIntervalNanos)
            }
        }
    }

    /// Coalesced refresh: one request in flight at a time, and a refusal
    /// (scope, app id) disables further attempts until re-init. Only the
    /// task's creator clears `inflight` (the actor serializes callers), so
    /// no identity comparison is needed.
    func refresh() async {
        guard !closed, !disabled, !offline else { return }
        if let inflight {
            await inflight.value
            return
        }
        let task = Task { await self.doRefresh() }
        inflight = task
        await task.value
        inflight = nil
    }

    /// A context change (identify): always ends with a fetch for the
    /// current context. Waits out an in-flight refresh first — two requests,
    /// never interleaved, newest context last.
    func refreshNow() async {
        guard !closed, !disabled, !offline else { return }
        if let inflight {
            await inflight.value
        }
        guard !closed, !disabled, !offline else { return }
        let task = Task { await self.doRefresh() }
        inflight = task
        await task.value
        inflight = nil
    }

    /// Lifecycle (foreground) entry: refresh only when the last fetch is
    /// older than 15 s, so a quick app switch costs nothing.
    func refreshIfStale() async {
        if let lastFetchAttempt, Date().timeIntervalSince(lastFetchAttempt) < 15 { return }
        await refresh()
    }

    func close() {
        closed = true
        pollTask?.cancel()
        pollTask = nil
        inflight?.cancel()
        inflight = nil
    }

    // MARK: - internals

    private func doRefresh() async {
        guard !closed, !disabled, !offline, Date() >= pausedUntil else { return }
        lastFetchAttempt = Date()

        var components = URLComponents(
            url: baseURL.appendingPathComponent("bootstrap"),
            resolvingAgainstBaseURL: false
        )!
        // encodeURIComponent-minus-punctuation: nothing structural (+, &, =,
        // quotes, spaces) ever passes through unescaped.
        let encoded = contextJSON().addingPercentEncoding(
            withAllowedCharacters: ClientFlagsDelivery.queryCharacterSet
        )!
        components.percentEncodedQueryItems = [URLQueryItem(name: "context", value: encoded)]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(appID, forHTTPHeaderField: "x-evolve-app-id")
        request.setValue(installID, forHTTPHeaderField: "x-evolve-install-id")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let status: Int
        let data: Data
        let retryAfter: String?
        do {
            let response: URLResponse
            (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            status = http?.statusCode ?? 0
            retryAfter = http?.value(forHTTPHeaderField: "Retry-After")
        } catch {
            guard !closed else { return }
            log.once("outage", "control plane unreachable, serving last known values")
            return
        }
        guard !closed else { return }

        switch status {
        case 200:
            do {
                let body = try JSONSerialization.jsonObject(with: data)
                guard let dict = body as? [String: Any] else { return }
                onPayload(dict)
            } catch {
                log.once("outage", "control plane returned an unreadable body, serving last known values")
            }
        case 403:
            let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            if text.contains("lacks the scope") {
                disabled = true
                pollTask?.cancel()
                pollTask = nil
                log.once(
                    "scope",
                    "this key lacks the scope flags:read — flags are off, telemetry is unaffected"
                )
            } else if text.contains("origin") || text.contains("app id") {
                log.once(
                    "origin",
                    "this client key is not allowed from here — add this origin or app id under the environment's Access action"
                )
                pausedUntil = Date().addingTimeInterval(Self.authRetrySeconds)
            } else {
                // An unrecognised 403 is an outage, not a refusal: say so
                // once and keep the normal poll (matches @e-volv/flags-client).
                log.once("outage", "control plane returned 403, serving last known values")
            }
        case 401, 404:
            log.once(
                "auth",
                "the control plane refused this key (\(status)); serving last known values and retrying every 5 minutes"
            )
            pausedUntil = Date().addingTimeInterval(Self.authRetrySeconds)
        case 429:
            let seconds = Double(retryAfter ?? "") ?? 30
            pausedUntil = Date().addingTimeInterval(max(0, seconds))
        default:
            log.once("outage", "control plane returned \(status), serving last known values")
        }
    }

    private static let queryCharacterSet: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return set
    }()
}
