import Foundation

/// Persistence for the `x-evolve-install-id` — a UUID the SDK generates once
/// per install and sends on every request (the ingest caps per-install
/// volume against it; the user can clear it by deleting the store).
public protocol InstallIDStoring {
    func load() -> String?
    func save(_ id: String)
}

/// UserDefaults-backed store (the default on iOS).
public struct UserDefaultsInstallIDStore: InstallIDStoring {
    private let key = "evolve.logs.installId"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> String? {
        defaults.string(forKey: key)
    }

    public func save(_ id: String) {
        defaults.set(id, forKey: key)
    }
}

/// File-backed store (the default on macOS, where apps may not use
/// UserDefaults for shared scaffolding; also handy for tests and CLIs).
public struct FileInstallIDStore: InstallIDStoring {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> String? {
        try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    public func save(_ id: String) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? id.write(to: url, atomically: true, encoding: .utf8)
    }
}

enum InstallIDs {
    /// Generates and persists a fresh id when the store is empty.
    static func resolve(using store: InstallIDStoring) -> String {
        if let existing = store.load() {
            return existing
        }
        let id = UUID().uuidString
        store.save(id)
        return id
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
