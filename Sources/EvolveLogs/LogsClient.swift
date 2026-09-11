import Foundation
#if canImport(EvolveLogsC)
    import EvolveLogsC
#endif
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The e-volv Observer client for iOS (and macOS). Batches events
/// (200 / 2 s / 512 KB), gzips the payload, redacts sensitive attribute
/// keys before enqueue, retries 429 honouring Retry-After and 413 by
/// halving, and buffers on a disk queue that survives process death — a
/// fatal crash lands on disk inside the signal handler and is sent on the
/// next launch. Everything is fail-silent: a logging SDK never throws into
/// user code.
public final class LogsClient {
    // --- identity --------------------------------------------------------
    let key: String
    let url: URL
    let service: String
    let environment: String
    let release: String
    let sampleRate: Double
    let appID: String
    let installID: String
    let redactMatches: (String) -> Bool
    let enabled: Bool

    // --- mobile transport -------------------------------------------------
    let queue: DiskQueue
    let transport: Transport?

    // --- session model ----------------------------------------------------
    private(set) var sessionID = ""
    private var sessionState = "background"
    private let sessionEventsEnabled: Bool
    private let sessionIDStampingEnabled: Bool

    // --- counters & buffers -------------------------------------------------
    private let lock = NSLock()
    private let flushLock = NSLock()
    private var dropped = 0
    private var memoryCount = 0
    private var memoryBytes = 0
    private var breadcrumbRing: [[String: Any]] = []
    private var flushTimer: DispatchSourceTimer?

    // --- hooks (installed once) ----------------------------------------------
    private let crashCatcher = CrashCatcher()
    #if os(iOS)
        private var lifecycle: LifecycleObserver?
    #endif

    /// Events dropped: evicted past the in-memory buffer cap (2× batch,
    /// oldest first), halved away by 413, or corrupt/oversized on disk.
    public var droppedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    public init(options: EvolveLogsOptions) {
        key = options.key
        service = options.service
        environment = options.environment
        release = options.release
        sampleRate = options.sampleRate > 0 ? options.sampleRate : 1
        redactMatches = Redactor.makeMatcher(extraKeys: options.redactKeys)
        sessionEventsEnabled = options.enableSessionEvents
        sessionIDStampingEnabled = options.enableSessionID

        // Key kind gate: a server key (evk_…) must never ship in a binary.
        // The conformance fixture key is a server-shaped test key; the
        // runner opts in explicitly with allowServerKeyForTesting — apps
        // cannot, and the default path refuses evk_ non-pub keys.
        let keyOK = options.key.hasPrefix("evk_pub_")
            || (options.allowServerKeyForTesting && options.key.hasPrefix("evk_"))
        let parsedURL = URL(string: options.url)
        url = parsedURL ?? URL(string: "invalid://")!
        enabled = keyOK && !options.key.isEmpty && parsedURL != nil

        if options.key.hasPrefix("evk_"), !options.key.hasPrefix("evk_pub_"), !keyOK {
            Diag.error("Refusing server ingest key (evk_…) in a mobile client — mint a public key (evk_pub_…) on the project's page.")
        } else if !enabled {
            Diag.warn("Init without a valid key and URL — the client is a no-op.")
        }

        // x-evolve-app-id defaults to the bundle id; x-evolve-install-id is
        // generated once per install and persisted (UserDefaults on iOS, the
        // app-support directory on macOS).
        appID = options.appID.isEmpty ? EvolveLogsOptions.defaultAppID() : options.appID
        let store = options.installIDStore ?? InstallIDStorePlatformDefault.make()
        installID = InstallIDs.resolve(using: store)

        // The disk queue survives process death; reads happen here, at
        // launch, before new events are appended.
        let queueDir = options.queueDirectory ?? DiskQueueDirectory.default()
        queue = (try? DiskQueue(directory: queueDir, byteCap: options.queueByteCap))
            ?? (try! DiskQueue(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("evolve-logs-\(UUID().uuidString)")))

        let session = options.session ?? URLSession(configuration: .ephemeral)
        transport = enabled
            ? Transport(url: url, key: key, appID: appID, installID: installID, session: session)
            : nil

        // Session model: one id per app foreground epoch, an app-start
        // marker, foreground/background transitions as events.
        beginSession(state: "foreground", marker: "app.start")
        refreshCrashBuffer()

        if options.captureCrashes {
            crashCatcher.install(client: self)
        }
        if options.urlSessionInstrumentation {
            URLSessionIntegration.enable()
        }
        #if os(iOS)
            lifecycle = LifecycleObserver(client: self)
        #endif

        startFlushTimer()
    }

