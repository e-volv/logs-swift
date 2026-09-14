import Foundation

/// A JSON value, the types a Launch context or a served flag value can carry.
/// `Equatable` so tests and change detection compare values directly; numbers
/// are `Double` like JavaScript's only number kind.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

public extension JSONValue {
    /// JSON text of this value: object keys sorted (canonical), numbers the
    /// way JavaScript prints them. Used by the conformance runner for eval
    /// replies; order-free by design.
    var jsonText: String { ContextFit.canonicalJSON(self) }

    /// JSONSerialization hands back `NSNumber` for both numbers and booleans,
    /// and `as? Bool` succeeds for 0 and 1. Booleans are told apart by their
    /// CoreFoundation type (Darwin) or the Objective-C type encoding (Linux).
    static func from(any value: Any?) -> JSONValue {
        switch value {
        case nil, is NSNull:
            return .null
        case let value as JSONValue:
            return value
        case let number as NSNumber:
            #if canImport(Darwin)
                if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            #else
                if String(cString: number.objCType) == "c" { return .bool(number.boolValue) }
            #endif
            return .number(number.doubleValue)
        case let bool as Bool:
            return .bool(bool)
        case let string as String:
            return .string(string)
        case let array as [Any?]:
            return .array(array.map { from(any: $0) })
        case let dict as [String: Any?]:
            return .object(dict.mapValues { from(any: $0) })
        default:
            return .string(String(describing: value!))
        }
    }

    /// The Foundation form for `JSONSerialization`.
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(b): return b
        case let .number(n): return n
        case let .string(s): return s
        case let .array(items): return items.map(\.anyValue)
        case let .object(map): return map.mapValues(\.anyValue)
        }
    }
}

/// The same value tree with objects kept as ordered key/value pairs.
/// `JSONValue.object` is a Swift dictionary and cannot preserve the caller's
/// key order; the fitted-context JSON must, because JavaScript objects
/// preserve insertion order (packages/flags-client/src/context-fit.ts). The
/// internal parser and the context fit work on this tree; everything that
/// only reads values (evaluation, fingerprints, canonical JSON) is
/// order-free and uses `JSONValue`.
indirect enum JSONTree {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONTree])
    case object([(String, JSONTree)])

    init(_ value: JSONValue) {
        switch value {
        case .null: self = .null
        case let .bool(b): self = .bool(b)
        case let .number(n): self = .number(n)
        case let .string(s): self = .string(s)
        case let .array(items): self = .array(items.map(JSONTree.init))
        case let .object(map): self = .object(map.map { ($0.key, JSONTree($0.value)) })
        }
    }

    /// The order-free public form.
    var value: JSONValue {
        switch self {
        case .null: return .null
        case let .bool(b): return .bool(b)
        case let .number(n): return .number(n)
        case let .string(s): return .string(s)
        case let .array(items): return .array(items.map(\.value))
        case let .object(pairs): return .object(Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, $0.1.value) }))
        }
    }

    /// The pairs of an object node, [] for anything else.
    var objectPairs: [(String, JSONTree)] {
        if case let .object(pairs) = self { return pairs }
        return []
    }
}

/// A minimal recursive-descent JSON parser whose object nodes keep the
/// document's key order. `JSONSerialization` cannot promise that (its objects
/// are dictionaries), and the shared vectors pin insertion order, so the
/// vectors test — and anything else that must reproduce `JSON.stringify`
/// output byte-for-byte — parses through here. Internal: the conformance
/// runner uses `JSONValue.from(any:)` with `JSONSerialization`, which is
/// order-free and sufficient for the wire protocol.
enum JSONParser {
    static func parse(_ text: String) -> JSONTree? {
        var scalars = Array(text.unicodeScalars)
        var index = 0
        guard let value = parseValue(&scalars, &index) else { return nil }
        skipWhitespace(&scalars, &index)
        return index == scalars.count ? value : nil
    }

    private static func skipWhitespace(_ s: inout [Unicode.Scalar], _ i: inout Int) {
        while i < s.count {
            let c = s[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1 } else { return }
        }
    }

    private static func parseValue(_ s: inout [Unicode.Scalar], _ i: inout Int) -> JSONTree? {
        skipWhitespace(&s, &i)
        guard i < s.count else { return nil }
        switch s[i] {
        case "{": return parseObject(&s, &i)
        case "[": return parseArray(&s, &i)
        case "\"": return parseString(&s, &i).map(JSONTree.string)
        case "t":
            return consume(&s, &i, "true") ? .bool(true) : nil
        case "f":
            return consume(&s, &i, "false") ? .bool(false) : nil
        case "n":
            return consume(&s, &i, "null") ? .null : nil
        default:
            return parseNumber(&s, &i)
        }
    }

