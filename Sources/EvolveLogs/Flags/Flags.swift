import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The install check answer (docs/LAUNCH-SDK.md §2.5).
public struct PingResult: Decodable {
    public let environment: String
    public let keyKind: String
    public let flags: Int
    public let etag: String
}

/// Handle for `onChange` subscriptions; `cancel()` stops the callbacks.
public final class FlagsSubscription {
    private let lock = NSLock()
    private var onCancel: (() -> Void)?
    private var cancelled = false

    init() {}

    /// Flags installs the remover here so `cancel()` can detach the
    /// listener (the subscription cannot reference itself before init).
    func setOnCancel(_ closure: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if cancelled {
            closure()
        } else {
            onCancel = closure
        }
    }

    public func cancel() {
        lock.lock()
        let action = onCancel
        onCancel = nil
        let already = cancelled
        cancelled = true
        lock.unlock()
        if !already { action?() }
    }
}

/// The e-volv Launch flags client for iOS and macOS (docs/LAUNCH-SDK.md,
/// client kind): one context, evaluated values fetched with a public key,
/// cached on device, refreshed on foreground. Reads are synchronous, never
/// throw and never do I/O; `ready` and `identify` are the only calls that
/// wait. Client SDKs poll — they never stream (contract §2.3).
public final class Flags: @unchecked Sendable {
    private final class Listener {
        weak var subscription: FlagsSubscription?
        let handler: ([String]) -> Void

        init(subscription: FlagsSubscription, handler: @escaping ([String]) -> Void) {
            self.subscription = subscription
            self.handler = handler
        }
    }

    /// Two-phase wiring between the delivery actor and Flags (see init).
    private final class CallbackBox {
        var contextJSON: () -> String = { "{}" }
        var onPayload: ([String: Any]) -> Void = { _ in }
    }

    private let lock = NSLock()
    private let log = FlagLog()
    private let key: String
    private let appID: String
    private let installID: String
    private let cache: ValuesCache?
    private let transport: Transport?
    // Internal rather than private so the tests can assert recording
    // behaviour (the exposure queue after typed reads).
    let exposures: ExposureRecorder
    private let delivery: ClientFlagsDelivery?
    private let baseURL: URL?
    private let session: URLSession?
    private let privateNames: [String]
    private let offlineMode: Bool
    private let structurallyDisabled: Bool

    // All guarded by `lock`.
    private var values: [String: Evaluation]?
    private var servedFingerprint: String?
    private var contextTree: JSONTree
    private var contextJSON: String
    private var contextFingerprint: String
    private var fetchedEnvironmentId: String?
    private var receivedFromNetwork = false
    private var updatedAt: Date?
    private var confirmedAt: Date?
    private var readyWaiters: [(id: Int, continuation: CheckedContinuation<Bool, Never>)] = []
    private var waiterSequence = 0
    private var listeners: [Listener] = []

    /// The flags handle for a disabled configuration: defaults only, no I/O.
    public static func disabled() -> Flags {
        Flags(structurallyDisabled: true)
    }

    private init(structurallyDisabled: Bool) {
        self.structurallyDisabled = structurallyDisabled
        key = ""
        appID = ""
        installID = ""
        cache = nil
        transport = nil
        session = nil
        baseURL = nil
        privateNames = []
        offlineMode = true
        delivery = nil
        exposures = ExposureRecorder(
            enabled: false,
            sampleRate: 1,
            dedupeWindowSeconds: 300,
            sendAttributes: false,
            privateAttributes: []
        )
        contextTree = .object([])
        contextJSON = "{}"
        contextFingerprint = ContextFit.fingerprint(JSONTree.object([]))
    }

