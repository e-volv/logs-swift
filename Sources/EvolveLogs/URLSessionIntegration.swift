import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
#if canImport(UIKit)
    import UIKit
#endif

/*
 * URLSession traceparent propagation, in and out.
 *
 * Outbound (injection): a custom URLProtocol added via
 * URLSessionConfiguration.protocolClasses. This is the swizzle-free route:
 * the SDK never touches URLSession's methods; any session whose
 * configuration carries the protocol gets traceparent headers on requests
 * made inside a trace, never overwriting an existing header. The price is
 * URLProtocol's documented limits — it is bypassed for background
 * (URLSessionConfiguration.background) sessions and for assets handed
 * directly to AVFoundation/WebKit, so those requests carry no automatic
 * traceparent.
 *
 * Inbound (reading traceparent off responses): there is no supported
 * delegate hook that exposes response headers before the task's completion,
 * so this one unavoidable swizzle is isolated here: method_exchangeImplementations
 * on URLSession.dataTask(urlRequest:completionHandler:) wraps the caller's
 * completion block, reads `traceparent` from the response and attaches the
 * response's span as a child context for the duration of the completion
 * callback — a crash reported from the callback joins the server trace.
 * It is installed once, guarded by a flag, and documented.
 */
public enum URLSessionIntegration {
    public static var isEnabled = false

    private static let lock = NSLock()
    private static var swizzled = false

    /// Adds the injecting URLProtocol to a configuration. Call for any
    /// session you create; the default-ephemeral delivery session does not
    /// need it.
    public static func inject(into configuration: URLSessionConfiguration) {
        var classes = configuration.protocolClasses ?? []
        guard !classes.contains(where: { $0 == EvolveTraceProtocol.self }) else { return }
        classes.insert(EvolveTraceProtocol.self, at: 0)
        configuration.protocolClasses = classes
    }

    static func enable() {
        lock.lock()
        defer { lock.unlock() }
        guard !isEnabled else { return }
        isEnabled = true
        swizzleCompletionHandlerOnce()
    }

    // MARK: - the one swizzle, isolated

    private static func swizzleCompletionHandlerOnce() {
        guard !swizzled else { return }
        swizzled = true
        // The Obj-C selector for dataTask(with: URLRequest, completionHandler:).
        let original = class_getInstanceMethod(
            URLSession.self,
            Selector(("dataTaskWithRequest:completionHandler:"))
        )
        let swizzledMethod = class_getInstanceMethod(
            URLSession.self,
            #selector(URLSession.evolve_dataTask(_:completionHandler:))
        )
        guard let original, let swizzledMethod else { return }
        method_exchangeImplementations(original, swizzledMethod)
    }
}

extension URLSession {
    @objc
    func evolve_dataTask(
        _ request: URLRequest,
        completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void
    ) -> URLSessionDataTask {
        // The implementation of dataTask(_:completionHandler:) now lives
        // under evolve_dataTask's selector; calling it dispatches the
        // original. Wrap the completion to capture traceparent.
        let wrapped: (Data?, URLResponse?, Error?) -> Void = { data, response, error in
            if let http = response as? HTTPURLResponse,
               let header = http.allHeaderFields["traceparent"] as? String,
               let responseContext = Traceparent.parse(header) {
                let child = Traces.child(of: responseContext)
                Traces.$current.withValue(child) {
                    completionHandler(data, response, error)
                }
                return
            }
            completionHandler(data, response, error)
        }
        return evolve_dataTask(request, completionHandler: wrapped)
    }
}

/// Injects `traceparent` on outbound requests made inside a trace. The
/// canonical request check keeps this cheap for requests outside a trace.
final class EvolveTraceProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        Traces.current != nil && property(forKey: "evolve.handled", in: request) == nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let mutable = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        if mutable.value(forHTTPHeaderField: "traceparent") == nil,
           let context = Traces.current {
            mutable.setValue(context.traceparent, forHTTPHeaderField: "traceparent")
        }
        EvolveTraceProtocol.setProperty(true, forKey: "evolve.handled", in: mutable)
        startForwardedLoad(with: mutable as URLRequest)
    }

    private func startForwardedLoad(with request: URLRequest) {
        // Forward through a real ephemeral session (without this protocol,
        // or the forwarding request loops back into canInit).
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = config.protocolClasses?.filter { $0 != EvolveTraceProtocol.self }
        let session = URLSession(configuration: config)
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            if let response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data {
                self.client?.urlProtocol(self, didLoad: data)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        task.resume()
    }

    override func stopLoading() {}
}
