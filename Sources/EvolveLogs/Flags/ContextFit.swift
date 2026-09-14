import Foundation
#if canImport(CryptoKit)
    import CryptoKit
#endif

/// Context fitting and fingerprinting for client keys (docs/LAUNCH-SDK.md
/// §2.2): the compact context JSON must fit 4,096 UTF-16 characters, dropping
/// attributes largest-first — never `key`, `kind` or `targetingKey` — and the
/// fingerprint is the sha1 of the canonical (sorted-key) JSON. Every rule
/// reproduces the JavaScript implementation in
/// packages/flags-client/src/context-fit.ts, pinned by the shared vectors
/// (packages/flags-client/__tests__/vectors.json).
enum ContextFit {
    static let maxChars = 4096
    private static let identity: Set<String> = ["key", "kind", "targetingKey"]

    // MARK: - fit

    /// Ordered-pairs entry — preserves the caller's key order exactly, the
    /// only way to reproduce JavaScript's JSON.stringify output
    /// byte-for-byte.
    static func fit(_ pairs: [(String, JSONValue)]) -> (context: [(String, JSONValue)], json: String, trimmed: Bool) {
        let tree = JSONTree.object(pairs.map { ($0.0, JSONTree($0.1)) })
        let result = fit(tree)
        return (
            result.context.objectPairs.map { ($0.0, $0.1.value) },
            result.json,
            result.trimmed
        )
    }

    /// Plain-dictionary entry: Swift dictionaries are unordered, so keys are
    /// sorted first — the output is deterministic, and the fingerprint is
    /// order-free either way. Pass ordered pairs to `Flags.identify` when the
    /// query must be byte-identical across platforms.
    static func fit(_ context: [String: JSONValue]) -> (context: [String: JSONValue], json: String, trimmed: Bool) {
        let sorted = context
            .map { ($0.key, $0.value) }
            .sorted { $0.0.utf16.lexicographicallyPrecedes($1.0.utf16) }
        let result = fit(sorted)
        return (Dictionary(uniqueKeysWithValues: result.context), result.json, result.trimmed)
    }

    /// The algorithm, on the order-preserving tree. Multi contexts trim
    /// inside each nested single context, exactly like the JavaScript.
    static func fit(_ context: JSONTree) -> (context: JSONTree, json: String, trimmed: Bool) {
        guard case let .object(top) = context else {
            return (context, render(context), false)
        }
        var work = top
        let initial = render(.object(work))
        if initial.utf16.count <= maxChars {
            return (.object(work), initial, false)
        }
        let isMulti = top.contains { pair in
            guard pair.0 == "kind", case let .string(kind) = pair.1 else { return false }
            return kind == "multi"
        }
        // candidate = (holder key, attribute name, size in UTF-16, insertion
        // order). holder nil = the root object. JavaScript's sort is stable,
        // so equal-size attributes are dropped in insertion order — the
        // vectors pin that rule.
        var candidates: [(holder: String?, name: String, size: Int, order: Int)] = []
        var order = 0
        if isMulti {
            for (key, value) in work where key != "kind" {
                guard case let .object(nested) = value else { continue }
                for (name, attribute) in nested where !identity.contains(name) {
                    candidates.append((key, name, render(attribute).utf16.count, order))
                    order += 1
                }
            }
        } else {
            for (name, attribute) in work where !identity.contains(name) {
                candidates.append((nil, name, render(attribute).utf16.count, order))
                order += 1
            }
        }
        candidates.sort {
            $0.size > $1.size || ($0.size == $1.size && $0.order < $1.order)
        }
        // JavaScript reports trimmed: true whenever the initial context did
        // not fit — even when nothing was droppable (identity-only vectors).
        var trimmed = true
        for candidate in candidates {
            removeAttribute(&work, holder: candidate.holder, name: candidate.name)
            let json = render(.object(work))
            if json.utf16.count <= maxChars {
                return (.object(work), json, true)
            }
        }
        // Only identity fields left (or nothing at all): send over-length.
        return (.object(work), render(.object(work)), trimmed)
    }

    private static func removeAttribute(_ work: inout [(String, JSONTree)], holder: String?, name: String) {
        if let holder {
            for index in work.indices where work[index].0 == holder {
                guard case var .object(nested) = work[index].1 else { continue }
                nested.removeAll { $0.0 == name }
                work[index].1 = .object(nested)
            }
        } else {
            work.removeAll { $0.0 == name }
        }
    }

    // MARK: - rendering (JavaScript JSON.stringify semantics)

    /// Insertion-ordered JSON, as JSON.stringify emits for an object built
    /// from the caller's keys.
    static func render(_ tree: JSONTree) -> String {
        switch tree {
        case .null: return "null"
        case let .bool(b): return b ? "true" : "false"
        case let .number(x): return jsNumberString(x)
        case let .string(s): return jsonString(s)
        case let .array(items):
            return "[" + items.map(render).joined(separator: ",") + "]"
        case let .object(pairs):
            return "{" + pairs.map { jsonString($0.0) + ":" + render($0.1) }.joined(separator: ",") + "}"
        }
    }

