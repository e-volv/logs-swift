import Foundation

/// Shared batching and retry numbers — identical in every SDK
/// (docs/OBSERVER-SDK.md §"The contract every SDK speaks").
enum Constants {
    static let maxBatch = 200
    static let flushIntervalNanoseconds: Int = 2_000_000_000
    static let maxPayloadBytes = 512 * 1024
    static let maxBuffer = maxBatch * 2 // then the oldest events are dropped
    static let maxAttempts = 3
    static let backoffBaseNanoseconds: Int = 500_000_000
    static let backoffMaxNanoseconds: Int = 10_000_000_000
    static let deliveryTimeoutSeconds: TimeInterval = 10
    static let redacted = "[redacted]"
    static let diskByteCap = 1024 * 1024 // mobile disk queue default
    static let breadcrumbCount = 32 // last-N buffered events shipped with a crash

    // OTel severity numbers (trace 1, debug 5, info 9, warn 13, error 17, fatal 21).
    static let otelTrace = 1
    static let otelDebug = 5
    static let otelInfo = 9
    static let otelWarn = 13
    static let otelError = 17
    static let otelFatal = 21
}