    init(
        key: String,
        appID: String,
        installID: String,
        observerUrl: String?,
        options: FlagsOptions,
        session: URLSession,
        queueDirectory: URL,
        transport: Transport?,
        enabled: Bool
    ) {
        self.key = key
        self.appID = appID
        self.installID = installID
        offlineMode = options.offline
        structurallyDisabled = !enabled || !options.enabled
        privateNames = options.privateAttributes
        cache = structurallyDisabled
            ? nil
            : ValuesCache(queueDirectory: queueDirectory, explicit: options.cacheDirectory, enabled: options.cacheEnabled)
        self.transport = structurallyDisabled ? nil : transport
        self.session = structurallyDisabled ? nil : session
        baseURL = structurallyDisabled
            ? nil
            : ClientFlagsDelivery.baseURL(flagsUrl: options.url, observerUrl: observerUrl)
        exposures = ExposureRecorder(
            enabled: options.exposuresEnabled,
            sampleRate: min(1, max(0, options.exposureSampleRate)),
            dedupeWindowSeconds: options.exposureDedupeWindowSeconds,
            sendAttributes: options.sendAttributes,
            privateAttributes: options.privateAttributes
        )

        // Fit and hold the initial context. A plain dictionary is sorted so
        // the output is deterministic; KeyValuePairs/ordered arrays keep the
        // caller's order (see identify).
        let fitted = ContextFit.fit(Flags.orderedPairs(options.initialContext))
        if fitted.trimmed { log.once("trimmed", "context exceeded 4096 characters — dropped attributes (largest first) to fit") }
        let stripped = Flags.stripPrivate(
            JSONTree.object(fitted.context.map { ($0.0, JSONTree($0.1)) }),
            options.privateAttributes
        )
        contextTree = stripped
        contextJSON = ContextFit.render(stripped)
        contextFingerprint = ContextFit.fingerprint(stripped)

        if let bootstrap = options.bootstrap {
            values = bootstrap
            updatedAt = Date()
        } else if let cached = cache?.read(key: key) {
            // §6: a cache for a different fingerprint may be served only
            // until the first fetch for the new context completes — serving
            // it at cold start is exactly the L5 behaviour.
            values = cached.flags
            servedFingerprint = cached.fingerprint
            updatedAt = cached.savedAt
        }

        let poll = options.unclampedPollInterval ?? max(15, options.pollIntervalSeconds)
        // The delivery's callbacks wire through a box: its initializer
        // closures cannot capture self before `delivery` itself is assigned,
        // and the box is connected the moment self is complete.
        let box = CallbackBox()
        delivery = structurallyDisabled
            ? nil
            : ClientFlagsDelivery(
                observerUrl: observerUrl,
                flagsUrl: options.url,
                key: key,
                appID: appID,
                installID: installID,
                userAgent: "e-volv-logs-swift/\(Constants.sdkVersion)",
                session: session,
                pollInterval: poll,
                offline: options.offline,
                contextJSON: { box.contextJSON() },
                onPayload: { body in box.onPayload(body) },
                log: log
            )
        box.contextJSON = { [weak self] in self?.currentContextJSON() ?? "{}" }
        box.onPayload = { [weak self] body in self?.accept(body) }
        // The actor starts from a task: the initializer is synchronous and
        // all shared state above is set before the first fetch can answer.
        if let delivery {
            Task { await delivery.start() }
        }
    }

    // MARK: - reads (synchronous, never throw, never I/O)

    public func bool(_ key: String, default defaultValue: Bool) -> Bool {
        let result = typed(.bool, key, .bool(defaultValue))
        if case let .bool(flag) = result.value { return flag }
        return defaultValue
    }

    public func string(_ key: String, default defaultValue: String) -> String {
        let result = typed(.string, key, .string(defaultValue))
        if case let .string(text) = result.value { return text }
        return defaultValue
    }

    public func number(_ key: String, default defaultValue: Double) -> Double {
        let result = typed(.number, key, .number(defaultValue))
        if case let .number(value) = result.value { return value }
        return defaultValue
    }

    public func json(_ key: String, default defaultValue: JSONValue) -> JSONValue {
        typed(nil, key, defaultValue).value
    }

