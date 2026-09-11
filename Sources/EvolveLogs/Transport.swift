import Foundation
#if canImport(EvolveLogsC)
    import EvolveLogsC
#endif
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// One delivery attempt over URLSession. The mobile client differs from the
/// server SDKs in transport only — the wire contract, batching thresholds,
/// retry semantics, redaction and gzip are identical
/// (docs/OBSERVER-SDK.md). Every request carries the public key, the app id
/// (`x-evolve-app-id`, the iOS bundle identifier) and the install id
/// (`x-evolve-install-id`), the binding that lets the ingest refuse keys
/// presented from the wrong app and cap a looping device.
final class Transport {
    let url: URL
    let key: String
    let appID: String
    let installID: String
    let session: URLSession

    init(url: URL, key: String, appID: String, installID: String, session: URLSession) {
        self.url = url
        self.key = key
        self.appID = appID
        self.installID = installID
        self.session = session
    }

    struct Result {
        let status: Int
        let retryAfter: String?
    }

    /// gzips `body` and POSTs it, returning the status and Retry-After
    /// header. A transport error is surfaced as status 0.
    func send(_ body: Data) -> Result {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("gzip", forHTTPHeaderField: "content-encoding")
        request.setValue(appID, forHTTPHeaderField: "x-evolve-app-id")
        request.setValue(installID, forHTTPHeaderField: "x-evolve-install-id")
        request.httpBody = Transport.gzip(body)

        var status = 0
        var retryAfter: String?
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse {
                status = http.statusCode
                retryAfter = http.allHeaderFields["Retry-After"] as? String
            }
            semaphore.signal()
        }
        // Deliveries outlive the caller's deadline: never cancel a flush
        // because the logging call site was cancelled. Matches the ingest's
        // own 10 s budget.
        task.resume()
        _ = semaphore.wait(timeout: .now() + Constants.deliveryTimeoutSeconds + 5)
        return Result(status: status, retryAfter: retryAfter)
    }

    static func gzip(_ data: Data) -> Data {
        // Through the system zlib, with the gzip container the ingest's
        // Content-Encoding expects (zlib's own format is not gzip).
        let bound = evolve_gzip_bound(data.count)
        let out = UnsafeMutableRawBufferPointer.allocate(byteCount: bound, alignment: 1)
        defer { out.deallocate() }
        let n = data.withUnsafeBytes { raw -> size_t in
            evolve_gzip(
                raw.bindMemory(to: UInt8.self).baseAddress,
                data.count,
                out.bindMemory(to: UInt8.self).baseAddress,
                bound
            )
        }
        guard n > 0 else { return data }
        return Data(out[..<n])
    }
}

/// Retry delay: Retry-After (seconds) when the ingest sent one, otherwise
/// exponential backoff from 500 ms doubling, capped at 10 s.
enum Backoff {
    /// Retry delay in nanoseconds: Retry-After (seconds) when the ingest
    /// sent one, otherwise exponential backoff from 500 ms doubling, capped
    /// at 10 s.
    static func delay(attempt: Int, retryAfter: String?) -> Int {
        if let retryAfter, let seconds = Double(retryAfter.trimmingCharacters(in: .whitespaces)),
           seconds >= 0 {
            return Int(seconds * 1_000_000_000)
        }
        var d = Constants.backoffBaseNanoseconds
        var i = 1
        while i < attempt {
            d *= 2
            if d > Constants.backoffMaxNanoseconds { return Constants.backoffMaxNanoseconds }
            i += 1
        }
        return min(d, Constants.backoffMaxNanoseconds)
    }
}

func sleepNanoseconds(_ ns: Int) {
    Thread.sleep(forTimeInterval: TimeInterval(ns) / 1_000_000_000)
}
