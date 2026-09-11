@testable import EvolveLogs
import XCTest

/// Redaction: the pinned backstop regex plus user keys, recursing into
/// nested dictionaries and arrays, literal "[redacted]".
final class RedactorTests: XCTestCase {
    func testBackstopKeysRedact() {
        let matches = Redactor.makeMatcher(extraKeys: [])
        let input: [String: Any] = [
            "password": "p",
            "PASSWORD": "p", // case-insensitive
            "user_secret": "s", // substring
            "access_token": "t",
            "Authorization": "a",
            "cookie": "c",
            "set-cookie": "sc",
            "api_key": "k",
            "apikey": "k",
            "api-key": "k",
            "visible": "yes",
        ]
        let out = Redactor.redact(input, matches: matches)
        for key in ["password", "PASSWORD", "user_secret", "access_token", "Authorization", "cookie", "set-cookie", "api_key", "apikey", "api-key"] {
            XCTAssertEqual(out[key] as? String, "[redacted]", key)
        }
        XCTAssertEqual(out["visible"] as? String, "yes")
    }

    func testUserKeysExtendTheList() {
        let matches = Redactor.makeMatcher(extraKeys: ["secret_note"])
        let out = Redactor.redact(["secret_note": "hide me", "visible": "yes"], matches: matches)
        XCTAssertEqual(out["secret_note"] as? String, "[redacted]")
        XCTAssertEqual(out["visible"] as? String, "yes")
    }

    func testRecursesIntoDictsAndArrays() {
        let matches = Redactor.makeMatcher(extraKeys: [])
        let input: [String: Any] = [
            "outer": ["nested_token": "x", "keep": 1],
            "list": [["inner": ["password": "y"]], ["ok": true]],
        ]
        let out = Redactor.redact(input, matches: matches)
        let outer = out["outer"] as? [String: Any]
        XCTAssertEqual(outer?["nested_token"] as? String, "[redacted]")
        XCTAssertEqual(outer?["keep"] as? Int, 1)
        let list = out["list"] as? [[String: Any]]
        let inner = list?[0]["inner"] as? [String: Any]
        XCTAssertEqual(inner?["password"] as? String, "[redacted]")
        XCTAssertEqual(list?[1]["ok"] as? Bool, true)
    }
}