    /// The full answer: value, variant, reason. No type check — the caller
    /// asked for the value as served.
    public func detail(_ key: String, default defaultValue: JSONValue) -> Evaluation {
        typed(nil, key, defaultValue)
    }

    /// The full answer for a typed read (`"bool"` / `"string"` / `"number"`,
    /// anything else reads like `detail`): the served value, variant and
    /// reason on a type match, the caller's default with `TYPE_MISMATCH`
    /// otherwise. Records an exposure exactly like the typed reads — a
    /// missing flag or a mismatch records nothing (contract §7). The
    /// conformance runner's `eval` goes through here so its reads exercise
    /// the real typed path.
    public func typedDetail(_ key: String, type: String, default defaultValue: JSONValue) -> Evaluation {
        switch type {
        case "bool": return typed(.bool, key, defaultValue)
        case "string": return typed(.string, key, defaultValue)
        case "number": return typed(.number, key, defaultValue)
        default: return typed(nil, key, defaultValue)
        }
    }

    // MARK: - writes (the only calls that wait)

    /// Replace the context and re-fetch values for it. Returns whether the
    /// served values are for this context. Accepts a plain dictionary
    /// (keys sorted, deterministic), `KeyValuePairs`, or an ordered
    /// `[(String, Any)]` — pass ordered input when the query must be
    /// byte-identical across platforms; the fingerprint is order-free.
    @discardableResult
    public func identify(_ context: [String: Any]) async -> Bool {
        await identifyPairs(Flags.orderedPairs(context))
    }

    @discardableResult
    public func identify(_ context: KeyValuePairs<String, Any>) async -> Bool {
        await identifyPairs(context.map { ($0.key, JSONValue.from(any: $0.value)) })
    }

    @discardableResult
    public func identify(_ context: [(String, Any)]) async -> Bool {
        await identifyPairs(context.map { ($0.0, JSONValue.from(any: $0.1)) })
    }

    /// The shared core: pairs already converted to JSONValue exactly once.
    @discardableResult
    private func identifyPairs(_ pairs: [(String, JSONValue)]) async -> Bool {
        let fitted = ContextFit.fit(pairs)
        if fitted.trimmed { log.once("trimmed", "context exceeded 4096 characters — dropped attributes (largest first) to fit") }
        let tree = Flags.stripPrivate(
            JSONTree.object(fitted.context.map { ($0.0, JSONTree($0.1)) }),
            privateNames
        )
        lock.lock()
        contextTree = tree
        contextJSON = ContextFit.render(tree)
        contextFingerprint = ContextFit.fingerprint(tree)
        lock.unlock()
        // A context change must always fetch: this is refreshNow, not the
        // coalesced poll refresh (the initial fetch may still be in flight
        // with the previous context).
        await delivery?.refreshNow()
        lock.lock()
        defer { lock.unlock() }
        return values != nil && servedFingerprint == contextFingerprint
    }

