import Foundation
#if canImport(os)
    import os.log
#endif

/// Internal diagnostics. The SDK never throws into user code; its own
/// failures go to os.log (visible in Console.app / `log stream`) under the
/// subsystem `io.e-volv.logs`.
enum Diag {
    #if canImport(os)
        private static let log = OSLog(subsystem: "io.e-volv.logs", category: "sdk")
    #endif

    static func warn(_ message: String) {
        #if canImport(os)
            os_log("%{public}@", log: log, type: .default, message)
        #else
            FileHandle.standardError.write(Data("e-volv-logs: \(message)\n".utf8))
        #endif
    }

    static func error(_ message: String) {
        #if canImport(os)
            os_log("%{public}@", log: log, type: .error, message)
        #else
            FileHandle.standardError.write(Data("e-volv-logs: \(message)\n".utf8))
        #endif
    }
}