    // MARK: - session model

    /// Starts a new session epoch (a fresh UUID) and emits its marker event
    /// (unless session events are disabled — the conformance runner).
    func beginSession(state: String, marker: String) {
        lock.lock()
        sessionID = UUID().uuidString
        sessionState = state
        lock.unlock()
        guard sessionEventsEnabled else { return }
        enqueue(
            severity: Constants.otelInfo,
            message: marker,
            attrs: ["session.event": marker, "app.state": state]
        )
    }

    /// Ends the current epoch with a background marker (iOS lifecycle).
    func endSession(marker: String) {
        lock.lock()
        sessionState = "background"
        let id = sessionID
        lock.unlock()
        guard sessionEventsEnabled else { return }
        enqueue(
            severity: Constants.otelInfo,
            message: marker,
            attrs: ["session.event": marker, "app.state": "background", "session.ended": id]
        )
    }

    // MARK: - logging

    /// Enqueues an event at the given OTel severity number.
    public func log(severity: Int, message: String, attrs: [String: Any] = [:]) {
        enqueue(severity: severity, message: message, attrs: attrs)
    }

    /// Logs err as an error event: severity 17, message
    /// err.localizedDescription, and exception.type / exception.message /
    /// exception.stack attributes — an error occurrence with a stack on the
    /// group page.
    public func exception(_ error: Error, attrs: [String: Any] = [:]) {
        let typeName: String
        if Swift.type(of: error) is NSError.Type {
            typeName = (error as NSError).domain // ObjC / Cocoa error
        } else {
            typeName = String(reflecting: Swift.type(of: error))
                .components(separatedBy: ".").last ?? "Error"
        }
        var merged = attrs
        merged["exception.type"] = typeName
        merged["exception.message"] = error.localizedDescription
        merged["exception.stack"] = Thread.callStackSymbols.joined(separator: "\n")
        enqueue(severity: Constants.otelError, message: error.localizedDescription, attrs: merged)
    }

    /// Starts a span. The rethrowing closure form ends the span when the
    /// closure returns or throws — a thrown error ends it as failed and is
    /// rethrown, so the caller's control flow is unchanged.
    public func span<T>(
        _ name: String,
        attrs: [String: Any] = [:],
        _ body: () throws -> T
    ) rethrows -> T {
        let handle = startSpan(name, attrs: attrs)
        do {
            let result = try body()
            handle.end()
            return result
        } catch {
            handle.end(error)
            throw error
        }
    }

    /// Starts a span and returns its handle; pair with `end()`/`end(error)`.
    public func startSpan(_ name: String, attrs: [String: Any] = [:]) -> Span {
        let context = Traces.child(of: Traces.current)
        return Span(client: self, name: name, attrs: attrs, context: context, start: Date())
    }

    // MARK: - trace context

    /// The W3C traceparent (`00-<traceId>-<spanId>-01`) of the trace in the
    /// current task-local context, or "" outside a trace.
    public func traceparent() -> String {
        Traceparent.current()
    }

    /// Runs `body` with the next hop of the trace named by a W3C traceparent
    /// header — the consumer side of a queue, the callee side of an inbound
    /// request. An absent or malformed header starts a fresh trace.
    public func runWithTraceparent<T>(_ header: String, _ body: () throws -> T) rethrows -> T {
        try Traces.$current.withValue(Traceparent.hop(from: header)) {
            try body()
        }
    }

    // MARK: - batching

