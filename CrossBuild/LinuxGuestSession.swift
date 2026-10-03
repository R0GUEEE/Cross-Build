import Foundation
#if canImport(CrossBuildLinux)
import CrossBuildLinux
#endif

/// Owns the one long-lived Linux guest for the process.
///
/// The interpreter cannot be restarted, so the guest is booted exactly once —
/// automatically, as soon as the app needs it — and every command afterwards is
/// streamed to the same running shell. That is what makes the root "started"
/// rather than a single command that happens to have run.
@MainActor
final class LinuxGuestSession: ObservableObject {
    static let shared = LinuxGuestSession()

    enum State: Equatable {
        case idle
        case starting
        case running
        case unavailable(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Serialises command execution: the guest shell is a single stream, so two
    /// concurrent commands would interleave their output.
    private var queue: Task<Void, Never>?

    private init() {}

    var isRunning: Bool { state == .running }

    /// Boots the guest if it is not already up. Safe to call from anywhere and as
    /// often as you like; concurrent callers wait for the same boot.
    func startIfNeeded() async {
        if state == .running || state == .starting { return }
        await boot()
    }

    private func boot() async {
        guard LinuxGuestEngine.isLinked else {
            state = .unavailable("The Linux engine is not linked into this build.")
            return
        }
        guard LinuxGuestEngine.isRootBundled else {
            state = .unavailable("No Linux rootfs image is bundled with this build.")
            return
        }
        state = .starting
        // Booting runs an emulated kernel and takes real time, and the guest works
        // on its own thread, so keep this off the main actor.
        let failure: String? = await Task.detached(priority: .userInitiated) {
            do {
                let root = try LinuxGuestEngine.prepareWritableRoot()
                #if canImport(CrossBuildLinux)
                let code = cblk_session_start(root, "/root")
                return code == 0 ? nil : "The guest failed to start (code \(code))."
                #else
                return "The Linux engine was not linked into this build."
                #endif
            } catch {
                return error.localizedDescription
            }
        }.value

        if let failure { state = .failed(failure) } else { state = .running }
    }

    /// Runs one command in the running shell and returns its combined output.
    func run(_ command: String, timeout: TimeInterval = 120) async -> (code: Int32, output: String) {
        await startIfNeeded()
        guard state == .running else {
            switch state {
            case .unavailable(let message), .failed(let message): return (-1, message)
            default: return (-1, "The Linux guest is not running.")
            }
        }

        // Chain onto the queue so two commands cannot interleave their output,
        // then hop off the main actor because the guest does real work.
        let previous = queue
        let milliseconds = Int32(max(1, timeout) * 1000)
        let task = Task { () -> (Int32, String) in
            await previous?.value
            return await Task.detached(priority: .userInitiated) {
                #if canImport(CrossBuildLinux)
                var outPointer: UnsafeMutablePointer<CChar>?
                let code = cblk_session_run(command, milliseconds, &outPointer)
                return (code, outPointer.map { String(cString: $0) } ?? "")
                #else
                return (Int32(-1), "The Linux engine was not linked into this build.")
                #endif
            }.value
        }
        queue = Task { _ = await task.value }
        return await task.value
    }
}
