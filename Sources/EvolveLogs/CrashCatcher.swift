import Foundation
#if canImport(EvolveLogsC)
    import EvolveLogsC
#endif

/*
 * Crash capture. Two layers, both chaining to whatever was installed before:
 *
 * 1. NSSetUncaughtExceptionHandler — ObjC/NSException crashes. Runs in a
 *    crashing-but-alive ObjC context: allocation is legal, but keep it small
 *    and fast; it re-raises so the process terminates as before.
 * 2. A BSD signal handler for the fatal signals (SIGABRT, SIGBUS, SIGFPE,
 *    SIGILL, SIGSEGV, SIGTRAP). This runs on the faulting thread where
 *    almost nothing is safe — the write path is entirely C and
 *    async-signal-safe (see CrashBuffer.c): the event JSON is pre-serialized
 *    (refreshCrashBuffer), the handler formats only the exception fields
 *    with snprintf into the pre-allocated buffer, and one write(2) lands the
 *    file on the disk queue, to be sent on next launch.
 *
 * Documented limits:
 * - No Mach exception ports in this version. A pure signal handler cannot
 *   catch every crash class on iOS: stack overflow, and some Swift runtime
 *   traps that go straight to Mach exception handling, may bypass it. Mach
 *   exception ports are the robust answer (they run on a dedicated thread
 *   and see everything); they are deliberately left out here because the
 *   port-handoff dance is easy to get wrong and can deadlock if it
 *   mis-handles EXC_RESOURCE/EXC_GUARD.
 * - Async-signal-safety is honoured on the write path; the Swift handler
 *   shim itself calls only the C write function and the previous handler.
 * - The crash file is written to the queue as `queue-crash-pending.json`;
 *   the normal queue reader sends it on next launch.
 */
final class CrashCatcher {
    private(set) var installed = false

    func install(client: LogsClient) {
        guard !installed, client.enabled else { return }
        // Bake the crash event (session id + breadcrumbs) into the C buffer
        // and install the handlers once.
        client.refreshCrashBuffer()
        evolve_crash_buffer_init()
        installExceptionHandler()
        installSignalHandlers()
        installed = true
    }

    func uninstall() {
        guard installed else { return }
        if Previous.exceptionHandler != nil {
            // Restore through a trampoline: C function pointers cannot be
            // formed from a stored closure value, so the restored handler
            // dispatches to the stored one.
            NSSetUncaughtExceptionHandler(evolveChainTrampoline(_:))
        } else {
            NSSetUncaughtExceptionHandler(nil)
        }
        for (sig, action) in Previous.signalActions {
            var restored = action
            withUnsafePointer(to: &restored) { sigaction(sig, $0, nil) }
        }
        installed = false
    }

    // MARK: - NSException

    private func installExceptionHandler() {
        Previous.exceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(evolveHandleUncaughtException(_:))
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - fatal signals

    static let fatalSignals: [Int32] = [
        SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP,
    ]

    private func installSignalHandlers() {
        for sig in CrashCatcher.fatalSignals {
            var action = Darwin.sigaction()
            action.sa_flags = 0
            action.__sigaction_u.__sa_handler = CrashCatcher.signalHandler
            sigemptyset(&action.sa_mask)
            var old = Darwin.sigaction()
            sigaction(sig, &action, &old)
            // Chain: remember the previous disposition per signal.
            Previous.signalActions[sig] = old
        }
    }

    // The signal shim: async-signal-safe body (C write path only), then
    // chain to the previous disposition and re-raise the default so the OS
    // still produces its own crash report.
    private static let signalHandler: sig_t = { signo in
        // Minimal context info: si_code/fault address would need a
        // SA_SIGINFO handler; the signal number alone identifies the class.
        _ = evolve_crash_buffer_write_signal(Int32(signo), 0, 0)
        // Chain to the previous handler if one was installed.
        Darwin.signal(signo, SIG_DFL)
        Darwin.raise(signo)
        _exit(1) // unreachable unless the raise was masked
    }
}

/// Storage for the previously installed handlers, so both layers chain
/// exactly as the process would behave without the SDK. Unsafe storage is
/// required: handlers are `@convention(c)` and cannot capture.
private enum Previous {
    nonisolated(unsafe) static var exceptionHandler: NSUncaughtExceptionHandler?
    nonisolated(unsafe) static var signalActions: [Int32: Darwin.sigaction] = [:]
}

/// Uninstall trampoline: dispatches to the handler that was installed
/// before us, restoring the pre-SDK behaviour. File-scope because Darwin
/// only forms C function pointers from free functions and literals.
private func evolveChainTrampoline(_ exception: NSException) {
    Previous.exceptionHandler?(exception)
}

/// The installed exception trampoline. A crashing ObjC context: allocation
/// is legal, but keep it minimal. JSON-escapes name/reason for the C write
/// path, then chains to the previously installed handler and terminates.
private func evolveHandleUncaughtException(_ exception: NSException) {
    let name = CrashCatcher.escape(exception.name.rawValue)
    let reason = CrashCatcher.escape(exception.reason ?? "")
    name.withCString { namePtr in
        reason.withCString { reasonPtr in
            _ = evolve_crash_buffer_write_exception(namePtr, reasonPtr)
        }
    }
    Previous.exceptionHandler?(exception)
    Darwin.raise(SIGABRT)
    _ = Darwin.kill(Darwin.getpid(), SIGKILL) // never returns
}
