import EvolveLogs
import Foundation

/*
 * Command conformance-runner is the Swift SDK's conformance runner
 * (packages/logs-conformance/runner-protocol.md): it reads the fixture path
 * from argv, points the SDK at the stub ingest via EVOLVE_STUB_INGEST_URL,
 * plays `calls`, flushes and exits 0. It never reads `expected` — the
 * orchestrator judges the recorded events.
 */

// Named error types so the SDK's type naming yields the fixture's pinned
// exception.type values.
struct CheckoutError: Error, LocalizedError {
    var errorDescription: String?
}

struct GatewayError: Error, LocalizedError {
    var errorDescription: String?
}

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("conformance-runner: \(message)\n".utf8))
    exit(code)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fail("usage: conformance-runner <fixture.json> with EVOLVE_STUB_INGEST_URL set", 2)
}
guard let stubURL = ProcessInfo.processInfo.environment["EVOLVE_STUB_INGEST_URL"],
      !stubURL.isEmpty
else {
    fail("EVOLVE_STUB_INGEST_URL is not set", 2)
}
guard let fixtureRaw = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
      let fixture = try? JSONSerialization.jsonObject(with: fixtureRaw) as? [String: Any],
      let initOpts = fixture["init"] as? [String: Any],
      let key = initOpts["key"] as? String,
      let service = initOpts["service"] as? String,
      let calls = fixture["calls"] as? [[String: Any]]
else {
    fail("cannot read fixture at \(args[1])", 2)
}

let queueDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("evolve-conformance-\(UUID().uuidString)")

let options = EvolveLogsOptions(
    key: key,
    url: stubURL,
    service: service,
    environment: initOpts["environment"] as? String ?? "",
    release: initOpts["release"] as? String ?? "",
    redactKeys: initOpts["redactKeys"] as? [String] ?? [],
    appID: "com.evolv.conformance",
    queueDirectory: queueDirectory,
    // The fixture key is server-shaped; the runner opts in explicitly
    // (production apps cannot — see EvolveLogsOptions).
    allowServerKeyForTesting: true,
    enableSessionEvents: false,
    enableSessionID: false
)
let client = EvolveLogs.initialize(options)

func severityNumber(_ name: String) -> Int {
    switch name {
    case "trace": return 1
    case "debug": return 5
    case "info": return 9
    case "warn": return 13
    case "error": return 17
    case "fatal": return 21
    default: return 9
    }
}

let fixedTraceparent = fixture["fixedTraceparent"] as? String ?? ""

for (index, call) in calls.enumerated() {
    guard let verb = call["do"] as? String else {
        fail("call \(index): missing verb", 1)
    }
    switch verb {
    case "log":
        client.log(
            severity: severityNumber(call["severity"] as? String ?? "info"),
            message: call["message"] as? String ?? "",
            attrs: call["attrs"] as? [String: Any] ?? [:]
        )
    case "exception":
        let type = call["type"] as? String ?? "Error"
        let message = call["message"] as? String ?? ""
        let error: Error = type == "GatewayError"
            ? GatewayError(errorDescription: message)
            : CheckoutError(errorDescription: message)
        client.exception(error, attrs: call["attrs"] as? [String: Any] ?? [:])
    case "spanOk":
        let handle = client.startSpan(
            call["name"] as? String ?? "span",
            attrs: call["attrs"] as? [String: Any] ?? [:]
        )
        handle.end()
    case "spanError":
        let name = call["name"] as? String ?? "span"
        let errorInfo = call["error"] as? [String: Any] ?? [:]
        let type = errorInfo["type"] as? String ?? "Error"
        let message = errorInfo["message"] as? String ?? ""
        let error: Error = type == "GatewayError"
            ? GatewayError(errorDescription: message)
            : CheckoutError(errorDescription: message)
        do {
            _ = try client.span(name) { () -> Int in
                throw error
            }
            fail("call \(index): span body did not throw", 1)
        } catch {
            // The span ended failed before the error propagated; the stub
            // comparison asserts it. Caught and continued per protocol.
        }
    case "queueHop":
        let logInfo = call["log"] as? [String: Any] ?? [:]
        client.runWithTraceparent(fixedTraceparent) {
            client.log(
                severity: severityNumber(logInfo["severity"] as? String ?? "info"),
                message: logInfo["message"] as? String ?? "",
                attrs: logInfo["attrs"] as? [String: Any] ?? [:]
            )
            let handle = client.startSpan(call["span"] as? String ?? "queue.consume")
            handle.end()
        }
    default:
        fail("call \(index): unknown fixture call \(verb)", 1)
    }
}

client.flush()

// An unflushable buffer is a deviation from the protocol: nothing may
// remain on the disk queue.
let remaining = ((try? FileManager.default.contentsOfDirectory(
    atPath: queueDirectory.path
)) ?? []).filter { $0.hasPrefix("queue-") && $0.hasSuffix(".json") }
if !remaining.isEmpty {
    fail("flush left \(remaining.count) event(s) on the disk queue", 1)
}
exit(0)
