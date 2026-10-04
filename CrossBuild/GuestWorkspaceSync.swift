import Foundation
import CryptoKit

/// Copies workspace files into the Linux guest.
///
/// The guest boots from its own filesystem image, so the iOS workspace directory
/// does not exist inside it -- the app's own `cd` fallback says as much ("... is
/// not a directory inside the guest"). That made every build a build of whatever
/// happened to be in the guest, not of the project on screen. Building one item
/// at a time needs that item in the guest first, so this is the step that puts it
/// there.
///
/// **This is the expensive step, and it used to be paid in full on every build.**
/// Every file was re-read from the iOS workspace, re-encoded and pushed again
/// whether or not it had changed, and each one cost two fork/exec pairs inside
/// the *emulated* guest (`printf | base64 -d`, plus its own `mkdir -p`). Under the
/// interpreter a fork/exec is one of the most expensive things the guest does, so
/// a project of a few hundred files spent almost all of its build time copying
/// itself into a guest that already had it.
///
/// Three things changed, in order of how much they matter:
///
/// 1. **Only what changed is sent.** Every file carries a digest of its bytes;
///    a file whose digest is already in the guest is skipped entirely, so the
///    second and every later build of a project pays for the edit, not for the
///    project. The record lives here, in memory, so it is exactly as long-lived
///    as the guest it describes.
/// 2. **Text is sent as a here-document, not as base64.** `cat > file <<'MARKER'`
///    is one process and no expansion, where `printf ... | base64 -d` was a
///    pipeline (a forked subshell plus `base64`) and inflated every file by a
///    third. Base64 stays as the fallback for anything a shell would mangle:
///    NUL bytes, no trailing newline, or a line equal to the delimiter.
/// 3. **Directories are created once per batch**, with one `mkdir -p` listing
///    every directory the batch needs, instead of one process per file.
///
/// Deletion is tracked too: `removingStale` removes what the project no longer
/// contains, so a rename cannot leave the old translation unit behind for the
/// compiler to pick up again.
@MainActor
final class GuestWorkspaceSync: ObservableObject {
    /// Where a project lands inside the guest.
    static let guestRoot = "/workspace"

    struct Item: Sendable {
        let relativePath: String
        let data: Data
    }

    /// Largest single file pushed. Anything bigger is reported rather than
    /// silently truncated.
    static let maximumItemBytes = 512 * 1024

    /// Roughly how much base64 text to put in one shell invocation. A project's
    /// worth of files in a single command is a very long line for the session to
    /// carry, so it is sent in batches.
    private static let batchBytes = 96 * 1024

    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var lastSummary = "Not synced yet."

    /// Digest of every file this session has put in the guest, by path relative
    /// to `guestRoot`. A file whose digest is unchanged is not sent again.
    private var pushedDigests: [String: String] = [:]
    /// Every path this session has ever pushed, so a stale one can be removed.
    private var pushedPaths: Set<String> = []

    /// Forgets what has been pushed, so the next `push` sends everything again.
    ///
    /// The record describes a guest that this process booted and that nothing
    /// else is expected to touch, so it is only needed to answer an explicit
    /// "copy it all again" -- which is what the Sync button does, and which is how
    /// a `/workspace` emptied from inside the guest is repaired.
    func forgetPushedState() {
        pushedDigests.removeAll()
        pushedPaths.removeAll()
    }

    /// Pushes `items` under `guestRoot`, creating directories as needed.
    ///
    /// Returns how many files were written, how many were already current, how
    /// many were removed as stale, which were too large, and the shell output so
    /// the caller can show something when it fails.
    func push(_ items: [Item],
              session: LinuxGuestSession,
              removingStale: Bool = false) async -> (pushed: Int, unchanged: Int, removed: Int, skipped: [String], output: String) {
        var skipped: [String] = []
        var unchanged = 0
        var pending: [(relative: String, destination: String, digest: String, payload: Payload)] = []
        var kept: Set<String> = []

        for item in items {
            // A path that climbs out of the guest workspace is refused outright:
            // the guest is writable and this is remote input.
            guard !item.relativePath.hasPrefix("/"),
                  !item.relativePath.split(separator: "/").contains("..") else { continue }
            // Recorded before the size check: a file that is too large to send is
            // still part of the project, and must not be treated as stale.
            kept.insert(item.relativePath)
            guard item.data.count <= Self.maximumItemBytes else {
                skipped.append(item.relativePath)
                continue
            }
            let digest = Self.digest(item.data)
            if pushedDigests[item.relativePath] == digest {
                unchanged += 1
                continue
            }
            pending.append((item.relativePath,
                            Self.guestRoot + "/" + item.relativePath,
                            digest,
                            Self.payload(for: item.data)))
        }

        // One command list per batch, plus the files it is responsible for, so a
        // batch that succeeds can be recorded and a batch that fails cannot.
        var batches: [(lines: [String], files: [(String, String)])] = []
        var lines: [String] = []
        var files: [(String, String)] = []
        var bytes = 0
        var directories = Set<String>()
        var neededDirectories: [String] = []

        func closeBatch() {
            guard !lines.isEmpty else { return }
            batches.append((lines, files))
            lines = []
            files = []
            bytes = 0
        }

        for entry in pending {
            let directory = (entry.destination as NSString).deletingLastPathComponent
            if directories.insert(directory).inserted {
                neededDirectories.append(directory)
            }
            lines.append(entry.payload.command(writingTo: entry.destination))
            files.append((entry.relative, entry.digest))
            bytes += entry.payload.size
            if bytes >= Self.batchBytes { closeBatch() }
        }
        closeBatch()

        var pushed = 0
        var output = ""
        var completed = true

        if !batches.isEmpty {
            // Every directory the whole push needs, made once, with one mkdir
            // process rather than one per file. `mkdir -p` is an external applet
            // in the guest, so this is not a micro-optimisation: it was two
            // fork/execs per file before.
            let directoriesLine = neededDirectories.isEmpty
                ? nil
                : "mkdir -p " + neededDirectories.map(Self.quoted).joined(separator: " ")
            var first = true
            for batch in batches {
                var script = ["mkdir -p \(Self.quoted(Self.guestRoot))"]
                if first, let directoriesLine { script.append(directoriesLine) }
                first = false
                script.append(contentsOf: batch.lines)
                let result = await session.run(script.joined(separator: "\n"), timeout: 180)
                if result.code != 0 {
                    output += result.output
                    completed = false
                    break
                }
                for (relative, digest) in batch.files {
                    pushedDigests[relative] = digest
                    pushedPaths.insert(relative)
                }
                pushed += batch.files.count
            }
        }

        // Only prune when everything above landed: removing a file whose
        // replacement never arrived would lose it from both sides.
        var removed = 0
        if removingStale && completed {
            let stale = pushedPaths.subtracting(kept).sorted()
            if !stale.isEmpty {
                for slice in stride(from: 0, to: stale.count, by: 64).map({ Array(stale[$0..<min($0 + 64, stale.count)]) }) {
                    let command = "rm -f " + slice.map { Self.quoted(Self.guestRoot + "/" + $0) }.joined(separator: " ")
                    let result = await session.run(command, timeout: 60)
                    if result.code != 0 {
                        output += result.output
                        completed = false
                        break
                    }
                    removed += slice.count
                }
                for relative in stale.prefix(removed) {
                    pushedPaths.remove(relative)
                    pushedDigests.removeValue(forKey: relative)
                }
            }
        }

        if !skipped.isEmpty {
            output += "\nSkipped (larger than \(Self.maximumItemBytes / 1024) KB): \(skipped.joined(separator: ", "))\n"
        }
        lastSyncedAt = Date()
        lastSummary = Self.summary(pushed: pushed, unchanged: unchanged, removed: removed)
        return (pushed, unchanged, removed, skipped, output)
    }