    /// Redacts, stamps and buffers one event: appended to the disk queue
    /// immediately (survives process death) and accounted in memory for the
    /// batching thresholds and the breadcrumb ring.
    func enqueue(severity: Int, message: String, attrs: [String: Any], explicitContext: TraceContext? = nil) {
        guard enabled else { return }
        if sampleRate < 1, Double.random(in: 0 ..< 1) > sampleRate {
            return
        }

        let context = explicitContext ?? Traces.current
        var stamped = Redactor.redact(attrs, matches: redactMatches)
        stamped["service.name"] = service
        if !environment.isEmpty { stamped["deployment.environment"] = environment }
        if !release.isEmpty { stamped["service.release"] = release }
        if sessionIDStampingEnabled {
            lock.lock()
            stamped["session.id"] = sessionID
            lock.unlock()
        }

        var event = LogEvent(
            ts: Clock.iso8601(),
            severity: severity,
            message: message,
            attrs: stamped,
            traceID: context?.traceID ?? "",
            spanID: context?.spanID ?? "",
            parentSpanID: context?.parentSpanID ?? ""
        )
        guard let wire = event.wireJSON() else { return }
        event.size = wire.count

        lock.lock()
        breadcrumbRing.append([
            "ts": event.ts,
            "severity": event.severity,
            "message": event.message,
        ])
        if breadcrumbRing.count > Constants.breadcrumbCount {
            breadcrumbRing.removeFirst(breadcrumbRing.count - Constants.breadcrumbCount)
        }
        memoryCount += 1
        memoryBytes += event.size
        let shouldFlush = memoryCount >= Constants.maxBatch || memoryBytes >= Constants.maxPayloadBytes
        lock.unlock()

        // The disk queue is the real buffer: oldest files drop past 2× the
        // batch size or the byte cap, counted on the visible counter.
        let evicted = queue.append(wire)
        if evicted > 0 {
            lock.lock(); dropped += evicted; lock.unlock()
        }
        if shouldFlush { flush() }
    }

    // MARK: - flush

    /// Sends what is pending, oldest first, in 200-event / 512 KB batches;
    /// loops until the queue drains or a batch fails. A failed batch stays
    /// on disk for the next flush (or the next launch) — on a hostile
    /// mobile network, delivery backs off rather than dropping. Never
    /// throws.
    public func flush() {
        guard enabled, let transport else { return }
        flushLock.lock()
        defer { flushLock.unlock() }

        // In-memory accounting resets with the disk queue it mirrors.
        lock.lock()
        memoryCount = 0
        memoryBytes = 0
        lock.unlock()
        refreshCrashBuffer()

        while true {
            var batchDropped = 0
            let files = queue.peek(
                maxEvents: Constants.maxBatch,
                maxBytes: Constants.maxPayloadBytes
            ) { batchDropped += $0 }
            if batchDropped > 0 {
                lock.lock(); dropped += batchDropped; lock.unlock()
            }
            guard !files.isEmpty else { return }

            var pending = files
            var body = envelope(pending)
            var attempt = 0
            var delivered = false
            while !delivered {
                let result = transport.send(body)
                if (200 ..< 300).contains(result.status) {
                    queue.remove(pending.map(\.name))
                    delivered = true
                    continue
                }
                if result.status == 429, attempt < Constants.maxAttempts - 1 {
                    // Throttling is about rate, not size: keep the batch
                    // whole, honour Retry-After, else exponential backoff.
                    attempt += 1
                    sleepNanoseconds(Backoff.delay(attempt: attempt, retryAfter: result.retryAfter))
                    continue
                }
                if result.status == 413, pending.count > 1 {
                    // Halve the batch; the excess half drops — visible on
                    // droppedCount and removed from the queue — and the
                    // oldest half is retried at once (matching Go).
                    let half = (pending.count + 1) / 2
                    let evicted = Array(pending.suffix(pending.count - half))
                    queue.remove(evicted.map(\.name))
                    lock.lock(); dropped += pending.count - half; lock.unlock()
                    pending = Array(pending.prefix(half))
                    body = envelope(pending)
                    continue
                }
                if result.status == 0, attempt < Constants.maxAttempts - 1 {
                    // Transport error: exponential backoff, then give up
                    // and leave the batch on disk.
                    attempt += 1
                    sleepNanoseconds(Backoff.delay(attempt: attempt, retryAfter: nil))
                    continue
                }
                // Other statuses and exhausted retries: the batch stays on
                // disk for the next flush or the next launch.
                Diag.warn("flush: batch of \(pending.count) event(s) not delivered (status \(result.status)); kept on disk.")
                return
            }
        }
    }

