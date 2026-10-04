import Foundation

/// What the guest already holds, remembered across app launches.
///
/// The guest boots from a filesystem image inside the app's Documents that is
/// copied once and then reused, so a project that was copied into it, and the
/// object files a compile produced, are still there the next time the app
/// starts. Nothing used to know that: the record of what had been pushed and the
/// compile cache both lived in memory and died with the process, so **every app
/// launch paid for the whole project twice** -- once to copy it into the guest,
/// once to compile it -- however little had changed since the last one.
///
/// This is the smallest thing that fixes that, and it is deliberately the only
/// thing it does: two dictionaries, keyed by the paths the guest uses, persisted
/// beside the guest root it describes.
///
/// Trust is the whole design. The record is a claim about a *guest*, so it is
/// only used while it describes the guest root that is actually present: the
/// root's identity (its file id and creation date) is stored with the state and
/// compared on load. Deleting the guest root -- the app copies a fresh image
/// whenever the directory is missing -- discards everything, because from then
/// on the claim would be about a filesystem that no longer exists.
@MainActor
final class GuestStateStore {
    static let shared = GuestStateStore()

    private struct Snapshot: Codable {
        var rootPath: String
        var rootIdentity: String
        var pushed: [String: String]
        var compiled: [String: String]
        var savedAt: Date
    }

    /// Path relative to the guest project root -> digest of the bytes the guest
    /// holds. A file whose digest still matches does not have to be sent again.
    private var pushed: [String: String] = [:]
    /// Path -> the compile token whose object is in the guest. A token is the
    /// source's digest, the project's header stamp and the exact command, so a
    /// match means the object in the guest is the one this compile would produce.
    private var compiled: [String: String] = [:]

    private var loaded = false
    private var saveTask: Task<Void, Never>?

    private init() {}

    // MARK: - Loading

    /// Reads the record for the guest root that is present, once per process.
    ///
    /// Called from every accessor rather than at a defined moment: the guest root
    /// is copied by whichever code path uses the guest first, and a state file
    /// read before that would be looked up against a directory that does not
    /// exist yet.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let root = Self.guestRootIdentity(),
              let url = Self.fileURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.rootPath == root.path,
              snapshot.rootIdentity == root.identity
        else { return }
        pushed = snapshot.pushed
        compiled = snapshot.compiled
    }

    /// The identity of the guest root, or nil when it has not been created yet.
    ///
    /// The path alone is not enough: the directory is recreated from the bundled
    /// image whenever it is missing, and a new one holds none of the project. The
    /// file id changes with it, and so does the creation date.
    private static func guestRootIdentity() -> (path: String, identity: String)? {
        guard let url = LinuxGuestEngine.writableRootURL,
              FileManager.default.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey, .creationDateKey])
        else { return nil }
        let identifier = values.fileResourceIdentifier.map { String(describing: $0) }
        let created = values.creationDate.map { String($0.timeIntervalSince1970) }
        // Nothing to recognise the root by means nothing is safe to assume about
        // it, so the record is treated as absent rather than matched loosely.
        guard identifier != nil || created != nil else { return nil }
        return (url.path, (identifier ?? "unknown") + "|" + (created ?? "unknown"))
    }

    private static var fileURL: URL? {
        LinuxGuestEngine.writableRootURL?
            .deletingLastPathComponent()
            .appendingPathComponent("guest-state.json")
    }

    // MARK: - Saving

    /// Writes the record out, coalescing bursts: a sync records one entry per
    /// file, and a compile one per source, and neither should be a write per
    /// entry.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes immediately. Called when a run ends, so a record is never left
    /// sitting only in memory because the app was killed inside the debounce.
    func saveNow() {
        guard loaded, let root = Self.guestRootIdentity(), let url = Self.fileURL else { return }
        let snapshot = Snapshot(rootPath: root.path,
                                rootIdentity: root.identity,
                                pushed: pushed,
                                compiled: compiled,
                                savedAt: Date())
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Synced files

    func pushedDigest(for path: String) -> String? {
        loadIfNeeded()
        return pushed[path]
    }

    var pushedPaths: [String] {
        loadIfNeeded()
        return Array(pushed.keys)
    }

    func recordPush(_ path: String, digest: String) {
        loadIfNeeded()
        pushed[path] = digest
        scheduleSave()
    }

    func forgetPushed(_ paths: [String]) {
        loadIfNeeded()
        for path in paths { pushed.removeValue(forKey: path) }
        scheduleSave()
    }

    /// Drops the record of what is in the guest, so the next sync sends
    /// everything again. The compile cache survives: the objects it describes are
    /// still in the guest, and they are keyed on the *source*, not on the path
    /// they arrived by.
    func forgetPushed() {
        loadIfNeeded()
        pushed.removeAll()
        saveNow()
    }

    // MARK: - Compiled sources

    func compileToken(for path: String) -> String? {
        loadIfNeeded()
        return compiled[path]
    }

    func recordCompile(_ path: String, token: String) {
        loadIfNeeded()
        compiled[path] = token
        scheduleSave()
    }

    func forgetCompile(_ path: String) {
        loadIfNeeded()
        compiled.removeValue(forKey: path)
        scheduleSave()
    }
}
