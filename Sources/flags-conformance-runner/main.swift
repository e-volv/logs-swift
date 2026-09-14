import EvolveLogs
import Foundation

/*
 * The Swift SDK's Launch delivery conformance runner
 * (docs/LAUNCH-SDK.md §9.2): one JSON command per stdin line, one JSON
 * reply per stdout line; SDK diagnostics go to stderr. Client kind only.
 *
 * Env: EVOLVE_FLAGS_STUB_URL (passed as the Observer url — the flags base
 * is its origin plus /api/public/v1/flags), EVOLVE_FLAGS_KEY (a public
 * key), EVOLVE_FLAGS_KIND=client, EVOLVE_FLAGS_CACHE_DIR (the values
 * envelope lands directly in it, so the driver can plant or corrupt one),
 * EVOLVE_FLAGS_APP_ID.
 *
 * Replies embed pre-rendered JSON (a served value round-trips through
 * JSONValue.jsonText), so they are built as text, not via
 * JSONSerialization.
 */

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("flags-conformance-runner: \(message)\n".utf8))
    exit(code)
}

let env = ProcessInfo.processInfo.environment
guard env["EVOLVE_FLAGS_KIND"] == "client" else {
    fail("flags-conformance-runner runs the client kind only", 2)
}
guard let stubURL = env["EVOLVE_FLAGS_STUB_URL"], !stubURL.isEmpty,
      let key = env["EVOLVE_FLAGS_KEY"], !key.isEmpty,
      let appID = env["EVOLVE_FLAGS_APP_ID"], !appID.isEmpty,
      let cacheDir = env["EVOLVE_FLAGS_CACHE_DIR"], !cacheDir.isEmpty
else {
    fail("EVOLVE_FLAGS_STUB_URL, EVOLVE_FLAGS_KEY, EVOLVE_FLAGS_APP_ID and EVOLVE_FLAGS_CACHE_DIR are required", 2)
}

/// Replies are written on one serial queue: the driver reads one line per
/// command and out-of-order writes would corrupt the protocol.
let replyQueue = DispatchQueue(label: "io.e-volv.flags-runner.reply")

func replyRaw(_ text: String) {
    replyQueue.sync {
        FileHandle.standardOutput.write(Data(text.utf8))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

func quote(_ value: String?) -> String {
    guard let value else { return "null" }
    guard let data = try? JSONSerialization.data(withJSONObject: [value]) else { return "null" }
    return String(data: data, encoding: .utf8).map { String($0.dropFirst().dropLast()) } ?? "null"
}

/// The installed client, guarded: the reader task and the async command
/// tasks touch it from different threads.
final class ClientBox {
    private let lock = NSLock()
    private var current: LogsClient?

    func set(_ client: LogsClient?) {
        lock.lock(); defer { lock.unlock() }
        current = client
    }

    func get() -> LogsClient? {
        lock.lock(); defer { lock.unlock() }
        return current
    }
}

let box = ClientBox()

/// The §4 init config from the driver, mapped onto FlagsOptions.
func mapConfig(_ config: [String: Any]) -> FlagsOptions {
    var flags = FlagsOptions()
    flags.cacheDirectory = URL(fileURLWithPath: cacheDir)
    if let mode = config["mode"] as? String, mode == "offline" {
        flags.offline = true
    }
    if let poll = config["pollIntervalSeconds"] as? NSNumber {
        flags.pollIntervalSeconds = poll.doubleValue
    }
    if let context = config["context"] as? [String: Any] {
        flags.initialContext = context
    }
    if let exposures = config["exposures"] as? [String: Any] {
        if let enabled = exposures["enabled"] as? Bool { flags.exposuresEnabled = enabled }
        if let rate = exposures["sampleRate"] as? NSNumber {
            flags.exposureSampleRate = rate.doubleValue
        }
        if let window = exposures["dedupeWindowSeconds"] as? NSNumber {
            flags.exposureDedupeWindowSeconds = window.doubleValue
        }
        if let send = exposures["sendAttributes"] as? Bool { flags.sendAttributes = send }
    }
    if let privateAttributes = config["privateAttributes"] as? [String] {
        flags.privateAttributes = privateAttributes
    }
    return flags
}

let options = EvolveLogsOptions(
    key: key,
    url: stubURL,
    service: "conformance",
    appID: appID,
    queueDirectory: URL(fileURLWithPath: cacheDir),
    captureCrashes: false,
    urlSessionInstrumentation: false,
    enableSessionEvents: false,
    enableSessionID: false
)

let semaphore = DispatchSemaphore(value: 0)

/// Reads stdin lines on a background thread so `main` can park on the
/// semaphore. The driver speaks strict request-reply, so at most one async
/// command is outstanding; each still runs to completion before its reply.
let reader = Task.detached {
    var options = options
    while let line = readLine() {
        guard let data = line.data(using: .utf8),
              let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = command["op"] as? String
        else { continue }

        switch op {
        case "init":
            options.flags = mapConfig(command["config"] as? [String: Any] ?? [:])
            box.set(EvolveLogs.initialize(options))
            replyRaw(#"{"ok":true}"#)

        case "identify":
            let context = command["context"] as? [String: Any] ?? [:]
            Task {
                await box.get()?.flags.identify(context)
                replyRaw(#"{"ok":true}"#)
            }

        case "eval":
            let flagKey = command["key"] as? String ?? ""
            let defaultValue = JSONValue.from(any: command["default"])
            let type = command["type"] as? String ?? "json"
            let started = DispatchTime.now().uptimeNanoseconds
            // The typed path: reading a flag as the wrong type serves the
            // default with TYPE_MISMATCH and records no exposure (the
            // exposures scenario asserts both), exactly like an app's
            // `bool`/`string`/`number` read.
            let detail = box.get()!.flags.typedDetail(flagKey, type: type, default: defaultValue)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            replyRaw(
                "{\"value\":\(detail.value.jsonText),\"variant\":\(quote(detail.variant)),"
                    + "\"reason\":\(quote(detail.reason)),\"ms\":\(String(format: "%.3f", ms))}"
            )

        case "ready":
            let timeoutMs = (command["timeoutMs"] as? NSNumber)?.doubleValue ?? 2000
            Task {
                let ready = await box.get()!.flags.ready(timeout: timeoutMs / 1000)
                replyRaw("{\"ready\":\(ready)}")
            }

        case "sleep":
            let ms = (command["ms"] as? NSNumber)?.doubleValue ?? 0
            Task {
                try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000))
                replyRaw(#"{"ok":true}"#)
            }

        case "state":
            let flags = box.get()!.flags
            let updated = flags.lastUpdatedAt
            let at = updated.map { String(format: "%.0f", $0.timeIntervalSince1970 * 1000) } ?? "null"
            replyRaw("{\"lastUpdatedAt\":\(at),\"mode\":\(quote(flags.mode))}")

        case "flush":
            Task {
                await box.get()?.flags.flushExposures()
                replyRaw(#"{"ok":true}"#)
            }

        case "close":
            Task {
                replyRaw(#"{"ok":true}"#)
                box.get()?.shutdown()
                semaphore.signal()
            }

        default:
            replyRaw("{\"error\":\"unknown op \(quote(op))\"}")
        }
    }
    // stdin closed without close: exit so the driver is not left waiting.
    semaphore.signal()
}
_ = reader

semaphore.wait()
exit(0)