    private static func summary(pushed: Int, unchanged: Int, removed: Int) -> String {
        if pushed == 0 && removed == 0 {
            return unchanged == 0
                ? "Nothing was copied into the guest."
                : "\(unchanged) file(s) already current in \(guestRoot)."
        }
        var parts = ["\(pushed) file(s) copied to \(guestRoot) inside the guest"]
        if unchanged > 0 { parts.append("\(unchanged) already current") }
        if removed > 0 { parts.append("\(removed) removed") }
        return parts.joined(separator: ", ") + "."
    }

    // MARK: - Payload

    /// How one file's bytes travel to the guest.
    ///
    /// The command text is what the *emulated* shell has to read and execute, so
    /// the shape matters as much as the size: a quoted here-document is fed
    /// straight to a single `cat`, where base64 needs a pipeline and carries the
    /// file a third larger.
    enum Payload {
        /// `cat > file <<'MARKER'` -- the shell feeds the text to cat verbatim.
        case hereDocument(marker: String, text: String)
        /// `printf '%s' '<base64>' | base64 -d > file`.
        case base64(String)

        var size: Int {
            switch self {
            case .hereDocument(_, let text): return text.utf8.count
            case .base64(let encoded): return encoded.count
            }
        }

        func command(writingTo destination: String) -> String {
            switch self {
            case .hereDocument(let marker, let text):
                // Quoted delimiter: the shell expands nothing inside it, so the
                // bytes reach cat exactly as they are. `cat` is one process where
                // the base64 form needed a pipeline, and the payload is the file
                // itself rather than a third larger. A trailing newline is
                // required for the here-document to end, which is why
                // `payload(for:)` only chooses this form for text that already
                // ends with one.
                return "cat > \(GuestWorkspaceSync.quoted(destination)) <<'\(marker)'\n\(text)\(marker)"
            case .base64(let encoded):
                return "printf '%s' \(GuestWorkspaceSync.quoted(encoded)) | base64 -d > \(GuestWorkspaceSync.quoted(destination))"
            }
        }
    }

    /// Picks the cheapest form that reproduces `data` byte for byte.
    ///
    /// A here-document is written verbatim by the shell, so it is only safe when
    /// nothing in the shell or the here-document reader would change the bytes:
    /// no NUL (a shell drops it), a trailing newline (the reader ends at one), and
    /// no line equal to the delimiter.
    nonisolated static func payload(for data: Data) -> Payload {
        if let text = hereDocumentText(for: data) {
            let marker = "CB_EOF_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            if !containsLine(text, marker) {
                return .hereDocument(marker: marker, text: text)
            }
        }
        return .base64(data.base64EncodedString())
    }

    nonisolated private static func hereDocumentText(for data: Data) -> String? {
        // The here-document reader stops at the first line equal to the
        // delimiter and ends at a newline, so a file that does not end with one,
        // or that contains a NUL, cannot be sent this way. A carriage return is
        // carried through untouched: there is no terminal on this pipe.
        guard data.last == 0x0A, !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// True when `marker` appears as a whole line of `text`.
    nonisolated private static func containsLine(_ text: String, _ marker: String) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) where line == Substring(marker) {
            return true
        }
        return false
    }

    /// Content digest, used to decide whether a file has to travel at all.
    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// POSIX single-quoting, so a path or a payload cannot break out of its
    /// quotes and become part of the command.
    nonisolated static func quoted(_ text: String) -> String {
        guard !text.isEmpty else { return "''" }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
