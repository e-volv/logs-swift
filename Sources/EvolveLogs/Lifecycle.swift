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
        }

        @objc
        private func willEnterForeground() {
            client?.beginSession(state: "foreground", marker: "app.foreground")
        }
    }
#endif