    /// JSON.stringify output for a number (packages/flags-kernel/PORTING.md
    /// `jsNumberString`). Swift's `\(x)` is the shortest round-trip digits
    /// ("1e+21", "1.5", "5e-324"); the exponent is normalised to JavaScript's
    /// spelling here.
    static func jsNumberString(_ x: Double) -> String {
        if x.isNaN || x.isInfinite { return "null" } // JSON.stringify(NaN) is "null"
        if x == 0 { return "0" } // and JSON.stringify(-0) is "0"
        if x < 0 { return "-" + jsNumberString(-x) }
        let text = "\(x)"
        let parts = text.lowercased().split(separator: "e", maxSplits: 1).map(String.init)
        let mantissa = parts[0]
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let pieces = mantissa.split(separator: ".", maxSplits: 1).map(String.init)
        let intPart = pieces[0]
        let fracPart = pieces.count > 1 ? pieces[1] : ""
        let raw = intPart + fracPart
        var n = intPart.count + exponent
        let stripped = String(raw.drop(while: { $0 == "0" }))
        n -= raw.count - stripped.count
        var d = stripped
        while d.hasSuffix("0") { d.removeLast() }
        if d.isEmpty { return "0" }
        let k = d.count
        if k <= n, n <= 21 { return d + String(repeating: "0", count: n - k) }
        if n > 0, n <= 21 { return String(d.prefix(n)) + "." + String(d.dropFirst(n)) }
        if n > -6, n <= 0 { return "0." + String(repeating: "0", count: -n) + d }
        let e = n - 1
        let head = k == 1 ? d : String(d.prefix(1)) + "." + String(d.dropFirst())
        return head + "e" + (e >= 0 ? "+" : "-") + String(abs(e))
    }

    /// JSON.stringify string escaping: ", \, control characters; everything
    /// else literal (non-ASCII passes through unescaped).
    static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: - canonical JSON and fingerprint

    /// Canonical JSON: object keys sorted by UTF-16 code units (what
    /// JavaScript's default Array.prototype.sort compares), recursively.
    static func canonicalJSON(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case let .bool(b): return b ? "true" : "false"
        case let .number(x): return jsNumberString(x)
        case let .string(s): return jsonString(s)
        case let .array(items):
            return "[" + items.map(canonicalJSON).joined(separator: ",") + "]"
        case let .object(map):
            return "{" + map.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
                .map { jsonString($0) + ":" + canonicalJSON(map[$0]!) }.joined(separator: ",") + "}"
        }
    }

    static func canonicalJSON(_ tree: JSONTree) -> String {
        switch tree {
        case .null: return "null"
        case let .bool(b): return b ? "true" : "false"
        case let .number(x): return jsNumberString(x)
        case let .string(s): return jsonString(s)
        case let .array(items):
            return "[" + items.map(canonicalJSON).joined(separator: ",") + "]"
        case let .object(pairs):
            return "{" + pairs
                .sorted { $0.0.utf16.lexicographicallyPrecedes($1.0.utf16) }
                .map { jsonString($0.0) + ":" + canonicalJSON($0.1) }.joined(separator: ",") + "}"
        }
    }

    /// sha1 hex of the canonical JSON — the same context hashes identically
    /// whatever order it was built in.
    static func fingerprint(_ context: JSONTree) -> String {
        sha1Hex(canonicalJSON(context))
    }

    static func fingerprint(_ context: [String: JSONValue]) -> String {
        sha1Hex(canonicalJSON(.object(context)))
    }

    static func sha1Hex(_ s: String) -> String {
        #if canImport(CryptoKit)
            return Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
            return SHA1Fallback.hex(Data(s.utf8))
        #endif
    }

    /// Cache file name for a key: the key's sha1, never the key itself
    /// (docs/LAUNCH-SDK.md §6).
    static func cacheName(key: String) -> String {
        "evolve-flags-\(sha1Hex(key).prefix(12)).json"
    }
}

/// Pure-Swift SHA-1 for platforms without CryptoKit (Linux CI runs). Verified
/// against CryptoKit in FlagsContextTests on every macOS test run.
enum SHA1Fallback {
    static func hex(_ data: Data) -> String {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in [56, 48, 40, 32, 24, 16, 8, 0] {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }

        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0

        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0 ..< 16 {
                w[i] = (UInt32(message[chunkStart + i * 4]) << 24)
                    | (UInt32(message[chunkStart + i * 4 + 1]) << 16)
                    | (UInt32(message[chunkStart + i * 4 + 2]) << 8)
                    | UInt32(message[chunkStart + i * 4 + 3])
            }
            for i in 16 ..< 80 {
                w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotatedLeft(1)
            }
            var a = h0, b = h1, c = h2, d = h3, e = h4
            for i in 0 ..< 80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0 ..< 20:
                    f = (b & c) | (~b & d)
                    k = 0x5A827999
                case 20 ..< 40:
                    f = b ^ c ^ d
                    k = 0x6ED9EBA1
                case 40 ..< 60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1BBCDC
                default:
                    f = b ^ c ^ d
                    k = 0xCA62C1D6
                }
                let temp = a.rotatedLeft(5) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = b.rotatedLeft(30)
                b = a
                a = temp
            }
            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
        }
        return [h0, h1, h2, h3, h4].map { String(format: "%08x", $0) }.joined()
    }
}

extension UInt32 {
    fileprivate func rotatedLeft(_ count: UInt32) -> UInt32 {
        (self << count) | (self >> (32 - count))
    }
}
