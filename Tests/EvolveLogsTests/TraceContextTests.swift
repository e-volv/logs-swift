@testable import EvolveLogs
import XCTest

/// W3C traceparent propagation: queue hops, nesting, parent linkage, and
/// span/exception event shapes.
final class TraceContextTests: XCTestCase {
    let fixed = "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01"

    override func setUp() {
        Stub.reset()
    }

    func isValidHex(_ s: String, _ len: Int) -> Bool {
        s.count == len && s.allSatisfy { $0.isHexDigit }
    }

    func testTraceparentOutsideTraceIsEmpty() {
        let client = makeClient()
        XCTAssertEqual(client.traceparent(), "")
        client.shutdown()
    }

    func testQueueHopContinuesTheTrace() throws {
        let client = makeClient()
        client.runWithTraceparent(fixed) {
            let tp = client.traceparent()
            let parts = tp.split(separator: "-").map(String.init)
            XCTAssertEqual(parts.count, 4)
            XCTAssertEqual(parts[0], "00")
            XCTAssertEqual(parts[1], "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
            XCTAssertTrue(self.isValidHex(parts[2], 16))
            XCTAssertNotEqual(parts[2], "bbbbbbbbbbbbbbbb")
            client.log(severity: 9, message: "job received", attrs: ["jobId": "j_1"])
            let span = client.startSpan("queue.consume")
            span.end()
        }
        client.flush()
        let events = recordedEvents()
        XCTAssertEqual(events.count, 2)

        let logEvent = events[0]
        XCTAssertEqual(logEvent["traceId"] as? String, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(logEvent["parentSpanId"] as? String, "bbbbbbbbbbbbbbbb")
        let logSpanId = try XCTUnwrap(logEvent["spanId"] as? String)
        XCTAssertTrue(isValidHex(logSpanId, 16))
        XCTAssertNotEqual(logSpanId, "bbbbbbbbbbbbbbbb")

        let spanEvent = events[1]
        XCTAssertEqual(spanEvent["traceId"] as? String, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(spanEvent["parentSpanId"] as? String, logSpanId, "span nests under the log's span")
        XCTAssertTrue(isValidHex(try XCTUnwrap(spanEvent["spanId"] as? String), 16))
        client.shutdown()
    }

    func testMalformedHeaderStartsAFreshTrace() {
        let client = makeClient()
        client.runWithTraceparent("not-a-traceparent") {
            let tp = client.traceparent()
            let parts = tp.split(separator: "-")
            XCTAssertEqual(parts.count, 4)
            XCTAssertTrue(isValidHex(String(parts[1]), 32))
            XCTAssertTrue(isValidHex(String(parts[2]), 16))
            XCTAssertNotEqual(String(parts[1]), "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        }
        client.shutdown()
    }

    func testAllZeroIdsAreRejected() {
        XCTAssertNil(Traceparent.parse("00-00000000000000000000000000000000-0000000000000000-01"))
        XCTAssertNil(Traceparent.parse(""))
        XCTAssertNil(Traceparent.parse("00-xyz-abc-01"))
    }

    func testNestingCreatesParentLinkage() {
        let client = makeClient()
        client.runWithTraceparent(fixed) {
            let outer = client.startSpan("outer")
            Traces.$current.withValue(outer.context) {
                let inner = client.startSpan("inner")
                XCTAssertEqual(inner.context.traceID, outer.context.traceID)
                XCTAssertEqual(inner.context.parentSpanID, outer.context.spanID)
            }
        }
        client.shutdown()
    }

    func testSpanOkEventShape() throws {
        let client = makeClient()
        _ = client.span("db.query", attrs: ["table": "orders"]) {
            42
        }
        client.flush()
        let events = recordedEvents()
        XCTAssertEqual(events.count, 1)
        let event = events[0]
        XCTAssertEqual(event["severity"] as? Int, 9)
        XCTAssertEqual(event["message"] as? String, "span db.query completed")
        let attrs = try XCTUnwrap(event["attrs"] as? [String: Any])
        XCTAssertEqual(attrs["span.name"] as? String, "db.query")
        XCTAssertEqual(attrs["table"] as? String, "orders")
        XCTAssertNotNil(attrs["durationMs"])
        XCTAssertTrue(isValidHex(try XCTUnwrap(event["traceId"] as? String), 32))
        XCTAssertTrue(isValidHex(try XCTUnwrap(event["spanId"] as? String), 16))
        client.shutdown()
    }

    func testSpanErrorEndsFailedAndRethrows() throws {
        let client = makeClient()
        XCTAssertThrowsError(try client.span("charge") { () -> Int in
            throw SampleError(errorDescription: "upstream timeout")
        }) { error in
            XCTAssertEqual((error as? SampleError)?.errorDescription, "upstream timeout")
        }
        client.flush()
        let events = recordedEvents()
        XCTAssertEqual(events.count, 1)
        let event = events[0]
        XCTAssertEqual(event["severity"] as? Int, 17)
        XCTAssertEqual(event["message"] as? String, "span charge failed")
        let attrs = try XCTUnwrap(event["attrs"] as? [String: Any])
        XCTAssertEqual(attrs["span.name"] as? String, "charge")
        XCTAssertEqual(attrs["exception.type"] as? String, "SampleError")
        XCTAssertEqual(attrs["exception.message"] as? String, "upstream timeout")
        client.shutdown()
    }

    func testExceptionMapping() throws {
        let client = makeClient()
        client.exception(SampleError(errorDescription: "card declined"), attrs: ["orderId": "o_1"])
        client.flush()
        let event = try XCTUnwrap(recordedEvents().first)
        XCTAssertEqual(event["severity"] as? Int, 17)
        XCTAssertEqual(event["message"] as? String, "card declined")
        let attrs = try XCTUnwrap(event["attrs"] as? [String: Any])
        XCTAssertEqual(attrs["exception.type"] as? String, "SampleError")
        XCTAssertEqual(attrs["exception.message"] as? String, "card declined")
        XCTAssertFalse((attrs["exception.stack"] as? String ?? "").isEmpty)
        XCTAssertEqual(attrs["orderId"] as? String, "o_1")
        client.shutdown()
    }

    func testNSErrorUsesDomainAsType() throws {
        let client = makeClient()
        struct NotNSError {}
        let error = NSError(domain: "com.test.domain", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "cocoa failure",
        ])
        client.exception(error)
        client.flush()
        let attrs = try XCTUnwrap(recordedEvents().first?["attrs"] as? [String: Any])
        XCTAssertEqual(attrs["exception.type"] as? String, "com.test.domain")
        XCTAssertEqual(attrs["exception.message"] as? String, "cocoa failure")
        client.shutdown()
    }
}
