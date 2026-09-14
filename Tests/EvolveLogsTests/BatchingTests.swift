import EvolveLogsC
@testable import EvolveLogs
import XCTest

/// Batching thresholds, drop-oldest with the visible counter, retry-after
/// handling, 413 halving, and gzip + envelope shape on the wire.
final class BatchingTests: XCTestCase {
    func testAutoFlushesAt200Events() {
        Stub.reset()
        let client = makeClient()
        for i in 0 ..< 200 {
            client.log(severity: 9, message: "m\(i)")
        }
        let requests = Stub.recorded
        XCTAssertEqual(requests.count, 1, "200 events trigger exactly one flush")
        let events = recordedEvents()
        XCTAssertEqual(events.count, 200)
        XCTAssertEqual(events.first?["message"] as? String, "m0")
        XCTAssertEqual(events.last?["message"] as? String, "m199")
        XCTAssertEqual(requests.first?.headers["Authorization"], "Bearer evk_test_conformance")
        XCTAssertEqual(requests.first?.headers["x-evolve-app-id"], "com.test.app")
        XCTAssertFalse((requests.first?.headers["x-evolve-install-id"] ?? "").isEmpty)
        client.shutdown()
    }

    func testDropOldestPast2xBatchWithCounter() {
        Stub.reset((500, [:])) // deliveries fail; the queue backs up
        let client = makeClient()
        for i in 0 ..< 450 {
            client.log(severity: 9, message: "m\(i)")
        }
        XCTAssertEqual(client.droppedCount, 50, "oldest 50 evicted past 2× the batch size")
        client.shutdown() // no-op flush against the 500-ing stub; files stay

        // Drain through a fresh client (the "next launch"): only the newest
        // 400 survive, oldest-first.
        Stub.reset()
        let relaunched = makeClient(queueDirectory: client.queue.directory)
        relaunched.flush()
        let events = recordedEvents()
        XCTAssertEqual(events.count, 400)
        XCTAssertEqual(events.first?["message"] as? String, "m50")
        XCTAssertEqual(events.last?["message"] as? String, "m449")
        relaunched.shutdown()
    }

    func testRetryAfterIsHonoured() {
        // First request throttled with Retry-After: 0, second accepted.
        Stub.responses = [(429, ["Retry-After": "0"], nil), (202, [:], nil)]
        Stub.lock.lock(); Stub.requests = []; Stub.lock.unlock()
        let client = makeClient()
        client.log(severity: 9, message: "throttled once")
        client.flush()
        XCTAssertEqual(Stub.recorded.count, 2, "429 retried once")
        // The throttled request was recorded too; the retry delivered it.
        let last = Stub.recorded.last.map { request -> [[String: Any]] in
            let bound = request.body.count * 64 + 65_536
            let out = UnsafeMutableRawBufferPointer.allocate(byteCount: bound, alignment: 1)
            defer { out.deallocate() }
            let n = request.body.withUnsafeBytes { raw -> Int in
                Int(evolve_gunzip(
                    raw.bindMemory(to: UInt8.self).baseAddress,
                    request.body.count,
                    out.bindMemory(to: UInt8.self).baseAddress,
                    bound
                ))
            }
            guard n > 0 else { return [] }
            return ((try? JSONSerialization.jsonObject(with: Data(out[..<n]))) as? [String: Any])?["events"] as? [[String: Any]] ?? []
        } ?? []
        XCTAssertEqual(last.count, 1, "event delivered after the retry")
        client.shutdown()
    }

    func testBackoffMath() {
        XCTAssertEqual(Backoff.delay(attempt: 1, retryAfter: "2"), 2_000_000_000)
        XCTAssertEqual(Backoff.delay(attempt: 1, retryAfter: nil), 500_000_000)
        XCTAssertEqual(Backoff.delay(attempt: 2, retryAfter: nil), 1_000_000_000)
        XCTAssertEqual(Backoff.delay(attempt: 3, retryAfter: nil), 2_000_000_000)
        XCTAssertEqual(Backoff.delay(attempt: 30, retryAfter: nil), 10_000_000_000, "capped at 10 s")
    }

    func test413HalvesAndCounts() {
        Stub.reset((413, [:]))
        let queueDirectory = tempQueueDir()
        let client = makeClient(queueDirectory: queueDirectory)
        for i in 0 ..< 4 {
            client.log(severity: 9, message: "m\(i)")
        }
        client.flush()
        // 4 → 413 → halve to 2 (drop 2) → 413 → halve to 1 (drop 1) → 413
        // with a single event: left on disk.
        XCTAssertEqual(client.droppedCount, 3)
        XCTAssertEqual(queuedEvents(queueDirectory).count, 1, "the last event stays on disk")
        client.shutdown()
    }

    func testEventsSurviveProcessDeath() {
        Stub.reset()
        let queueDirectory = tempQueueDir()
        let client = makeClient(queueDirectory: queueDirectory)
        for i in 0 ..< 3 {
            client.log(severity: 9, message: "persisted-\(i)")
        }
        // No flush: the events exist only on disk. "Kill" the process by
        // dropping the client and building a new one over the same dir.
        client.shutdown()
        _ = client

        let relaunched = makeClient(queueDirectory: queueDirectory)
        relaunched.flush()
        let events = recordedEvents()
        XCTAssertEqual(events.map { $0["message"] as? String }, ["persisted-0", "persisted-1", "persisted-2"])
        relaunched.shutdown()
    }
}
