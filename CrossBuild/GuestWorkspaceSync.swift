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
    static let guestRoot = "/workspace"

    struct Item {
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

    /// Pushes `items` under `guestRoot`, creating directories as needed.
    ///
    /// Returns how many landed, which were too large, and the shell output so the
    /// caller can show something when it fails.
    func push(_ items: [Item],
              session: LinuxGuestSession) async -> (pushed: Int, skipped: [String], output: String) {
        var skipped: [String] = []
        var batches: [[String]] = []
        var current: [String] = []
        var currentBytes = 0

        for item in items {
            // A path that climbs out of the guest workspace is refused outright:
            // the guest is writable and this is remote input.
            guard !item.relativePath.hasPrefix("/"),
                  !item.relativePath.split(separator: "/").contains("..") else { continue }
            guard item.data.count <= Self.maximumItemBytes else {
                skipped.append(item.relativePath)
                continue
            }
            let destination = Self.guestRoot + "/" + item.relativePath
            let directory = (destination as NSString).deletingLastPathComponent
            let encoded = item.data.base64EncodedString()
            current.append("mkdir -p \(Self.quoted(directory))")
            current.append("printf '%s' \(Self.quoted(encoded)) | base64 -d > \(Self.quoted(destination))")
            currentBytes += encoded.count
            if currentBytes >= Self.batchBytes {
                batches.append(current)
                current = []
                currentBytes = 0
            }
        }
        if !current.isEmpty { batches.append(current) }

        var pushed = 0
        var output = ""
        for batch in batches {
            let script = (["mkdir -p \(Self.quoted(Self.guestRoot))"] + batch).joined(separator: "\n")
            let result = await session.run(script, timeout: 180)
            if result.code != 0 {
                output += result.output
                break
            }
            pushed += batch.filter { $0.hasPrefix("printf ") }.count
        }
        if !skipped.isEmpty {
            output += "\nSkipped (larger than \(Self.maximumItemBytes / 1024) KB): \(skipped.joined(separator: ", "))\n"
        }
        lastSyncedAt = Date()
        lastSummary = pushed == 0
            ? "Nothing was copied into the guest."
            : "\(pushed) file(s) copied to \(Self.guestRoot) inside the guest."
        return (pushed, skipped, output)
    }

    /// POSIX single-quoting, so a path or a base64 blob cannot break out of its
    /// quotes and become part of the command.
    static func quoted(_ text: String) -> String {
        guard !text.isEmpty else { return "''" }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
