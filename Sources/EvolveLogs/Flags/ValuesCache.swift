import Foundation

/// The values cache (docs/LAUNCH-SDK.md §6): one envelope file per key,
/// `evolve-flags-<first 12 hex of sha1(key)>.json`, written atomically, kept
/// beside the Observer disk queue. The reader rejects everything the
/// contract lists: a file over 10 MB, an unknown formatVersion, the wrong
/// kind, rulesetVersion > 2, unparseable JSON, and a payload without a
/// string contextFingerprint.
struct ValuesCache {
    let directory: URL
    private static let maxBytes = 10 * 1024 * 1024

    /// nil when the cache is disabled; otherwise the directory exists.
    init?(queueDirectory: URL, explicit: URL?, enabled: Bool) {
        guard enabled else { return nil }
        do {
            var dir = explicit ?? queueDirectory.appendingPathComponent("flags", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Cached flag values must not ride into iCloud backups.
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            _ = try? dir.setResourceValues(resourceValues)
            directory = dir
        } catch {
            return nil
        }
    }

    private func file(for key: String) -> URL {
        directory.appendingPathComponent("evolve-flags-\(ContextFit.sha1Hex(key).prefix(12)).json")
    }

    struct Entry {
        let flags: [String: Evaluation]
        let fingerprint: String
        let savedAt: Date
    }

    func read(key: String) -> Entry? {
        do {
            let url = file(for: key)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if (attributes[.size] as? Int) ?? 0 > Self.maxBytes { return nil }
            let data = try Data(contentsOf: url)
            guard data.count <= Self.maxBytes else { return nil }
            let object = try JSONSerialization.jsonObject(with: data)
            guard let envelope = object as? [String: Any] else { return nil }
            guard (envelope["formatVersion"] as? Int) == 1 else { return nil }
            guard envelope["kind"] as? String == "values" else { return nil }
            if let version = envelope["rulesetVersion"] as? Double, version > 2 { return nil }
            guard envelope["environmentId"] is String, envelope["etag"] is String else { return nil }
            let payload = envelope["payload"] as? [String: Any]
            guard let fingerprint = payload?["contextFingerprint"] as? String else { return nil }
            guard let flagsObject = payload?["flags"] as? [String: Any] else { return nil }
            var flags: [String: Evaluation] = [:]
            for (name, raw) in flagsObject {
                guard let dict = raw as? [String: Any] else { return nil }
                flags[name] = Evaluation(
                    value: JSONValue.from(any: dict["value"]),
                    variant: dict["variant"] as? String,
                    reason: dict["reason"] as? String ?? ""
                )
            }
            let savedAt = Date.parseIso8601(envelope["savedAt"] as? String) ?? Date()
            return Entry(flags: flags, fingerprint: fingerprint, savedAt: savedAt)
        } catch {
            return nil // corrupt or unreadable: start clean (L7)
        }
    }

    func write(
        key: String,
        environmentId: String,
        rulesetVersion: Int,
        etag: String,
        fingerprint: String,
        flags: [String: Evaluation]
    ) {
        do {
            let envelope = JSONTree.object([
                ("formatVersion", .number(1)),
                ("kind", .string("values")),
                ("environmentId", .string(environmentId)),
                ("rulesetVersion", .number(Double(rulesetVersion))),
                ("etag", .string(etag)),
                ("savedAt", .string(Clock.iso8601())),
                ("payload", .object([
                    ("contextFingerprint", .string(fingerprint)),
                    ("flags", .object(flags.map { name, evaluation in
                        (name, .object([
                            ("value", JSONTree(evaluation.value)),
                            ("variant", evaluation.variant.map(JSONTree.string) ?? .null),
                            ("reason", .string(evaluation.reason)),
                        ]))
                    })),
                ])),
            ])
            let body = ContextFit.render(envelope)
            // The 10 MB cap counts bytes, not UTF-16 units (contract §6):
            // measure the encoded body and write those same bytes.
            let data = Data(body.utf8)
            guard data.count <= Self.maxBytes else { return }
            try data.write(to: file(for: key), options: [.atomic])
        } catch {
            // A full or unavailable disk must never break evaluation.
        }
    }
}

extension Date {
    /// The `savedAt` grammar both sides write: RFC3339 with milliseconds.
    static func parseIso8601(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.date(from: text)
    }
}
