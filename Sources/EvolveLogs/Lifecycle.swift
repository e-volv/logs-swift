#if os(iOS)
    import Foundation
    import UIKit

    /*
     * Lifecycle-driven flush and the session model (docs/pm spec §3: "flush
     * is driven by lifecycle, not exit"). Wires the shared client to
     * UIApplication notifications; the background flush is opportunistic —
     * a few seconds of background execution, no beginBackgroundTask, so a
     * flush that cannot finish leaves the queue on disk for next launch,
     * which is the point of the disk queue. Foreground/background
     * transitions are session events; a fresh session id starts at every
     * foreground epoch (matching the Android client).
     *
     * Launch flags ride the same transitions: foreground refreshes stale
     * values (poll clients re-check on foreground, contract §2.3) and
     * background flushes pending exposures (contract §7).
     */
    final class LifecycleObserver {
        private weak var client: LogsClient?

        init(client: LogsClient) {
            self.client = client
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(didEnterBackground),
                name: UIApplication.didEnterBackgroundNotification,
                object: nil
            )
            center.addObserver(
                self,
                selector: #selector(willEnterForeground),
                name: UIApplication.willEnterForegroundNotification,
                object: nil
            )
        }

        @objc
        private func didEnterBackground() {
            guard let client else { return }
            client.endSession(marker: "app.background")
            client.flush() // lifecycle flush: the buffer must not wait for a launch
            Task { await client.flags.flushExposures() }
        }

        @objc
        private func willEnterForeground() {
            guard let client else { return }
            client.beginSession(state: "foreground", marker: "app.foreground")
            Task { await client.flags.refreshIfStale() }
        }
    }
#endif

#if os(macOS) && canImport(AppKit)
    import AppKit
    import Foundation

    /// macOS has no UIApplication; the app-framework equivalents drive the
    /// flags lifecycle. Only the flags hooks exist here — the Observer
    /// session model and background flush are iOS concepts.
    final class MacLifecycleObserver {
        private weak var client: LogsClient?

        init(client: LogsClient) {
            self.client = client
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(didBecomeActive),
                name: NSApplication.didBecomeActiveNotification,
                object: nil
            )
        }

        @objc
        private func didBecomeActive() {
            guard let client else { return }
            Task { await client.flags.refreshIfStale() }
        }
    }
#endif
