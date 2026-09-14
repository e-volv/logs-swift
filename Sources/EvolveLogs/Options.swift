import Foundation

/// Options configures the SDK. Key and URL are both required; without them
/// the SDK is a no-op and warns once.
public struct EvolveLogsOptions {
    /// The project **public** ingest key (`evk_pub_…`). A server key
    /// (`evk_`) is refused — it must never ship inside a binary.
    public var key: String
    /// The ingest endpoint, e.g. https://api.e-volv.io/api/public/v1/logs.
    public var url: String
    /// Becomes the `service.name` attribute on every event.
    public var service: String
    /// Becomes `deployment.environment` on every event.
    public var environment: String
    /// Becomes `service.release` on every event (your build/version — the
    /// value you later upload dSYMs for).
    public var release: String
    /// Extends the backstop redaction list with extra key names.
    public var redactKeys: [String]
    /// Keep-rate in [0, 1]; below 1 events are dropped randomly. Default 1.
    public var sampleRate: Double
    /// The `x-evolve-app-id` sent on every request. Defaults to the bundle
    /// identifier (iOS/macOS apps); CLI/tests pass an explicit value.
    public var appID: String
    /// The `x-evolve-install-id` storage. Defaults to UserDefaults (iOS) or a
    /// file in the app-support directory (macOS). Pass a custom store to
    /// control where the generated UUID persists.
    public var installIDStore: InstallIDStoring?
    /// Directory of the disk queue that survives process death. Defaults to
    /// the app's caches directory (excluded from iCloud backups).
    public var queueDirectory: URL?
    /// Byte cap of the disk queue (default 1 MB); oldest files drop first.
    public var queueByteCap: Int
    /// Capture uncaught NSExceptions and fatal signals. Default true.
    public var captureCrashes: Bool
    /// Enable the URLSession traceparent machinery. Default true.
    public var urlSessionInstrumentation: Bool
    /// The URLSession used for delivery (test hook).
    public var session: URLSession?
    /// Conformance-runner escape hatch: the fixture key is server-shaped
    /// (`evk_test_conformance`), which production mobile clients must never
    /// send. Apps cannot set this.
    public var allowServerKeyForTesting: Bool
    /// Emits the session model events (`app.start`, foreground/background
    /// transitions). Default true; the conformance runner disables it so
    /// the fixture comparison sees only the fixture's calls.
    public var enableSessionEvents: Bool
    /// Stamps `session.id` on every event. Default true (the mobile
    /// session model); the conformance runner disables it because the
    /// pinned fixture predates session ids.
    public var enableSessionID: Bool
    /// The Launch flags client (docs/LAUNCH-SDK.md, client kind): evaluated
    /// values for one context, cached on device, refreshed on foreground.
    public var flags: FlagsOptions

    public init(
        key: String,
        url: String,
        service: String,
        environment: String = "",
        release: String = "",
        redactKeys: [String] = [],
        sampleRate: Double = 1,
        appID: String = EvolveLogsOptions.defaultAppID(),
        installIDStore: InstallIDStoring? = nil,
        queueDirectory: URL? = nil,
        queueByteCap: Int = 1_048_576, // 1 MB, Constants.diskByteCap
        captureCrashes: Bool = true,
        urlSessionInstrumentation: Bool = true,
        session: URLSession? = nil,
        allowServerKeyForTesting: Bool = false,
        enableSessionEvents: Bool = true,
        enableSessionID: Bool = true,
        flags: FlagsOptions = FlagsOptions()
    ) {
        self.key = key
        self.url = url
        self.service = service
        self.environment = environment
        self.release = release
        self.redactKeys = redactKeys
        self.sampleRate = sampleRate
        self.appID = appID
        self.installIDStore = installIDStore
        self.queueDirectory = queueDirectory
        self.queueByteCap = queueByteCap
        self.captureCrashes = captureCrashes
        self.urlSessionInstrumentation = urlSessionInstrumentation
        self.session = session
        self.allowServerKeyForTesting = allowServerKeyForTesting
        self.enableSessionEvents = enableSessionEvents
        self.enableSessionID = enableSessionID
        self.flags = flags
    }

    public static func defaultAppID() -> String {
        Bundle.main.bundleIdentifier ?? "unknown-app"
    }
}