    private static func consume(_ s: inout [Unicode.Scalar], _ i: inout Int, _ word: String) -> Bool {
        let word = Array(word.unicodeScalars)
        guard i + word.count <= s.count else { return false }
        for (offset, c) in word.enumerated() where s[i + offset] != c { return false }
        i += word.count
        return true
    }

    private static func parseObject(_ s: inout [Unicode.Scalar], _ i: inout Int) -> JSONTree? {
        i += 1 // '{'
        var pairs: [(String, JSONTree)] = []
        skipWhitespace(&s, &i)
        if i < s.count, s[i] == "}" { i += 1; return .object(pairs) }
        while i < s.count {
            skipWhitespace(&s, &i)
            guard let key = parseString(&s, &i) else { return nil }
            skipWhitespace(&s, &i)
            guard i < s.count, s[i] == ":" else { return nil }
            i += 1
            guard let value = parseValue(&s, &i) else { return nil }
            // JSON.parse semantics: a repeated key keeps the last value.
            pairs.removeAll { $0.0 == key }
            pairs.append((key, value))
            skipWhitespace(&s, &i)
            guard i < s.count else { return nil }
            if s[i] == "," { i += 1; continue }
            if s[i] == "}" { i += 1; return .object(pairs) }
            return nil
        }
        return nil
    }

    private static func parseArray(_ s: inout [Unicode.Scalar], _ i: inout Int) -> JSONTree? {
        i += 1 // '['
        var items: [JSONTree] = []
        skipWhitespace(&s, &i)
        if i < s.count, s[i] == "]" { i += 1; return .array(items) }
        while i < s.count {
            guard let value = parseValue(&s, &i) else { return nil }
            items.append(value)
            skipWhitespace(&s, &i)
            guard i < s.count else { return nil }
            if s[i] == "," { i += 1; continue }
            if s[i] == "]" { i += 1; return .array(items) }
            return nil
        }
        return nil
    }

    private static func parseString(_ s: inout [Unicode.Scalar], _ i: inout Int) -> String? {
        guard i < s.count, s[i] == "\"" else { return nil }
        i += 1
        var out = String.UnicodeScalarView()
        while i < s.count {
            let c = s[i]
            if c == "\"" {
                i += 1
                return String(out)
            }
            if c == "\\" {
                i += 1
                guard i < s.count else { return nil }
                let esc = s[i]
                i += 1
                switch esc {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    guard let high = parseHex4(&s, &i) else { return nil }
                    // A UTF-16 surrogate pair: \uD83D\uDE00 and friends.
                    if high >= 0xD800, high < 0xDC00,
                       i + 1 < s.count, s[i] == "\\", s[i + 1] == "u" {
                        i += 2
                        guard let low = parseHex4(&s, &i), low >= 0xDC00, low < 0xE000 else { return nil }
                        let combined = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
                        guard let scalar = Unicode.Scalar(combined) else { return nil }
                        out.append(scalar)
                    } else if let scalar = Unicode.Scalar(high) {
                        out.append(scalar)
                    } else {
                        return nil
                    }
                default:
                    return nil
                }
                continue
            }
            out.append(c)
            i += 1
        }
        return nil
    }

    private static func parseHex4(_ s: inout [Unicode.Scalar], _ i: inout Int) -> Int? {
        guard i + 4 <= s.count else { return nil }
        var value = 0
        for _ in 0 ..< 4 {
            let c = s[i]
            i += 1
            let digit: Int
            switch c {
            case "0" ... "9": digit = Int(c.value - Unicode.Scalar("0").value)
            case "a" ... "f": digit = Int(c.value - Unicode.Scalar("a").value) + 10
            case "A" ... "F": digit = Int(c.value - Unicode.Scalar("A").value) + 10
            default: return nil
            }
            value = value * 16 + digit
        }
        return value
    }

    private static func parseNumber(_ s: inout [Unicode.Scalar], _ i: inout Int) -> JSONTree? {
        let start = i
        if i < s.count, s[i] == "-" { i += 1 }
        while i < s.count, s[i] >= "0", s[i] <= "9" { i += 1 }
        if i < s.count, s[i] == "." {
            i += 1
            while i < s.count, s[i] >= "0", s[i] <= "9" { i += 1 }
        }
        if i < s.count, s[i] == "e" || s[i] == "E" {
            i += 1
            if i < s.count, s[i] == "+" || s[i] == "-" { i += 1 }
            while i < s.count, s[i] >= "0", s[i] <= "9" { i += 1 }
        }
        guard i > start else { return nil }
        let text = String(String.UnicodeScalarView(s[start ..< i]))
        guard let number = Double(text), number.isFinite else { return nil }
        return .number(number)
    }
}
