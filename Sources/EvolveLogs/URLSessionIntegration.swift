import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/*
 * URLSession traceparent propagation, in and out.
 *
 * Outbound (injection): the swizzle below — a single
 * method_exchangeImplementations on
 * URLSession.dataTask(with:completionHandler:) — stamps `traceparent` onto
 * the request at task creation, on the caller's thread, where the
 * task-local trace context (Traces.current) still resolves. A
 * URLProtocol-based injector cannot do this job: request classification and
 * startLoading run on a session queue, after the caller's task-local
 * context is gone (the S5 protocol lived here and never fired — caught by
 * the S6 bridge tests). A caller-set traceparent header is never
 * overwritten, and the ambient Swift context wins over the external
 * traceparent a cross-platform layer set with
 * LogsClient.setExternalTraceparent.
 *
 * Inbound (reading traceparent off responses): the same swizzle wraps the
 * task's completion block, reads `traceparent` from the response and
 * attaches the response's span as a child context for the duration of the
 * completion callback — a crash reported from the callback joins the
 * server trace. Installed once, guarded by a flag.
 *
 * The delegate-based dataTask(with:) (no completion block) is not covered,
 * for either direction — the same coverage line as every swizzle-based
 * instrumentor.
 */
public enum URLSessionIntegration {
    public static var isEnabled = false

    private static let lock = NSLock()
    private static var swizzled = false

    // The traceparent a cross-platform layer (React Native, Flutter) is
    // inside; injected when no task-local context exists. Process-wide on
    // purpose: the bridge configures a single client and there is one
    // ambient external trace at a time.
    private static let externalLock = NSLock()
    private static var externalTraceparent: String?

    static func setExternalTraceparent(_ header: String?) {
        externalLock.lock()
        externalTraceparent = header
        externalLock.unlock()
    }

    static func currentExternalTraceparent() -> String? {
        externalLock.lock()
        defer { externalLock.unlock() }
        return externalTraceparent
    }

    static func enable() {
        lock.lock()
        defer { lock.unlock() }
        guard !isEnabled else { return }
        isEnabled = true
        swizzleOnce()
    }

    private static func swizzleOnce() {
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
        // Outbound: stamp the header while the caller's task-local context
        // is still live. After the exchange, evolve_dataTask's selector
        // dispatches the original implementation.
        var outgoing = request
        if request.value(forHTTPHeaderField: "traceparent") == nil,
           let header = Traces.current?.traceparent
               ?? URLSessionIntegration.currentExternalTraceparent() {
            let mutable = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
            mutable.setValue(header, forHTTPHeaderField: "traceparent")
            outgoing = mutable as URLRequest
        }

        // Inbound: wrap the completion to capture traceparent.
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
        return evolve_dataTask(outgoing, completionHandler: wrapped)
    }
}
