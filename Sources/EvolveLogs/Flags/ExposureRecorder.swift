import Foundation

/// Exposure recording for client keys (docs/LAUNCH-SDK.md §7): sampling
/// first, then de-duplication on (flagKey, variant, contextKind, subject)
/// within the window; suppressed repeats ride as `count` on the first
/// exposure after the window. Everything is best effort: a recording
/// failure never reaches the caller. The lock guards every field; `detail`
/// may be called from any thread.
final class ExposureRecorder {
    private let enabled: Bool
    private let sampleRate: Double
    private let dedupeWindowSeconds: Double
    private let sendAttributes: Bool
    private let privateNames: Set<String>
    private let lock = NSLock()
    private var queue: [[String: Any]] = []
    private var seen: [String: SeenEntry] = [:]

    private struct SeenEntry {
        var atSeconds: Double
        var suppressed: Int
    }

    static let bufferCap = 10_000
    private static let seenCap = 50_000
    private static let reserved: Set<String> = ["kind", "key", "targetingKey", "name", "anonymous"]

    init(
        enabled: Bool,
        sampleRate: Double,
        dedupeWindowSeconds: Double,
        sendAttributes: Bool,
        privateAttributes: [String]
    ) {
        self.enabled = enabled
        self.sampleRate = sampleRate
        self.dedupeWindowSeconds = dedupeWindowSeconds
        self.sendAttributes = sendAttributes
        privateNames = Set(privateAttributes)
    }

    var pending: Int {
        lock.lock()
        defer { lock.unlock() }
        return queue.count
    }

    /// Record one evaluation. Only flags present in the payload reach here —
    /// `FLAG_NOT_FOUND` and `TYPE_MISMATCH` never record.
    func record(flagKey: String, variant: String?, reason: String, context: JSONTree) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        if sampleRate < 1, Double.random(in: 0 ..< 1) >= sampleRate { return }

        let subject = subjectOf(context)
        let dedupeKey = "\(flagKey)\u{0}\(variant ?? "")\u{0}\(subject.kind)\u{0}\(subject.key ?? "")"
        let now = Date().timeIntervalSince1970
        if var entry = seen[dedupeKey], now - entry.atSeconds < dedupeWindowSeconds {
            entry.suppressed += 1
            seen[dedupeKey] = entry
            return
        }
        let count = 1 + (seen[dedupeKey]?.suppressed ?? 0)
        seen[dedupeKey] = SeenEntry(atSeconds: now, suppressed: 0)
        if seen.count > Self.seenCap { prune(now) }

        var row: [String: Any] = [
            "id": UUID().uuidString,
            "ts": Clock.iso8601(),
            "flagKey": Self.clip(flagKey, to: 64),
            "reason": Self.clip(reason, to: 40),
            "contextKind": Self.clip(subject.kind, to: 64),
        ]
        if let variant { row["variant"] = Self.clip(variant, to: 60) }
        if let key = subject.key { row["subject"] = key }
        if let name = subject.name { row["contextName"] = name }
        if subject.anonymous { row["anonymous"] = true }
        if count > 1 { row["count"] = min(count, 1_000_000) }
        if sampleRate < 1 { row["sampleRate"] = sampleRate }
        if sendAttributes {
            row["attributes"] = subject.attributes.filter { !privateNames.contains($0.key) }
        }
        queue.append(row)
        if queue.count > Self.bufferCap {
            queue.removeFirst(queue.count - Self.bufferCap)
        }
    }

    /// Remove and return up to `limit` pending exposures.
    func drain(limit: Int = 1000) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        let count = min(limit, queue.count)
        let batch = Array(queue.prefix(count))
        queue.removeFirst(count)
        return batch
    }

    /// Put a batch that could not be sent back at the front, still capped.
    func requeue(_ batch: [[String: Any]]) {
        lock.lock()
        defer { lock.unlock() }
        queue = batch + queue
        if queue.count > Self.bufferCap {
            queue.removeFirst(queue.count - Self.bufferCap)
        }
    }

    private func prune(_ nowSeconds: Double) {
        seen = seen.filter { key, entry in
            _ = key
            return nowSeconds - entry.atSeconds < dedupeWindowSeconds || entry.suppressed > 0
        }
    }

    /// Contract §2.4: the exposure field limits (64/40/60/64/200) count
    /// code points, and a cut never splits a surrogate pair. The
    /// `unicodeScalars` view is Swift's code-point view — one scalar per
    /// code point — so a scalar prefix is a code-point prefix and cannot
    /// leave a lone surrogate (a grapheme-cluster `String.prefix` would
    /// under-count clusters like flags emoji, and a UTF-16 prefix could
    /// split a pair).
    private static func clip(_ text: String, to limit: Int) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        return String(decoding: text.unicodeScalars.prefix(limit).map(\.value), as: UTF32.self)
    }

    private struct Subject {
        let kind: String
        let key: String?
        let name: String?
        let anonymous: Bool
        let attributes: [String: Any]
    }

    private func subjectOf(_ context: JSONTree) -> Subject {
        let pairs = context.objectPairs
        var kind = "user"
        var single = pairs
        if let kindValue = pairs.first(where: { $0.0 == "kind" }), case let .string(value) = kindValue.1 {
            kind = value
        }
        if kind == "multi" {
            single = []
            for (name, value) in pairs where name != "kind" {
                if case .object = value {
                    kind = name
                    single = value.objectPairs
                    break
                }
            }
        }
        // §7: the subject is the context key with the same precedence
        // evaluation uses — `key` first, then `targetingKey`.
        let rawKey = single.first { $0.0 == "key" }?.1 ?? single.first { $0.0 == "targetingKey" }?.1
        let key = rawKey.map { Self.clip(jsString($0), to: 200) }
        let name = single.first(where: { $0.0 == "name" }).flatMap { pair -> String? in
            if case let .string(value) = pair.1 { return value }
            return nil
        }.map { Self.clip($0, to: 200) }
        let anonymous = single.first(where: { $0.0 == "anonymous" }).map { pair -> Bool in
            if case let .bool(flag) = pair.1 { return flag }
            return false
        } ?? false
        var attributes: [String: Any] = [:]
        for (name, value) in single where !Self.reserved.contains(name) {
            attributes[name] = value.value.anyValue
        }
        return Subject(kind: kind, key: key, name: name, anonymous: anonymous, attributes: attributes)
    }

    /// JavaScript's String() over the subject-key shapes a context carries.
    private func jsString(_ value: JSONTree) -> String {
        switch value {
        case .null: return "null"
        case let .bool(b): return b ? "true" : "false"
        case let .number(n): return ContextFit.jsNumberString(n)
        case let .string(s): return s
        case .array: return "[object Object]"
        case .object: return "[object Object]"
        }
    }
}