    private func envelope(_ files: [(name: String, data: Data)]) -> Data {
        let objs = files.compactMap { (try? JSONSerialization.jsonObject(with: $0.data)) as? [String: Any] }
        guard JSONSerialization.isValidJSONObject(["events": objs]),
              let data = try? JSONSerialization.data(
                  withJSONObject: ["events": objs],
                  options: [.sortedKeys, .withoutEscapingSlashes]
              )
        else { return Data() }
        return data
    }

    // MARK: - crash support (internal)

    /// Refreshes the pre-serialized crash event prefix/suffix for the
    /// async-signal-safe write path: current session id, breadcrumbs and
    /// service attrs are baked in, so the handler itself formats only the
    /// exception fields. Called at init and after every flush, so the
    /// stamped timestamp is never more than one flush interval old.
    func refreshCrashBuffer() {
        guard enabled else { return }
        lock.lock()
        let crumbs: [[String: Any]] = breadcrumbRing.map { crumb in
            [
                "ts": crumb["ts"] ?? "",
                "severity": crumb["severity"] ?? 0,
                "message": crumb["message"] ?? "",
            ]
        }
        let sid = sessionID
        lock.unlock()

        var attrs: [String: Any] = [
            "span.name": "app.crash",
            "crash": true,
            "breadcrumbs": crumbs,
            "session.id": sid,
            "service.name": service,
        ]
        if !environment.isEmpty { attrs["deployment.environment"] = environment }
        if !release.isEmpty { attrs["service.release"] = release }

        // The attrs object stays OPEN in the prefix (its closing brace is
        // stripped): the crash-time middle contributes exception.type and
        // exception.message, the suffix adds a static exception.stack and
        // closes attrs and event. The file is a SINGLE EVENT (like every
        // other queue file) — the queue reader wraps it in the batch
        // envelope like any other event.
        var attrsJSON = try? JSONSerialization.data(
            withJSONObject: attrs,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard attrsJSON?.last == UInt8(ascii: "}") else { return }
        attrsJSON?.removeLast()

        // Layout: {"ts":…,"severity":21,"message":"app crash","attrs":{…attrs…,
        // | middle: "exception.type":…,"exception.message":…, |
        // "exception.stack":"" }}
        var prefix = Data("{\"ts\":\"".utf8)
        prefix.append(Data(Clock.iso8601().utf8))
        prefix.append(Data("\",\"severity\":21,\"message\":\"app crash\",\"attrs\":".utf8))
        prefix.append(attrsJSON!)
        prefix.append(Data(",".utf8))
        let suffix = Data("\"exception.stack\":\"\"}}".utf8)

        evolve_crash_buffer_init()
        _ = prefix.withUnsafeBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            return evolve_crash_buffer_set_prefix(base.assumingMemoryBound(to: CChar.self), prefix.count)
        }
        _ = suffix.withUnsafeBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            return evolve_crash_buffer_set_suffix(base.assumingMemoryBound(to: CChar.self), suffix.count)
        }
        _ = queue.crashPendingPath().path.withCString { evolve_crash_buffer_set_path($0) }
    }

    // MARK: - lifecycle

    private func startFlushTimer() {
        guard enabled else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "io.e-volv.logs.flush"))
        timer.schedule(
            deadline: .now() + .nanoseconds(Constants.flushIntervalNanoseconds),
            repeating: .nanoseconds(Constants.flushIntervalNanoseconds)
        )
        timer.setEventHandler { [weak self] in
            self?.flush()
        }
        timer.resume()
        flushTimer = timer
    }

    /// Stops the flush timer, removes the crash handlers (chaining to the
    /// previously installed ones) and flushes what is pending.
    public func shutdown() {
        flushTimer?.cancel()
        flushTimer = nil
        crashCatcher.uninstall()
        flush()
    }
}

enum DiskQueueDirectory {
    static func `default`() -> URL {
        #if os(iOS)
            return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("evolve-logs", isDirectory: true)
        #else
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return base.appendingPathComponent("evolve-logs", isDirectory: true)
        #endif
    }
}

enum InstallIDStorePlatformDefault {
    static func make() -> InstallIDStoring {
        #if os(iOS)
            return UserDefaultsInstallIDStore()
        #else
            let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("evolve-install-id")
            return FileInstallIDStore(url: url)
        #endif
    }
}
