import Foundation
@testable import EvolveLogs
import XCTest

/**
 * Task A2 of the S6 plan: the snapshot and exposure-send entry points the
 * React Native bridge reads — `Flags.snapshotJSON()` (synchronous, no I/O)
 * and `Flags.sendExposures(json:)` (posts a cross-platform-recorded batch
 * through the exposure transport, requeuing like a local flush on failure).
 */
final class FlagsBridgeTests: XCTestCase {
    let key = "evk_pub_test_client"
    var queueDirectory: URL!

    override func setUp() {
        Stub.reset()
        queueDirectory = tempQueueDir()
    }

    private let valuesBody = """
    {"rulesetVersion":2,"environmentId":"flag_environment:test","etag":"etag-a","flags":\
    {"checkout.new":{"value":true,"variant":"on","reason":"RULE:0"},\
    "banner.copy":{"value":"Hello","variant":"a","reason":"DEFAULT"}}}
    """

    private func makeFlags(
        _ configure: (inout FlagsOptions) -> Void = { _ in }
    ) -> Flags {
        var options = FlagsOptions()
        configure(&options)
        return Flags(
            key: key,
            appID: "com.test.app",
            installID: "install-1",
            observerUrl: "https://stub.evolv.test/api/public/v1/logs",
            options: options,
            session: stubSession(),
            queueDirectory: queueDirectory,
            transport: Transport(
                url: URL(string: "https://stub.evolv.test/api/public/v1/logs")!,
                key: key,
                appID: "com.test.app",
                installID: "install-1",
                session: stubSession()
            ),
            enabled: true
        )
    }

    private func parse(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }

    func testSnapshotIsNullBeforeAnyFetch() {
        let flags = makeFlags { $0.offline = true }
        let snapshot = parse(flags.snapshotJSON())
        XCTAssertTrue(snapshot["values"] is NSNull)
        XCTAssertTrue(snapshot["environmentId"] is NSNull)
        XCTAssertTrue(snapshot["updatedAt"] is NSNull)
        flags.close()
    }

    func testSnapshotServesValuesAfterFetch() async throws {
        Stub.respond(200, body: valuesBody)
        let flags = makeFlags()
        let ready = await flags.ready(timeout: 5)
        XCTAssertTrue(ready)
        let snapshot = parse(flags.snapshotJSON())
        let values = try XCTUnwrap(snapshot["values"] as? [String: Any])
        let entry = try XCTUnwrap(values["checkout.new"] as? [String: Any])
        XCTAssertEqual(entry["value"] as? Bool, true)
        XCTAssertEqual(entry["variant"] as? String, "on")
        XCTAssertEqual(entry["reason"] as? String, "RULE:0")
        XCTAssertEqual(snapshot["environmentId"] as? String, "flag_environment:test")
        XCTAssertNotNil(snapshot["updatedAt"] as? Double)
        flags.close()
    }

    func testSendExposuresPostsTheDecodedBatch() async throws {
        Stub.reset()
        let flags = makeFlags { $0.offline = true }
        // Returns at once (the bridges call it from the Flutter platform
        // thread and the React Native module queue); the task completes when
        // the batch is delivered or requeued.
        let delivery = flags.sendExposures(json:
            """
            {"exposures":[
              {"id":"e1","ts":"2026-09-14T00:00:00.000Z","flagKey":"checkout.new","variant":"on",
               "reason":"RULE:0","contextKind":"user","subject":"u1"}
            ]}
            """
        )
        await delivery.value
        let request = try XCTUnwrap(
            Stub.recorded.first { $0.url.path.hasSuffix("/flags/exposures") },
            "the bridged batch posts to /exposures"
        )
        XCTAssertEqual(request.headers["Authorization"], "Bearer \(key)")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )
        let batch = try XCTUnwrap(body["exposures"] as? [[String: Any]])
        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(batch[0]["flagKey"] as? String, "checkout.new")
        XCTAssertEqual(batch[0]["subject"] as? String, "u1")
        flags.close()
    }

    func testSendExposuresRequeuesOnOutageAndMalformedJsonDrops() async throws {
        Stub.respond(500, body: "{}")
        let flags = makeFlags { $0.offline = true }
        await flags.sendExposures(json:
            """
            {"exposures":[
              {"id":"e1","ts":"2026-09-14T00:00:00.000Z","flagKey":"checkout.new","reason":"RULE:0","contextKind":"user"},
              {"id":"e2","ts":"2026-09-14T00:00:00.000Z","flagKey":"banner.copy","reason":"DEFAULT","contextKind":"user"}
            ]}
            """
        ).value
        // The outage requeued the batch — nothing delivered, nothing lost.
        XCTAssertTrue(Stub.recorded.filter { $0.url.path.hasSuffix("/flags/exposures") }.count >= 1)

        Stub.reset()
        await flags.flushExposures()
        let delivered = Stub.recorded.filter { $0.url.path.hasSuffix("/flags/exposures") }
        let last = try XCTUnwrap(delivered.last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: last.body) as? [String: Any])
        let batch = try XCTUnwrap(body["exposures"] as? [[String: Any]])
        XCTAssertEqual(batch.count, 2, "the requeued batch flushes whole on recovery")

        // Malformed input never throws and touches nothing.
        let before = Stub.recorded.count
        await flags.sendExposures(json: "{not json").value
        await flags.sendExposures(json: "{\"noExposures\":[]}").value
        XCTAssertEqual(Stub.recorded.count, before)
        flags.close()
    }

    func testSendExposuresOnDisabledFlagsIsANoOp() async {
        Stub.reset()
        let flags = Flags.disabled()
        await flags.sendExposures(json:
            """
            {"exposures":[{"id":"e1","ts":"2026-09-14T00:00:00.000Z","flagKey":"k","reason":"DEFAULT","contextKind":"user"}]}
            """
        ).value
        XCTAssertTrue(Stub.recorded.isEmpty)
        flags.close()
    }
}
