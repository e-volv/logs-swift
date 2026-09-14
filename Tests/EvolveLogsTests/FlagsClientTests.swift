import Foundation
@testable import EvolveLogs
import XCTest

/// The client flags behaviours (S5 plan Task A2 Step 1): the eleven S4
/// client-flags behaviours with the mobile header set, plus concurrency.
/// The stub speaks HTTP through StubURLProtocol exactly like the ingest
/// tests; the flags body fixtures mirror the conformance stub's RULESET_A
/// evaluated values.
final class FlagsClientTests: XCTestCase {
    let key = "evk_pub_test_client"
    var queueDirectory: URL!
    var cacheDirectory: URL!

    override func setUp() {
        queueDirectory = tempQueueDir()
        cacheDirectory = queueDirectory.appendingPathComponent("flags", isDirectory: true)
    }

    private let valuesBody = """
    {"rulesetVersion":2,"environmentId":"flag_environment:test","etag":"etag-a","flags":\
    {"checkout.new":{"value":true,"variant":"on","reason":"RULE:0"},\
    "banner.copy":{"value":"Hello","variant":"a","reason":"DEFAULT"},\
    "price":{"value":2.5,"variant":"p","reason":"DEFAULT"}}}
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

    /// The bootstrap requests the stub recorded, newest last.
    private func bootstrapRequests() -> [(url: URL, headers: [String: String], body: Data)] {
        Stub.recorded.filter { $0.url.path.hasSuffix("/flags/bootstrap") }
    }

    func testIdentifyRequestShape() async throws {
        Stub.respond(200, body: valuesBody)
        let flags = makeFlags()
        let identified = await flags.identify(["targetingKey": "u1", "plan": "pro"])
        XCTAssertTrue(identified)
        // The init fetch (empty initial context) fires first; identify adds
        // a second request carrying the new context.
        let request = try XCTUnwrap(bootstrapRequests().last)
        XCTAssertEqual(request.url.path, "/api/public/v1/flags/bootstrap")
        XCTAssertEqual(request.headers["Authorization"], "Bearer \(key)")
        XCTAssertEqual(request.headers["x-evolve-app-id"], "com.test.app")
        XCTAssertEqual(request.headers["x-evolve-install-id"], "install-1")
        XCTAssertEqual(request.headers["User-Agent"], "e-volv-logs-swift/\(Constants.sdkVersion)")
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
        let context = components.queryItems?.first { $0.name == "context" }?.value
        let parsed = try XCTUnwrap(context.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any])
        XCTAssertEqual(parsed["targetingKey"] as? String, "u1")
        XCTAssertEqual(parsed["plan"] as? String, "pro")
        flags.close()
    }

    func testTypedReadsAndTypeMismatch() async throws {
        Stub.respond(200, body: valuesBody)
        let flags = makeFlags()
        let ready = await flags.ready(timeout: 2)
        XCTAssertTrue(ready)
        XCTAssertEqual(flags.bool("checkout.new", default: false), true)
        XCTAssertEqual(flags.string("banner.copy", default: "x"), "Hello")
        XCTAssertEqual(flags.number("price", default: 0), 2.5)
        // A string flag read as a bool: caller's default with TYPE_MISMATCH
        // semantics — the typed read returns the default and, unlike a
        // matching read, records no exposure.
        XCTAssertEqual(flags.bool("banner.copy", default: false), false)
        XCTAssertEqual(flags.exposures.pending, 3, "only the three matching reads recorded")
        flags.close()
    }

    func testCacheEnvelopeWritten() async throws {
        Stub.respond(200, body: valuesBody)
        let flags = makeFlags()
        let ready = await flags.ready(timeout: 2)
        XCTAssertTrue(ready)
        let name = "evolve-flags-\(ContextFit.sha1Hex(key).prefix(12)).json"
        let url = cacheDirectory.appendingPathComponent(name)
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(envelope["formatVersion"] as? Int, 1)
        XCTAssertEqual(envelope["kind"] as? String, "values")
        XCTAssertEqual(envelope["environmentId"] as? String, "flag_environment:test")
        let payload = envelope["payload"] as? [String: Any]
        XCTAssertNotNil(payload?["contextFingerprint"] as? String)
        XCTAssertNotNil(payload?["flags"] as? [String: Any])
        flags.close()
    }

    func testColdStartServesCache() async throws {
        Stub.respond(200, body: valuesBody)
        let first = makeFlags()
        let firstReady = await first.ready(timeout: 2)
        XCTAssertTrue(firstReady)
        first.close()
        // Fresh client, same cache dir; the control plane now fails.
        Stub.respond(500, body: #"{"message":"boom"}"#)
        let second = makeFlags()
        let started = Date()
        XCTAssertEqual(second.bool("checkout.new", default: false), true, "L5: cache serves the cold start")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "cache reads are instant")
        second.close()
    }

    func testCorruptCacheStartsClean() async throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let name = "evolve-flags-\(ContextFit.sha1Hex(key).prefix(12)).json"
        try Data(#"{"formatVersion":9,"kind":"values","environmentId":"x","rulesetVersion":2,"etag":"x","savedAt":"2026-09-13T00:00:00.000Z","payload":{}}"#.utf8)
            .write(to: cacheDirectory.appendingPathComponent(name))
        Stub.respond(500, body: #"{"message":"boom"}"#)
        let flags = makeFlags()
        let detail = flags.detail("checkout.new", default: .bool(false))
        XCTAssertEqual(detail.reason, "FLAG_NOT_FOUND")
        XCTAssertEqual(detail.value, .bool(false))
        flags.close()
    }

    func testPollKeepsValuesThrough500() async throws {
        Stub.respond(200, body: valuesBody)
        let flags = makeFlags { $0.unclampedPollInterval = 0.2 }
        let ready = await flags.ready(timeout: 2)
        XCTAssertTrue(ready)
        Stub.respond(500, body: #"{"message":"boom"}"#)
        try await Task.sleep(nanoseconds: 600_000_000) // three poll periods
        for _ in 0 ..< 5 {
            XCTAssertEqual(flags.bool("checkout.new", default: false), true, "L2: held values survive 5xx")
        }
        flags.close()
    }

    func testScope403DisablesFlags() async throws {
        Stub.respond(200, body: valuesBody)
        let flags = makeFlags { $0.unclampedPollInterval = 0.2 }
        let ready = await flags.ready(timeout: 2)
        XCTAssertTrue(ready)
        Stub.respond(403, body: #"{"message":"This key lacks the scope flags:read."}"#)
        try await Task.sleep(nanoseconds: 600_000_000)
        let afterScope = bootstrapRequests().count
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(bootstrapRequests().count, afterScope, "no retries after a scope refusal")
        // Held values keep serving after a scope refusal (telemetry is
        // unaffected too); reads never throw.
        XCTAssertEqual(flags.bool("checkout.new", default: false), true)
        flags.close()
    }

    func testOrigin403LogsAccessActionOnceAndPauses() async throws {
        let stderr = StderrCapture()
        Stub.respond(403, body: #"{"message":"this app id is refused"}"#)
        let flags = makeFlags()
        _ = await flags.identify(["targetingKey": "u1"])
        let output = stderr.finish()
        XCTAssertEqual(output.components(separatedBy: "Access action").count - 1, 1, "one Access warning")
        let before = bootstrapRequests().count
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(bootstrapRequests().count, before, "app-id refusal pauses retries")
        flags.close()
    }

    func testUnknown403LogsOutageOnceAndKeepsPolling() async throws {
        let stderr = StderrCapture()
        Stub.respond(403, body: #"{"message":"request blocked by the edge"}"#)
        let flags = makeFlags { $0.unclampedPollInterval = 0.2 }
        _ = await flags.identify(["targetingKey": "u1"])
        let output = stderr.finish()
        XCTAssertEqual(
            output.components(separatedBy: "control plane returned 403").count - 1,
            1,
            "one outage line for the unrecognised 403"
        )
        let before = bootstrapRequests().count
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertGreaterThan(
            bootstrapRequests().count,
            before,
            "an unrecognised 403 is an outage, not a refusal — the normal poll continues"
        )
        flags.close()
    }

    func testPrivateAttributesStripped() async throws {
        Stub.respond(200, body: valuesBody)
        let flags = makeFlags { $0.privateAttributes = ["email"] }
        _ = await flags.identify(["targetingKey": "u1", "email": "a@b.c", "plan": "pro"])
        let request = try XCTUnwrap(bootstrapRequests().last)
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
        let context = components.queryItems?.first { $0.name == "context" }?.value
        let parsed = try XCTUnwrap(context.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any])
        XCTAssertNil(parsed["email"], "private attributes never leave the SDK")
        XCTAssertEqual(parsed["plan"] as? String, "pro")
        flags.close()
    }

    func testExposuresDedupeAndFlush() async throws {
        Stub.respond(200, body: valuesBody)
        let flags = makeFlags()
        _ = await flags.identify(["targetingKey": "beta-1", "plan": "pro"])
        let ready = await flags.ready(timeout: 2)
        XCTAssertTrue(ready)
        for _ in 0 ..< 50 { _ = flags.bool("checkout.new", default: false) }
        await flags.flushExposures()
        let posts = Stub.recorded.filter { $0.url.path.hasSuffix("/flags/exposures") }
        XCTAssertEqual(posts.count, 1, "one flush sends one batch")
        let body = try XCTUnwrap(posts.first.flatMap { try? JSONSerialization.jsonObject(with: $0.body) } as? [String: Any])
        let exposures = try XCTUnwrap(body["exposures"] as? [[String: Any]])
        XCTAssertEqual(exposures.count, 1, "50 evals dedupe to one exposure inside the window")
        XCTAssertEqual(exposures[0]["flagKey"] as? String, "checkout.new")
        XCTAssertEqual(exposures[0]["variant"] as? String, "on")
        XCTAssertEqual(exposures[0]["reason"] as? String, "RULE:0")
        XCTAssertEqual(exposures[0]["subject"] as? String, "beta-1")
        XCTAssertNotNil(exposures[0]["id"] as? String)
        XCTAssertNotNil(exposures[0]["ts"] as? String)
        // A second flush with nothing new adds nothing.
        await flags.flushExposures()
        XCTAssertEqual(Stub.recorded.filter { $0.url.path.hasSuffix("/flags/exposures") }.count, 1)
        flags.close()
    }

    /// §7 subject precedence is key-first, the same as evaluation: a
    /// context carrying both `key` and `targetingKey` records `key`.
    func testExposureSubjectPrefersKeyOverTargetingKey() {
        let recorder = ExposureRecorder(
            enabled: true,
            sampleRate: 1,
            dedupeWindowSeconds: 300,
            sendAttributes: false,
            privateAttributes: []
        )
        recorder.record(
            flagKey: "f",
            variant: nil,
            reason: "DEFAULT",
            context: .object([
                ("kind", .string("user")),
                ("key", .string("k-1")),
                ("targetingKey", .string("tk-1")),
            ])
        )
        let batch = recorder.drain()
        XCTAssertEqual(batch[0]["subject"] as? String, "k-1")
    }

    /// §2.4: the field limits count code points and a cut never splits a
    /// surrogate pair — an astral character straddling the 200-code-point
    /// subject limit survives whole (a UTF-16 cut would leave a lone
    /// surrogate).
    func testExposureFieldsClipByCodePointsWithoutSplittingPairs() throws {
        let recorder = ExposureRecorder(
            enabled: true,
            sampleRate: 1,
            dedupeWindowSeconds: 300,
            sendAttributes: false,
            privateAttributes: []
        )
        let longKey = String(repeating: "a", count: 199) + "😀" + "z"
        recorder.record(
            flagKey: String(repeating: "f", count: 65),
            variant: String(repeating: "v", count: 61),
            reason: "RULE:0",
            context: .object([("key", .string(longKey))])
        )
        let row = try XCTUnwrap(recorder.drain().first)
        let subject = try XCTUnwrap(row["subject"] as? String)
        XCTAssertEqual(subject.unicodeScalars.count, 200)
        XCTAssertTrue(subject.hasSuffix("😀"), "the surrogate pair stays whole")
        XCTAssertFalse(subject.hasSuffix("z"))
        XCTAssertEqual(try XCTUnwrap(row["flagKey"] as? String).unicodeScalars.count, 64)
        XCTAssertEqual(try XCTUnwrap(row["variant"] as? String).unicodeScalars.count, 60)
    }

    func testOnChangeReportsChangedKeys() async throws {
        Stub.respond(200, body: valuesBody)
        let flags = makeFlags { $0.unclampedPollInterval = 0.2 }
        let ready = await flags.ready(timeout: 2)
        XCTAssertTrue(ready)
        var changes: [String] = []
        let subscription = flags.onChange { keys in changes.append(contentsOf: keys) }
        Stub.respond(200, body: """
        {"rulesetVersion":2,"environmentId":"flag_environment:test","etag":"etag-b","flags":\
        {"checkout.new":{"value":false,"variant":"off","reason":"DEFAULT"}}}
        """)
        let deadline = Date().addingTimeInterval(3)
        while changes.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(changes, ["banner.copy", "checkout.new", "price"], "changed and removed keys are all reported")
        subscription.cancel()
        Stub.respond(200, body: valuesBody)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(changes, ["banner.copy", "checkout.new", "price"], "cancelled subscriptions stop firing")
        flags.close()
    }

    func testOfflineBootstrapServesWithoutNetwork() async throws {
        Stub.reset()
        let flags = makeFlags {
            $0.offline = true
            $0.bootstrap = [
                "checkout.new": Evaluation(value: .bool(true), variant: "on", reason: "RULE:0"),
            ]
        }
        let ready = await flags.ready(timeout: 0.1)
        XCTAssertTrue(ready, "bootstrap + offline is ready at once")
        XCTAssertEqual(flags.bool("checkout.new", default: false), true)
        XCTAssertEqual(flags.mode, "offline")
        XCTAssertTrue(Stub.recorded.isEmpty, "offline never contacts the control plane")
        flags.close()
    }

    func testReadyWaitsForNetworkConfirmation() async throws {
        // Nothing held and a hanging stub: ready times out false; reads
        // answer defaults instantly (L6).
        Stub.respond(500, body: #"{"message":"boom"}"#)
        let flags = makeFlags()
        let started = Date()
        let ready = await flags.ready(timeout: 0.3)
        XCTAssertFalse(ready)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3)
        let detail = flags.detail("checkout.new", default: .bool(false))
        XCTAssertEqual(detail.reason, "FLAG_NOT_FOUND")
        flags.close()
    }

    func testConcurrentReadsDuringRefreshes() async throws {
        Stub.respond(200, body: valuesBody)
        let flags = makeFlags { $0.unclampedPollInterval = 0.1 }
        _ = await flags.identify(["targetingKey": "beta-1"])
        let ready = await flags.ready(timeout: 2)
        XCTAssertTrue(ready)

        let refreshTask = Task {
            for _ in 0 ..< 50 {
                await flags.refreshIfStale()
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        var readTasks: [Task<Int, Never>] = []
        for _ in 0 ..< 32 {
            readTasks.append(Task {
                var count = 0
                for _ in 0 ..< 5_000 {
                    if flags.bool("checkout.new", default: false) { count += 1 }
                }
                return count
            })
        }
        var total = 0
        for task in readTasks { total += await task.value }
        XCTAssertEqual(total, 32 * 5_000, "every read returns the held value; no crash, no default leak")
        await refreshTask.value
        flags.close()
    }
}

/// Redirects stderr to a pipe for the duration of a test so the log-once
/// assertions can read what the SDK wrote (dup2(FileHandle.standardError)
/// would observe FileHandle's own writes as well, so this swaps the fd).
final class StderrCapture {
    private let pipe = Pipe()
    private var saved: Int32 = -1

    init() {
        saved = dup(STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
    }

    /// Restores stderr and returns everything written while captured.
    func finish() -> String {
        dup2(saved, STDERR_FILENO)
        close(saved)
        pipe.fileHandleForWriting.closeFile()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
