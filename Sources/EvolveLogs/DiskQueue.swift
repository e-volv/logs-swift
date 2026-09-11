import Foundation

/*
 * The mobile buffer: a directory of single-event JSON files that survive
 * process death. A crash is precisely the case where an in-memory ring
 * buffer is lost, so the queue lives on disk; the crash-time write lands
 * here and is sent on next launch. Files are written atomically (write to a
 * temp name, rename) so a process killed mid-write never yields a torn
 * file. Reads happen on launch, before new events are appended, oldest
 * first; the oldest files drop past the byte cap and past 2× the batch
 * size (the same "oldest-first with a visible counter" rule the server
 * SDKs apply to their memory buffer).
 */
final class DiskQueue {
    let directory: URL
    let byteCap: Int
    /// 2× the batch size — the drop-oldest threshold, shared with the
    /// server SDKs' in-memory buffers.
    let maxFiles: Int

    private let lock = NSLock()

    /// Incrementing counter + random suffix keep file names unique across
    /// very fast successive writes and across relaunches with a reset clock.
    private var counter: UInt64
    private let idSuffix = UUID().uuidString.prefix(8)

    init(directory: URL, byteCap: Int = Constants.diskByteCap, maxFiles: Int = Constants.maxBuffer) throws {
        self.directory = directory
        self.byteCap = byteCap
        self.maxFiles = maxFiles
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        // Seed the counter above anything already on disk so new file names
        // sort after the existing ones (they drain first).
        let existing = (try? FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )) ?? []
        var maxCounter: UInt64 = 0
        for name in existing where name.hasPrefix("queue-") {
            let digits = name.dropFirst("queue-".count).prefix(while: \.isNumber)
            if let n = UInt64(digits) {
                maxCounter = max(maxCounter, n)
            }
        }
        counter = maxCounter
    }

    /// Every file currently queued, oldest first (name order: counter-prefixed).
    private func fileNames() -> [String] {
        let names = ((try? FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )) ?? []).filter { $0.hasPrefix("queue-") && $0.hasSuffix(".json") }
        return names.sorted()
    }

    private func totalBytes() -> Int {
        fileNames().reduce(0) { sum, name in
            let path = directory.appendingPathComponent(name).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
            return sum + (size ?? 0)
        }
    }

    /// Appends one pre-serialized event file, evicting oldest files past
    /// the count or byte cap. Returns how many older files were evicted
    /// (visible on the client's dropped counter). Not async-signal-safe —
    /// the crash handler bypasses this (CrashBuffer) and drops to raw
    /// write(2).
    @discardableResult
    func append(_ data: Data) -> Int {
        lock.lock()
        defer { lock.unlock() }

        counter &+= 1
        let name = String(
            format: "queue-%012llu-%@.json",
            counter,
            String(idSuffix)
        )
        let url = directory.appendingPathComponent(name)
        // .atomic = write temp + rename: a kill mid-write never leaves a
        // torn file behind.
        try? data.write(to: url, options: .atomic)

        var evicted = 0
        var names = fileNames()
        var bytes = totalBytes()
        while names.count > maxFiles || bytes > byteCap {
            guard names.count > 1 else { break } // never evict what we just wrote alone
            let oldest = names.removeFirst()
            let path = directory.appendingPathComponent(oldest).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
            try? FileManager.default.removeItem(atPath: path)
            bytes -= size
            evicted += 1
        }
        return evicted
    }

    /// Peeks up to `maxEvents` files whose combined size is under `maxBytes`,
    /// oldest first, without removing them. Corrupt or oversized head files
    /// are removed and reported on `dropped` — an event that can never fit a
    /// 512 KB payload must not block the queue forever.
    func peek(
        maxEvents: Int,
        maxBytes: Int,
        dropped: ((Int) -> Void)? = nil
    ) -> [(name: String, data: Data)] {
        lock.lock()
        defer { lock.unlock() }

        var out: [(name: String, data: Data)] = []
        var bytes = 0
        for name in fileNames() {
            guard out.count < maxEvents else { break }
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else {
                try? FileManager.default.removeItem(at: url)
                dropped?(1)
                continue
            }
            if bytes + data.count > maxBytes {
                if out.isEmpty {
                    try? FileManager.default.removeItem(at: url)
                    dropped?(1)
                }
                break
            }
            out.append((name, data))
            bytes += data.count
        }
        return out
    }

    /// Removes processed files after a successful send.
    func remove(_ names: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for name in names {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(name)
            )
        }
    }

    /// The crash-time destination: a pre-resolved path the signal handler
    /// writes with a single write(2), picked up here on the next launch
    /// because the name matches the queue-* glob.
    func crashPendingPath() -> URL {
        directory.appendingPathComponent("queue-crash-pending.json")
    }
}
