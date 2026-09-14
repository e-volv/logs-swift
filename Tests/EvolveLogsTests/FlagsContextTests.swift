import XCTest
@testable import EvolveLogs

/// The shared vectors (packages/flags-client/__tests__/vectors.json, copied
/// byte-identical into this target's Resources) pin Swift's context fitting
/// and fingerprinting to the JavaScript implementation. The copy is asserted
/// byte-identical from the flags-client spec, so a drift fails there first.
final class FlagsContextTests: XCTestCase {
    private func loadVectors() throws -> [JSONTree] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vectors", withExtension: "json"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = try XCTUnwrap(JSONParser.parse(text), "vectors.json did not parse")
        guard case let .array(entries) = parsed else {
            XCTFail("vectors.json is not an array")
            return []
        }
        return entries
    }

    private func field(_ name: String, in entry: JSONTree) -> JSONTree? {
        entry.objectPairs.first { $0.0 == name }?.1
    }

    private func stringField(_ name: String, in entry: JSONTree) -> String? {
        guard let tree = field(name, in: entry), case let .string(value) = tree else { return nil }
        return value
    }

    func testSharedVectors() throws {
        for entry in try loadVectors() {
            let name = try XCTUnwrap(stringField("name", in: entry))
            guard let context = field("context", in: entry), case .object = context else {
                return XCTFail("\(name): context is not an object")
            }
            let expectedFitted = try XCTUnwrap(stringField("fitted", in: entry), name)
            let expectedTrimmed = field("trimmed", in: entry).map { tree -> Bool in
                if case let .bool(b) = tree { return b }
                return false
            } ?? false
            let expectedFingerprint = try XCTUnwrap(stringField("fingerprint", in: entry), name)
            let expectedCanonical = try XCTUnwrap(stringField("canonical", in: entry), name)

            let result = ContextFit.fit(context)
            XCTAssertEqual(result.json, expectedFitted, name)
            XCTAssertEqual(result.trimmed, expectedTrimmed, name)
            XCTAssertEqual(ContextFit.fingerprint(result.context), expectedFingerprint, name)
            XCTAssertEqual(ContextFit.canonicalJSON(result.context), expectedCanonical, name)
        }
    }

    func testBooleansAreNotNumbers() throws {
        let parsed = try JSONSerialization.jsonObject(with: Data(#"{"a":true,"b":1,"c":0}"#.utf8))
        XCTAssertEqual(
            JSONValue.from(any: parsed),
            .object(["a": .bool(true), "b": .number(1), "c": .number(0)])
        )
    }

    func testNumbersPrintLikeJavaScript() {
        XCTAssertEqual(ContextFit.jsNumberString(1), "1")
        XCTAssertEqual(ContextFit.jsNumberString(1.5), "1.5")
        XCTAssertEqual(ContextFit.jsNumberString(1e21), "1e+21")
        XCTAssertEqual(ContextFit.jsNumberString(-0), "0")
        XCTAssertEqual(ContextFit.jsNumberString(5e-7), "5e-7")
        XCTAssertEqual(ContextFit.jsNumberString(5e-324), "5e-324")
        XCTAssertEqual(ContextFit.jsNumberString(100), "100")
        XCTAssertEqual(ContextFit.jsNumberString(0.05), "0.05")
        XCTAssertEqual(ContextFit.jsNumberString(-1.5), "-1.5")
        XCTAssertEqual(ContextFit.jsNumberString(.nan), "null")
        XCTAssertEqual(ContextFit.jsNumberString(.infinity), "null")
    }

    func testSha1FallbackMatchesCryptoKit() {
        // SHA1Fallback exists for Linux CI runs; on macOS it must agree with
        // CryptoKit exactly or the Linux vector runs would drift silently.
        let inputs = [
            "",
            "abc",
            "The quick brown fox jumps over the lazy dog",
            String(repeating: "ünïcødé 🚀 ", count: 40),
        ]
        for input in inputs {
            let expected = ContextFit.sha1Hex(input)
            XCTAssertEqual(SHA1Fallback.hex(Data(input.utf8)), expected, "sha1(\"\(input.prefix(20))…\")")
        }
    }
}
