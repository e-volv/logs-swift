import EvolveLogsC
@testable import EvolveLogs
import XCTest

/// Disk queue persistence and caps, session id on every event, the key
/// kind gate, and the crash-time write path (written on "crash", sent on
/// next launch, breadcrumbs attached).
final class DiskAndCrashTests: XCTestCase {
    override func setUp() {
        Stub.reset()
    }

    func testDiskQueueByteCapDropsOldest() throws {
        let dir = tempQueueDir()
        let queue = try DiskQueue(directory: dir, byteCap: 1_000)
        let payload = Data(repeating: UInt8(ascii: "x"), count: 200)
        for _ in 0 ..< 10 {
            queue.append(payload)
        }
        let remaining = queue.peek(maxEvents: 100, maxBytes: 100_000)
        XCTAssertEqual(remaining.count, 5, "byte cap evicts oldest files first")
        queue.remove(remaining.map(\.name))
    }

    func testSessionIdAndServiceAttrsOnEveryEvent() throws {
        let client = makeClient()
        client.log(severity: 9, message: "hello", attrs: [:])
        let file = queuedEvents(client.queue.directory).first
        let attrs = try XCTUnwrap(file?["attrs"] as? [String: Any])
        XCTAssertEqual(attrs["service.name"] as? String, "test-svc")
        XCTAssertEqual(attrs["deployment.environment"] as? String, "test")
        XCTAssertEqual(attrs["service.release"] as? String, "abc123")
        XCTAssertEqual(attrs["session.id"] as? String, client.sessionID)
        XCTAssertFalse(client.sessionID.isEmpty)
        client.shutdown()
    }

    func testServerKeyIsRefused() {
        let client = LogsClient(options: EvolveLogsOptions(
            key: "evk_live_server_key",
            url: "https://api.e-volv.io/api/public/v1/logs",
            service: "s",
            queueDirectory: tempQueueDir(),
            captureCrashes: false,
            urlSessionInstrumentation: false,
            session: stubSession(),
            enableSessionEvents: false
        ))
        XCTAssertFalse(client.enabled)
        client.log(severity: 9, message: "dropped")
        XCTAssertTrue(queuedEvents(client.queue.directory).isEmpty)
        client.shutdown()
    }

    func testPublicKeyIsAccepted() {
        let client = LogsClient(options: EvolveLogsOptions(
            key: "evk_pub_mobile_key",
            url: "https://api.e-volv.io/api/public/v1/logs",
            service: "s",
            queueDirectory: tempQueueDir(),
            captureCrashes: false,
            urlSessionInstrumentation: false,
            session: stubSession(),
            enableSessionEvents: false
        ))
        XCTAssertTrue(client.enabled)
        client.shutdown()
    }

    func testInstallIDIsGeneratedAndPersisted() {
        let url = tempQueueDir().appendingPathComponent("install-id")
        let store = FileInstallIDStore(url: url)
        let first = InstallIDs.resolve(using: store)
        XCTAssertEqual(first, InstallIDs.resolve(using: store), "stable across calls")
        XCTAssertEqual(first.count, 36, "UUID format")
        XCTAssertEqual(FileInstallIDStore(url: url).load(), first, "survives a new store over the same file")
    }

    /// The async-signal-safe crash write path: the C buffer holds a
    /// pre-serialized event (session + breadcrumbs); the "handler"
    /// formats only the exception fields; the file lands on the queue and
    /// a fresh client sends it on next launch.
    func testCrashFileIsWrittenAndSentOnNextLaunch() throws {
        let queueDirectory = tempQueueDir()
        // Deliveries fail while we build the crash: everything must stay
        // on the disk queue, as it would after a real crash.
        Stub.reset((500, [:]))
        let crashed = makeClient(queueDirectory: queueDirectory, captureCrashes: true)
        for i in 0 ..< 3 {
            crashed.log(severity: 9, message: "crumb-\(i)")
        }
        // Bake the current session + breadcrumbs into the pre-serialized
        // crash event, then simulate the handler body (what
        // evolveHandleUncaughtException calls after escaping name/reason):
        crashed.refreshCrashBuffer()
        let written = "NSException".withCString { name in
            "boom".withCString { reason in
                evolve_crash_buffer_write_exception(name, reason)
            }
        }
        XCTAssertGreaterThan(written, 0)
        crashed.shutdown()
        _ = crashed

        // "Next launch": the crash file is on the queue before any new event.
        let eventsBefore = queuedEvents(queueDirectory)
        XCTAssertEqual(eventsBefore.count, 4, "3 crumbs + the crash file")

        Stub.reset()
        let relaunched = makeClient(queueDirectory: queueDirectory)
        relaunched.flush()
        let all = recordedEvents()
        XCTAssertEqual(all.count, 4)
        let crash = try XCTUnwrap(all.first { ($0["attrs"] as? [String: Any])?["crash"] as? Bool == true })
        XCTAssertEqual(crash["severity"] as? Int, 21)
        let attrs = try XCTUnwrap(crash["attrs"] as? [String: Any])
        XCTAssertEqual(attrs["exception.type"] as? String, "NSException")
        XCTAssertEqual(attrs["exception.message"] as? String, "boom")
        let breadcrumbs = try XCTUnwrap(attrs["breadcrumbs"] as? [[String: Any]])
        XCTAssertEqual(breadcrumbs.count, 3, "the last buffered events ship with the crash")
        XCTAssertEqual(breadcrumbs.last?["message"] as? String, "crumb-2")
        relaunched.shutdown()
    }

    func testSignalCrashPathWritesValidJSON() throws {
        let queueDirectory = tempQueueDir()
        let client = makeClient(queueDirectory: queueDirectory, captureCrashes: true)
        client.refreshCrashBuffer()
        let written = evolve_crash_buffer_write_signal(SIGSEGV, 2, 0xdeadbeef)
        XCTAssertGreaterThan(written, 0)
        let data = try Data(contentsOf: queueDirectory.appendingPathComponent("queue-crash-pending.json"))
        // The crash file is a single event, like every other queue file.
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["severity"] as? Int, 21)
        XCTAssertEqual(obj["message"] as? String, "app crash")
        let attrs = try XCTUnwrap(obj["attrs"] as? [String: Any])
        XCTAssertEqual(attrs["exception.type"] as? String, "signal")
        client.shutdown()
    }
}