    /// Wait (at most `timeout` seconds) for values confirmed by the control
    /// plane for the current context. Bootstrap and cache serve reads
    /// immediately; this only gates on the network answer.
    public func ready(timeout: TimeInterval = 5) async -> Bool {
        lock.lock()
        if isReadyLocked() {
            lock.unlock()
            return true
        }
        lock.unlock()
        return await withCheckedContinuation { continuation in
            let box = WaiterBox(continuation: continuation)
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                self.timeoutWaiter(box)
            }
            lock.lock()
            if isReadyLocked() {
                lock.unlock()
                timeoutTask.cancel()
                continuation.resume(returning: true)
            } else {
                waiterSequence += 1
                box.id = waiterSequence
                readyWaiters.append((id: waiterSequence, continuation: continuation))
                lock.unlock()
            }
        }
    }

    /// Foreground refresh: fetches only when the last fetch is older than
    /// 15 s (the lifecycle hook calls this on every app foreground).
    public func refreshIfStale() async {
        await delivery?.refreshIfStale()
    }

    /// Force a coalesced refresh now (the poll collapses concurrent
    /// refreshes). The React Native `flagsRefresh` bridges here.
    public func refresh() async {
        await delivery?.refreshNow()
    }

    /// Subscribe to flag-key changes; `cancel()` the subscription to stop.
    @discardableResult
    public func onChange(_ handler: @escaping ([String]) -> Void) -> FlagsSubscription {
        let subscription = FlagsSubscription()
        let listener = Listener(subscription: subscription, handler: handler)
        subscription.setOnCancel { [weak self, weak listener] in
            guard let self, let listener else { return }
            self.lock.lock()
            self.listeners.removeAll { $0 === listener }
            self.lock.unlock()
        }
        lock.lock()
        listeners.append(listener)
        lock.unlock()
        return subscription
    }

    /// When the held values were last confirmed by the control plane, or —
    /// before the first confirmation — last swapped in. Nil when nothing
    /// has ever been held.
    public var lastUpdatedAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return confirmedAt ?? updatedAt
    }

    /// The delivery mode: client SDKs poll, or report offline.
    public var mode: String {
        structurallyDisabled || offlineMode ? "offline" : "poll"
    }

    /// The install check: `GET /ping` against the control plane.
    public func verify() async -> PingResult? {
        guard !structurallyDisabled, let baseURL, let session else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent("ping"))
        request.timeoutInterval = 10
        applyIdentityHeaders(to: &request)
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(PingResult.self, from: data)
        } catch {
            return nil
        }
    }

    /// Drain pending exposures to `/exposures`, 1,000 at a time. Async: the
    /// POSTs ride `session.data(for:)`, so this never parks the calling
    /// thread (the background lifecycle task and `shutdown()` included).
    public func flushExposures() async {
        guard !structurallyDisabled, let transport, let baseURL else { return }
        while true {
            let batch = exposures.drain()
            if batch.isEmpty { return }
            guard let body = try? JSONSerialization.data(withJSONObject: ["exposures": batch]) else { return }
            let result = await transport.postJSON(body, to: baseURL.appendingPathComponent("exposures"))
            if (200 ..< 300).contains(result.status) { continue }
            exposures.requeue(batch)
            return
        }
    }

    /**
     * Accepts exposures recorded by a cross-platform layer (React Native,
     * Flutter — reads happen there) as `{"exposures": [...]}` and posts them
     * through the exposure transport with the same failure semantics as
     * `flushExposures`: an undeliverable batch is requeued for the next
     * flush. Malformed JSON is dropped; never throws.
     *
     * Parses on the caller and posts off it: the bridges call this from the
     * Flutter platform thread and the React Native module queue, so it
     * returns at once. The returned task completes when the batch has been
     * delivered or requeued.
     */
    @discardableResult
    public func sendExposures(json: String) -> Task<Void, Never> {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let batch = parsed["exposures"] as? [[String: Any]], !batch.isEmpty
        else { return Task {} }
        return Task.detached { await self.postBridgedExposures(batch) }
    }

    /**
     * The current snapshot as JSON for the React Native bridge
     * (`flagsSnapshot`): `{"values": {key: {value, variant, reason}} | null,
     * "environmentId": String?, "updatedAt": epoch-ms | null}`. Synchronous —
     * an AtomicReference-style read, no I/O.
     */
    public func snapshotJSON() -> String {
        lock.lock()
        let held = values
        let environmentId = fetchedEnvironmentId
        let at = confirmedAt ?? updatedAt
        lock.unlock()

        var object: [String: Any] = [
            "values": NSNull(),
            "environmentId": environmentId ?? NSNull(),
            "updatedAt": at.map { $0.timeIntervalSince1970 * 1000 } ?? NSNull(),
        ]
        if let held {
            var flags: [String: Any] = [:]
            for (key, evaluation) in held {
                flags[key] = [
                    "value": evaluation.value.anyValue,
                    "variant": evaluation.variant ?? NSNull(),
                    "reason": evaluation.reason,
                ]
            }
            object["values"] = flags
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else {
            return #"{"values":null,"environmentId":null,"updatedAt":null}"#
        }
        return String(data: data, encoding: .utf8)
            ?? #"{"values":null,"environmentId":null,"updatedAt":null}"#
    }

    /// Stop polling and flush what is pending. Idempotent. The final flush
    /// runs detached and is never awaited: closing from
    /// `applicationWillTerminate` must not park the main thread on the
    /// network, and whatever the flush misses stays queued for the next
    /// flush after relaunch.
    public func close() {
        let delivery = delivery
        Task { await delivery?.close() }
        Task.detached { await self.flushExposures() }
    }

    // MARK: - internals

    private enum ExpectedType { case bool, string, number }

    private func typed(_ expected: ExpectedType?, _ key: String, _ defaultValue: JSONValue) -> Evaluation {
        lock.lock()
        guard !structurallyDisabled else {
            lock.unlock()
            return Evaluation(value: defaultValue, variant: nil, reason: "FLAG_NOT_FOUND")
        }
        guard let held = values else {
            lock.unlock()
            log.once("not-ready", "flags not ready — serving defaults until the first values arrive")
            return Evaluation(value: defaultValue, variant: nil, reason: "FLAG_NOT_FOUND")
        }
        guard let entry = held[key] else {
            lock.unlock()
            return Evaluation(value: defaultValue, variant: nil, reason: "FLAG_NOT_FOUND")
        }
        if let expected {
            let matches: Bool
            switch expected {
            case .bool: matches = { if case .bool = entry.value { return true }; return false }()
            case .string: matches = { if case .string = entry.value { return true }; return false }()
            case .number: matches = { if case .number = entry.value { return true }; return false }()
            }
            if !matches {
                lock.unlock()
                return Evaluation(value: defaultValue, variant: nil, reason: "TYPE_MISMATCH")
            }
        }
        lock.unlock()
        exposures.record(flagKey: key, variant: entry.variant, reason: entry.reason, context: currentContextTree())
        return entry
    }

    /// A 200 bootstrap body: { rulesetVersion, environmentId, etag, flags }.
    private func accept(_ body: [String: Any]) {
        if let version = body["rulesetVersion"] as? Double, version > 2 {
            log.once("version", "ignoring values from a ruleset newer than this SDK reads (v\(Int(version))); upgrade e-volv-logs-swift")
            return
        }
        guard let flagsObject = body["flags"] as? [String: Any] else { return }
        var parsed: [String: Evaluation] = [:]
        for (name, raw) in flagsObject {
            guard let dict = raw as? [String: Any] else { return }
            parsed[name] = Evaluation(
                value: JSONValue.from(any: dict["value"]),
                variant: dict["variant"] as? String,
                reason: dict["reason"] as? String ?? ""
            )
        }

        lock.lock()
        let previous = values
        values = parsed
        servedFingerprint = contextFingerprint
        let at = Date()
        updatedAt = at
        confirmedAt = at
        receivedFromNetwork = true
        let environmentId = body["environmentId"] as? String
        if let environmentId {
            if let fetched = fetchedEnvironmentId, environmentId != fetched {
                log.once("environment", "this key now serves a different environment")
            }
            fetchedEnvironmentId = environmentId
        }
        let fingerprint = contextFingerprint
        let environment = environmentId ?? fetchedEnvironmentId ?? ""
        let etag = body["etag"] as? String ?? ""
        let version = Int(body["rulesetVersion"] as? Double ?? 2)
        let changed = Flags.changedKeys(previous: previous, next: parsed)
        let callbacks = listeners.compactMap { listener -> (([String]) -> Void)? in
            listener.subscription == nil ? nil : listener.handler
        }
        let waiters = readyWaiters
        readyWaiters = []
        let readyNow = isReadyLocked()
        lock.unlock()

        cache?.write(
            key: key,
            environmentId: environment,
            rulesetVersion: version,
            etag: etag,
            fingerprint: fingerprint,
            flags: parsed
        )
        for callback in callbacks where !changed.isEmpty {
            callback(changed)
        }
        for waiter in waiters {
            waiter.continuation.resume(returning: readyNow)
        }
    }

    private func isReadyLocked() -> Bool {
        guard values != nil else { return false }
        if offlineMode { return true }
        return receivedFromNetwork && servedFingerprint == contextFingerprint
    }

    /// The timeout path of `ready`: resume the boxed waiter with the current
    /// answer if nobody else got to it first.
    private final class WaiterBox {
        let continuation: CheckedContinuation<Bool, Never>
        var id = 0

        init(continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }
    }

    private func timeoutWaiter(_ box: WaiterBox) {
        lock.lock()
        guard let index = readyWaiters.firstIndex(where: { $0.id == box.id }) else {
            lock.unlock()
            return
        }
        readyWaiters.remove(at: index)
        let answer = isReadyLocked()
        lock.unlock()
        box.continuation.resume(returning: answer)
    }

    private func currentContextJSON() -> String {
        lock.lock()
        defer { lock.unlock() }
        return contextJSON
    }

    private func currentContextTree() -> JSONTree {
        lock.lock()
        defer { lock.unlock() }
        return contextTree
    }

    private func applyIdentityHeaders(to request: inout URLRequest) {
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(appID, forHTTPHeaderField: "x-evolve-app-id")
        request.setValue(installID, forHTTPHeaderField: "x-evolve-install-id")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    }

    private var userAgent: String { "e-volv-logs-swift/\(Constants.sdkVersion)" }

    /// The shared poster for bridged batches: 1,000 per request, requeue and
    /// stop on a delivery failure — exactly `flushExposures`'s contract.
    private func postBridgedExposures(_ batch: [[String: Any]]) async {
        guard !structurallyDisabled, let transport, let baseURL else { return }
        var remaining = batch
        while !remaining.isEmpty {
            let chunk = Array(remaining.prefix(1000))
            remaining = Array(remaining.dropFirst(1000))
            guard let body = try? JSONSerialization.data(withJSONObject: ["exposures": chunk]) else { return }
            let result = await transport.postJSON(body, to: baseURL.appendingPathComponent("exposures"))
            if (200 ..< 300).contains(result.status) { continue }
            exposures.requeue(chunk + remaining)
            return
        }
    }

    /// Sorted-key deterministic form of a plain dictionary.
    private static func orderedPairs(_ context: [String: Any]) -> [(String, JSONValue)] {
        context
            .map { ($0.key, JSONValue.from(any: $0.value)) }
            .sorted { $0.0.utf16.lexicographicallyPrecedes($1.0.utf16) }
    }

    /// Remove private attributes from a single context or from every nested
    /// single of a multi context (the JavaScript stripPrivate).
    private static func stripPrivate(_ tree: JSONTree, _ names: [String]) -> JSONTree {
        guard !names.isEmpty, case let .object(pairs) = tree else { return tree }
        let nameSet = Set(names)
        let isMulti = pairs.contains { pair in
            guard pair.0 == "kind", case let .string(kind) = pair.1 else { return false }
            return kind == "multi"
        }
        guard isMulti else {
            return .object(pairs.filter { !nameSet.contains($0.0) })
        }
        return .object(pairs.map { key, value in
            guard key != "kind", case let .object(nested) = value else { return (key, value) }
            return (key, JSONTree.object(nested.filter { !nameSet.contains($0.0) }))
        })
    }

    private static func changedKeys(previous: [String: Evaluation]?, next: [String: Evaluation]) -> [String] {
        guard let previous else { return [] }
        var keys = Set(previous.keys)
        keys.formUnion(next.keys)
        return keys
            .filter { previous[$0] != next[$0] }
            .sorted()
    }
}
