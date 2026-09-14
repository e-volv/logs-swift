# e-volv-logs-swift

e-volv Observer SDK for iOS (Swift package `EvolveLogs`) — batched log
shipping, trace context, crash capture and session reporting against the
e-volv ingest endpoint (`POST /api/public/v1/logs`). Companions: the Node.js
SDK `@e-volv/logs`, the Python SDK `e-volv-logs` and the Go SDK
`e-volv-logs-go`. All speak one wire contract (`docs/OBSERVER-SDK.md`).

iOS 15+ / macOS 13+. Foundation + URLSession only — no third-party
dependencies (system zlib for gzip, os.log for diagnostics). Mobile clients
differ from the server SDKs in transport only: a disk-backed queue that
survives process death, lifecycle-driven flush, and long back-off.

## Install

Swift Package Manager. SwiftPM names the package after the repository, so the
product comes from `logs-swift`:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/e-volv/logs-swift", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "EvolveLogs", package: "logs-swift"),
    ]),
]
```

CocoaPods:

```ruby
pod 'EvolveLogs', '~> 0.1'
```

## Quick start

```swift
import EvolveLogs

EvolveLogs.initialize(EvolveLogsOptions(
    key: "evk_pub_…",   // public project key — minted on the project's page
    url: "https://api.e-volv.io/api/public/v1/logs",
    service: "acme-shop",
    environment: "production",
    release: "1.4.2"    // the value you later upload dSYMs for
))

Logs.info("order created", attrs: ["orderId": "o_1", "total": 42.5])
Logs.error("payment failed", attrs: ["orderId": "o_1"])

do {
    try charge()
} catch {
    Logs.exception(error, attrs: ["orderId": "o_1"]) // exception.type/message/stack
}

Logs.flush() // safe to call repeatedly; also automatic every 2 s and on background
```

Initialize from `UIApplicationDelegate.application(_:didFinishLaunchingWithOptions:)`
(or your SwiftUI `.init`) before any `Logs` call. If the key or URL is
missing the SDK is a no-op and warns once via os.log; it never throws into
your code.

**Key kinds.** This SDK refuses a server key (`evk_…`) at init — a server
key must never ship inside a binary. Use a **public key** (`evk_pub_…`,
minted on the Observer project's page). Every request carries
`x-evolve-app-id` (your bundle identifier) and a generated, persisted
`x-evolve-install-id`; the ingest checks the key's app-id allowlist and caps
per-install volume, which is what bounds the damage from an extracted key.

## Traces and spans

Trace context lives in a `@TaskLocal`, so it flows across `await` and into
Swift concurrency child tasks:

```swift
let span = client.startSpan("db.query", attrs: ["table": "orders"])
do {
    try db.query("…")
    span.end()
} catch {
    span.end(error) // ends the span as failed
}

// rethrowing closure form — a thrown error ends the span failed and
// is rethrown, so control flow is unchanged:
let rows = try client.span("db.query") { try db.query("…") }

