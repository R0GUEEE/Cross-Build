import Foundation

/// Copies workspace files into the Linux guest.
///
/// The guest boots from its own filesystem image, so the iOS workspace directory
/// does not exist inside it -- the app's own `cd` fallback says as much ("... is
/// not a directory inside the guest"). That made every build a build of whatever
/// happened to be in the guest, not of the project on screen. Building one item
/// at a time needs that item in the guest first, so this is the step that puts it
/// there.
///
/// Files are transferred base64-encoded rather than pasted. The command travels
/// through the session shell, and anything that looks like a quote, a backslash or
/// a newline in the source would otherwise be reinterpreted on the way in.
@MainActor
final class GuestWorkspaceSync: ObservableObject {
    /// Where a project lands inside the guest.
    ///
    /// `nonisolated` on the immutable constants and the string helpers: the class
    /// is `@MainActor`, and `batches(for:)` runs off the main actor, so anything
    /// it touches must be reachable from a nonisolated context.
    nonisolated static let guestRoot = "/workspace"

    /// The one file-size cap for the sync: `WorkspaceModel` filters by this
    /// constant before reading anything, and `push` refuses anything larger.
    ///
    /// There used to be two: 16 MB in the workspace model, which decided what to
    /// read, and this one, which decided what to send. A 2 MB asset was therefore
    /// read off disk, base64-encoded, and only then dropped by a push that had
    /// already decided it was too big.
    nonisolated static let maximumItemBytes = 512 * 1024

    /// Roughly how much base64 text to put in one shell invocation. A project's
    /// worth of files in a single command is a very long line for the session to
    /// carry, so it is sent in batches.
    private nonisolated static let batchBytes = 96 * 1024

    struct Item: Sendable {
        let relativePath: String
        let data: Data
    }

    /// What a push actually did.
    ///
    /// `complete` exists because the result used to be judged by `pushed > 0`
    /// alone: a push that failed on its third batch out of five still reported the
    /// files that had landed, the caller took that as success, and the build ran
    /// against a half-copied tree.
    struct PushResult: Sendable {
        var pushed: Int
        var skipped: [String]
        var output: String
        var complete: Bool
        /// 1-based index of the batch that failed, when one did.
        var failedBatch: Int?
    }

    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var lastSummary = "Not synced yet."

    /// Pushes `items` under `guestRoot`, replacing what was there.
    ///
    /// The guest root is wiped first. The copy used to be create/overwrite only,
    /// so a deleted or renamed source file stayed in the guest: `make` kept
    /// compiling the deleted one, and a rename produced two files with the same
    /// symbols. Every caller pushes the whole project, so nothing is lost by
    /// starting from an empty directory.
    func push(_ items: [Item],
              session: LinuxGuestSession) async -> PushResult {
        var skipped: [String] = []
        var accepted: [Item] = []
        for item in items {
            // A path that climbs out of the guest workspace is refused outright:
            // the guest is writable and this is remote input.
            guard !item.relativePath.hasPrefix("/"),
                  !item.relativePath.split(separator: "/").contains("..") else { continue }
            guard item.data.count <= Self.maximumItemBytes else {
                skipped.append(item.relativePath)
                continue
            }
            accepted.append(item)
        }

        // Base64-encoding a project is proportional to its size and has no reason
        // to run on the main actor.
        let batches = await Task.detached(priority: .utility) {
            Self.batches(for: accepted)
        }.value

        var pushed = 0
        var output = ""
        var failedBatch: Int?
        for (index, batch) in batches.enumerated() {
            // A subshell, so `set -e` stops this batch at its first failed write
            // without leaving the option set on the long-lived session shell,
            // where the next failing command would take the shell down with it.
            let script = "( set -e\n"
                + "rm -rf \(Self.quoted(Self.guestRoot))\n"
                + "mkdir -p \(Self.quoted(Self.guestRoot))\n"
                + batch.joined(separator: "\n")
                + "\n)"
            let result = await session.run(script, timeout: 180)
            // `code` is the transport's verdict; `status` is the script's own
            // exit status, which is what says whether the writes landed.
            if result.code != 0 || result.status != 0 {
                output += result.output
                failedBatch = index
                break
            }
            pushed += batch.filter { $0.hasPrefix("printf ") }.count
        }
        if !skipped.isEmpty {
            output += "\nSkipped (larger than \(Self.maximumItemBytes / 1024) KB): \(skipped.joined(separator: ", "))\n"
        }
        let complete = failedBatch == nil
        if let failedBatch {
            // A partial copy is not a sync. Reporting one as a success made the
            // caller say "N file(s) copied" after a failure, and the earlier
            // batches' output went down with the batch that broke.
            lastSummary = "Copy failed on batch \(failedBatch + 1) of \(batches.count); \(pushed) file(s) landed before the failure."
        } else {
            lastSyncedAt = Date()
            lastSummary = pushed == 0
                ? "Nothing was copied into the guest."
                : "\(pushed) file(s) copied to \(Self.guestRoot) inside the guest."
        }
        return PushResult(pushed: pushed, skipped: skipped, output: output,
                          complete: complete, failedBatch: failedBatch)
    }

    /// Turns items into shell scripts, `batchBytes` of base64 at a time.
    ///
    /// `nonisolated` and static so the encoding can run off the main actor; it
    /// touches nothing but its argument.
    private nonisolated static func batches(for items: [Item]) -> [[String]] {
        var batches: [[String]] = []
        var current: [String] = []
        var currentBytes = 0

        for item in items {
            let destination = guestRoot + "/" + item.relativePath
            let directory = (destination as NSString).deletingLastPathComponent
            let encoded = item.data.base64EncodedString()
            // The budget has to include the shell syntax around the payload, or
            // it bounds nothing: an empty file costs 0 by payload length but ~90
            // bytes by command length, and 5000 of them would make one 400 KB
            // script while the accounting still said "0 / 96 KB".
            let cost = encoded.count + destination.utf8.count + directory.utf8.count + 64
            if !current.isEmpty && currentBytes + cost > batchBytes {
                batches.append(current)
                current = []
                currentBytes = 0
            }
            current.append("mkdir -p \(quoted(directory))")
            current.append("printf '%s' \(quoted(encoded)) | base64 -d > \(quoted(destination))")
            currentBytes += cost
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// POSIX single-quoting, so a path or a base64 blob cannot break out of its
    /// quotes and become part of the command.
    nonisolated static func quoted(_ text: String) -> String {
        guard !text.isEmpty else { return "''" }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
