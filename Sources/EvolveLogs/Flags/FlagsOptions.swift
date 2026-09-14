import Foundation

/// One evaluated flag as a client key receives it: the value, the variant it
/// came from, and why (docs/LAUNCH-SDK.md §2.2). Also the `detail` return.
public struct Evaluation: Equatable {
    public let value: JSONValue
    public let variant: String?
    public let reason: String

    public init(value: JSONValue, variant: String?, reason: String) {
        self.value = value
        self.variant = variant
        self.reason = reason
    }
}

/// Flags configuration, the client defaults of docs/LAUNCH-SDK.md §4 (poll,
/// 60 s, exposures dedupe 300 s, cache on). Set `EvolveLogsOptions.flags`.
public struct FlagsOptions {
    /// Start the flags client. Default true.
    public var enabled = true
    /// Base URL ending in `/api/public/v1/flags`; default is the origin of
    /// the Observer `url` plus that path, then production.
    public var url: String? = nil
    /// Never contact the control plane: bootstrap snapshot or defaults only.
    public var offline = false
    /// Poll period in seconds; clamped to a 15 s minimum.
    public var pollIntervalSeconds: Double = 60
    /// Keep the last-known values on disk (contract §6). Default true.
    public var cacheEnabled = true
    /// A bundled values map served before the first fetch.
    public var bootstrap: [String: Evaluation]? = nil
    /// The context the first fetch uses, until `identify` replaces it.
    public var initialContext: [String: Any] = [:]
    /// Record exposures on evaluation. Default true.
    public var exposuresEnabled = true
    /// Probability an evaluation is recorded; sent as `sampleRate`.
    public var exposureSampleRate: Double = 1
    /// Suppress repeats of the same (flagKey, variant, contextKind, subject).
    public var exposureDedupeWindowSeconds: Double = 300
    /// Send context attributes with exposures (private attributes removed).
    public var sendAttributes = false
    /// Attribute names never sent anywhere.
    public var privateAttributes: [String] = []

    public init() {}

    /// Where the values envelope is written; `queueDirectory/flags` by
    /// default. Set directly by the conformance runner and tests so the
    /// cache file lands exactly where the driver plants or corrupts one.
    public var cacheDirectory: URL? = nil

    /// Test hook: poll period without the 15 s floor (the suite drives a
    /// 0.2 s poll for L2). Apps cannot set this.
    var unclampedPollInterval: Double? = nil
}
