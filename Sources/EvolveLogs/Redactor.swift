import Foundation

/// Case-insensitive substring redaction of attribute keys, pinned by the
/// shared contract (docs/OBSERVER-SDK.md): keys matching
/// `password|secret|token|authorization|cookie|set-cookie|api[-_]?key` —
/// plus anything the caller listed in `redactKeys` — are replaced with
/// "[redacted]" before anything leaves the process. The walk recurses into
/// nested dictionaries and arrays. In Swift attrs are typed
/// `[String: Any]`; both NSDictionary and Swift dictionaries arrive as
/// [String: Any] at the SDK boundary, so one walker covers both.
enum Redactor {
    static let backstop = "password|secret|token|authorization|cookie|set-cookie|api[-_]?key"

    static func pattern(extraKeys: [String]) -> String {
        guard !extraKeys.isEmpty else { return backstop }
        let quoted = extraKeys.map { NSRegularExpression.escapedPattern(for: $0) }
        return backstop + "|" + quoted.joined(separator: "|")
    }

    static func makeMatcher(extraKeys: [String]) -> (String) -> Bool {
        let re = try? NSRegularExpression(pattern: pattern(extraKeys: extraKeys))
        let lowered = extraKeys.map { $0.lowercased() }
        return { key in
            let k = key.lowercased()
            if let re, re.firstMatch(
                in: k,
                range: NSRange(k.startIndex..., in: k)
            ) != nil {
                return true
            }
            return lowered.contains { k.contains($0) }
        }
    }

    static func redact(_ attrs: [String: Any], matches: (String) -> Bool) -> [String: Any] {
        var out = walk(attrs, matches) as? [String: Any]
        if out == nil { out = [:] }
        return out!
    }

    private static func walk(_ value: Any, _ matches: (String) -> Bool) -> Any {
        switch value {
        case let dict as [String: Any]:
            var out = [String: Any](minimumCapacity: dict.count)
            for (key, val) in dict {
                if matches(key) {
                    out[key] = Constants.redacted
                } else {
                    out[key] = walk(val, matches)
                }
            }
            return out
        case let arr as [Any]:
            return arr.map { walk($0, matches) }
        default:
            return value
        }
    }
}
