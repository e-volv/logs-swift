import Foundation
@testable import EvolveLogs
import XCTest

/*
 * Task 1 of the S6 plan (React Native + Flutter): the entry points the
 * cross-platform bridges call — `emit(json:)` into the shared
 * redact/stamp/enqueue path, the public install id, the external
 * traceparent URLSession injection consults when no task-local trace is
 * active, and the explicit trace ids a pre-built event carries.
 */
final class BridgeAffordancesTests: XCTestCase {
    /// Exactly-n lowercase hex, without hand-counting characters.
    private static func hex(_ ch: Character, _ n: Int) -> String {
        String(repeating: ch, count: n)
    }

    func testEmitJsonRedactsAndStampsThroughEnqueue() {
        let dir = tempQueueDir()
        let client = makeClient(queueDirectory: dir)
        client.emit(json: """
        {"ts":"2026-09-14T00:00:00.000Z","severity":9,"message":"m","attrs":{"password":"x","user":"u1"}}
        """)
        let events = queuedEvents(dir)
        XCTAssertEqual(events.count, 1)
        let attrs = events[0]["attrs"] as? [String: Any] ?? [:]
        XCTAssertEqual(attrs["password"] as? String, "[redacted]")
        XCTAssertEqual(attrs["user"] as? String, "u1")
        XCTAssertEqual(attrs["service.name"] as? String, "test-svc")
        client.shutdown()
    }

    func testEmitJsonCarriesExplicitTraceIds() {
        let dir = tempQueueDir()
        let client = makeClient(queueDirectory: dir)
        client.emit(json: """
        {"ts":"2026-09-14T00:00:00.000Z","severity":9,"message":"m","attrs":{},
        "traceId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","spanId":"bbbbbbbbbbbbbbbb",
        "parentSpanId":"cccccccccccccccc"}
        """)
        let events = queuedEvents(dir)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["traceId"] as? String, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(events[0]["spanId"] as? String, "bbbbbbbbbbbbbbbb")
        XCTAssertEqual(events[0]["parentSpanId"] as? String, "cccccccccccccccc")
        client.shutdown()
    }

    func testMalformedEmitJsonDropsWithoutThrowing() {
        let dir = tempQueueDir()
        let client = makeClient(queueDirectory: dir)
        client.emit(json: "{not valid json")
        client.emit(json: #"{"noMessage":true}"#)
        XCTAssertEqual(queuedEvents(dir).count, 0)
        XCTAssertEqual(client.droppedCount, 2)
        client.shutdown()
    }

    func testInstallIDIsPublicAndStable() {
        let client = makeClient()
        XCTAssertFalse(client.installID.isEmpty)
        XCTAssertEqual(client.installID, client.installID)
        client.shutdown()
    }

    func testExternalTraceparentIsInjectedWhenNoTaskLocalTrace() {
        Stub.reset()
        URLSessionIntegration.enable()
        let client = makeClient()
        client.setExternalTraceparent("00-\(Self.hex("a", 32))-\(Self.hex("b", 16))-01")

        let session = stubSession()
        let done = expectation(description: "request completed")
        // The swizzle covers dataTask(with: URLRequest, completionHandler:) —
        // the URL convenience variant is documented as not covered.
        session.dataTask(with: URLRequest(url: URL(string: "https://app.example/api")!)) { _, _, _ in
            done.fulfill()
        }.resume()
        waitForExpectations(timeout: 5)

        XCTAssertEqual(
            Stub.recorded.first?.headers["traceparent"],
            "00-\(Self.hex("a", 32))-\(Self.hex("b", 16))-01"
        )
        client.setExternalTraceparent(nil)
        client.shutdown()
    }

    func testTaskLocalTraceWinsOverExternalTraceparent() {
        Stub.reset()
        URLSessionIntegration.enable()
        let client = makeClient()
        client.setExternalTraceparent("00-\(Self.hex("a", 32))-\(Self.hex("b", 16))-01")

        let session = stubSession()
        let done = expectation(description: "request completed")
        let taskLocal = TraceContext(
            traceID: Self.hex("d", 32),
            spanID: Self.hex("e", 16),
            parentSpanID: ""
        )
        Traces.$current.withValue(taskLocal) {
            session.dataTask(with: URLRequest(url: URL(string: "https://app.example/api")!)) { _, _, _ in
                done.fulfill()
            }.resume()
        }
        waitForExpectations(timeout: 5)

        // The ambient task-local trace wins over the external header.
        XCTAssertEqual(
            Stub.recorded.first?.headers["traceparent"],
            "00-\(Self.hex("d", 32))-\(Self.hex("e", 16))-01"
        )
        client.setExternalTraceparent(nil)
        client.shutdown()
    }
}
