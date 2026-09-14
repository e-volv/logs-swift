import EvolveLogsC
import Foundation
@testable import EvolveLogs
import XCTest

/*
 * Shared test scaffolding: a stub URLProtocol that stands in for the ingest
 * (the same shape as packages/logs-conformance/stub-ingest.ts), a temp
 * queue directory per test, and helpers to read what the client wrote.
 */
enum Stub {
    typealias Response = (status: Int, headers: [String: String], body: Data?)

    static var lock = NSLock()
    static var responses: [Response] = []
    static var requests: [(url: URL, headers: [String: String], body: Data)] = []

    static func reset(_ response: (status: Int, headers: [String: String]) = (202, [:])) {
        lock.lock()
        responses = [(response.status, response.headers, nil)]
        requests = []
        lock.unlock()
    }

    /// A canned JSON response (flags tests need bodies, log tests do not).
    static func respond(_ status: Int, headers: [String: String] = [:], body: String) {
        lock.lock()
        responses = [(status, headers, Data(body.utf8))]
        requests = []
        lock.unlock()
    }

    /// Next canned response; repeats the last one when exhausted.
    static func nextResponse() -> Response {
        lock.lock()
        defer { lock.unlock() }
        if responses.count > 1 {
            return responses.removeFirst()
        }
        return responses.first ?? (202, [:], nil)
    }

    static func record(url: URL, headers: [String: String], body: Data) {
        lock.lock()
        requests.append((url, headers, body))
        lock.unlock()
    }

    static var recorded: [(url: URL, headers: [String: String], body: Data)] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// URLSession moves httpBody into httpBodyStream for protocol-handled
    /// requests — read whichever is present.
    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        // Read until EOF — hasBytesAvailable is advisory and goes stale
        // mid-stream for larger bodies.
        while true {
            let n = stream.read(buffer, maxLength: 4096)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    override func startLoading() {
        let body = StubURLProtocol.body(of: request)
        Stub.record(
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: body
        )
        let r = Stub.nextResponse()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: r.status,
            httpVersion: nil,
            headerFields: r.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func stubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

func tempQueueDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("evolve-tests-\(UUID().uuidString)")
}

func makeClient(
    queueDirectory explicitQueueDirectory: URL? = nil,
    session: URLSession? = nil,
    redactKeys: [String] = [],
    captureCrashes: Bool = false,
    file: StaticString = #filePath,
    line: UInt = #line
) -> LogsClient {
    // Every test client gets its own queue directory; the production default
    // (app support / caches) would leak events across tests.
    let queueDirectory = explicitQueueDirectory ?? tempQueueDir()
    return LogsClient(options: EvolveLogsOptions(
        key: "evk_test_conformance",
        url: "https://stub.evolv.test/api/public/v1/logs",
        service: "test-svc",
        environment: "test",
        release: "abc123",
        redactKeys: redactKeys,
        appID: "com.test.app",
        installIDStore: FileInstallIDStore(url: queueDirectory.appendingPathComponent("install-id")),
        queueDirectory: queueDirectory,
        captureCrashes: captureCrashes,
        urlSessionInstrumentation: false,
        session: session ?? stubSession(),
        allowServerKeyForTesting: true,
        enableSessionEvents: false
    ))
}

/// Decompresses the recorded (gzipped) request body and returns the events.
func recordedEvents() -> [[String: Any]] {
    Stub.recorded.flatMap { request -> [[String: Any]] in
        XCTAssertEqual(request.headers["Content-Encoding"], "gzip")
        // JSON expands a lot; give the inflater generous headroom.
        let bound = request.body.count * 64 + 65_536
        let out = UnsafeMutableRawBufferPointer.allocate(byteCount: bound, alignment: 1)
        defer { out.deallocate() }
        let n = request.body.withUnsafeBytes { raw -> Int in
            Int(evolve_gunzip(
                raw.bindMemory(to: UInt8.self).baseAddress,
                request.body.count,
                out.bindMemory(to: UInt8.self).baseAddress,
                bound
            ))
        }
        guard n > 0 else { return [] }
        let obj = try? JSONSerialization.jsonObject(with: Data(out[..<n]))
        return (obj as? [String: Any])?["events"] as? [[String: Any]] ?? []
    }
}

/// Reads the raw single-event files off a queue directory.
func queuedEvents(_ directory: URL) -> [[String: Any]] {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        .filter { $0.hasPrefix("queue-") && $0.hasSuffix(".json") }
        .sorted()
    return names.compactMap { name in
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}

struct SampleError: Error, LocalizedError {
    var errorDescription: String?
}