// queue hops: continue an inbound traceparent (consumer side)
Logs.runWithTraceparent(message.headers["traceparent"] ?? "") {
    Logs.info("job received", attrs: ["jobId": job.id])
    client.startSpan("queue.consume").end()
}
```

`span.end` records an event with `span.name` and `durationMs` — the ingest
turns it into a span row, which is how `span()` reaches the trace graph.
`Logs.traceparent()` returns the W3C `00-<traceId>-<spanId>-01` header of
the current trace, or "" outside one. Spans nest by parent linkage; an
absent or malformed inbound header starts a fresh trace.

### URLSession propagation

Outbound, requests made inside a trace get a `traceparent` header (an
existing header is never overwritten) via a `URLProtocol` you opt into per
session — no swizzling:

```swift
let config = URLSessionConfiguration.default
URLSessionIntegration.inject(into: config)
let session = URLSession(configuration: config)
```

(The documented `URLProtocol` limits: background sessions and requests
handed straight to AVFoundation/WebKit bypass it.) Inbound, the SDK reads
`traceparent` off responses with one isolated, guarded swizzle of
`URLSession.dataTask(_:completionHandler:)` — installed once at
`initialize` — so a crash reported from a completion handler joins the
server trace that caused it.

## Crash capture

- `NSSetUncaughtExceptionHandler` for `NSException` crashes, and a BSD
  signal handler for `SIGABRT/SIGBUS/SIGFPE/SIGILL/SIGSEGV/SIGTRAP`. Both
  chain to the previously installed handler and re-raise, so the process
  still terminates (and is still reported) by the OS exactly as before.
- The crash-time write path is a small C shim and **async-signal-safe**: the
  event JSON (current session id, service attrs, and the last **32**
  buffered events as breadcrumbs) is pre-serialized into a pre-allocated
  buffer; the handler formats only the exception fields with `snprintf` and
  lands the file with one `write(2)`. The crash event is sent on next
  launch.
- **Limits, stated plainly:** there are no Mach exception ports in this
  version. A pure signal handler cannot catch every crash class on iOS —
  stack overflow and some Swift runtime traps that go straight to Mach
  exception handling may bypass it. Mach ports (a dedicated handler thread
  that sees everything) are the known follow-up. The crash file is written
  to the app's queue directory; if the device dies with it unsent it ships
  on the next launch.

## Lifecycle, sessions, offline

- The buffer is a **disk queue** (one atomic file per event, read at launch
  before new events) with a 1 MB byte cap and drop-oldest — a crash, a kill
  or a reboot loses nothing that was already logged.
- Flush is lifecycle-driven: every 2 s in foreground and on
  `applicationDidEnterBackground` (UIKit notification). Failed batches stay
  on disk and back off rather than dropping.
- **Session model:** a fresh `session.id` per app foreground epoch, an
  `app.start` marker, and foreground/background transitions as events;
  `session.id` rides on every event (crash-free session rate).
- **429** honours `Retry-After`, else exponential backoff (500 ms doubling,
  capped at 10 s), 3 attempts. **413** halves the batch (oldest half kept,
  the excess dropped and counted). Losses are visible on
  `client.droppedCount`.

## Redaction and sampling

Attribute keys matching
`password|secret|token|authorization|cookie|set-cookie|api[-_]?key`
(case-insensitive substring, recursing into nested dictionaries and arrays)
are replaced with `[redacted]` before anything leaves the process;
`redactKeys` extends the list. `sampleRate` (0–1) randomly drops events
below 1.

## Symbolication: upload your dSYMs

Release builds ship stripped binaries — without symbols, crash frames read
as `0x1045a8f3c in MyApp`. Upload the dSYM per release with the CLI (a
**server** key, from CI, never from the app):

```bash
evolve-logs upload-artifacts --key evk_… --url https://api.e-volv.io \
  --release 1.4.2 --platform ios --type dsym \
  MyApp.app.dSYM
```

See `tools/logs-cli/README.md` for the full command. Uploading backfills
already-received occurrences for the same release.

## Out of scope (this version)

- Mach exception ports (see Crash capture above).
- App Attest / Play Integrity attestation and the short-lived-token key
  exchange (the wire format leaves room for it; server-side only when it
  lands).
- Session replay, performance vitals/RUM, network waterfall, metrics
  ingest.
- User-identity or device-fingerprint collection beyond the install id
  (which the user can clear).

## Conformance

```bash
npx tsx packages/logs-conformance/run.ts packages/logs-conformance/fixture.json -- \
  swift run --package-path packages/logs-swift conformance-runner
```

Replays the shared fixture (`packages/logs-conformance/fixture.json`)
through this runner against a stub ingest — the same gate every SDK runs,
pinning the wire contract. See `packages/logs-conformance/runner-protocol.md`.

## Development

```bash
cd packages/logs-swift
swift build
swift test
```
