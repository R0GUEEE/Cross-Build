import Foundation
#if canImport(CrossBuildLinux)
import CrossBuildLinux
#endif

/// How one command should be run inside the guest shell.
///
/// These travel with the command rather than being read from settings at boot,
/// because the guest boots exactly once per launch while every one of them can
/// change while the app is running.
struct GuestShellInvocation {
    /// Shell to run the command with. The session shell itself is always
    /// `/bin/sh` -- the one shell the bundled root is guaranteed to carry -- so
    /// any other value is run as a child of it.
    var executable: String = "/bin/sh"
    /// A login shell reads `/etc/profile` first.
    var login = false
    var interactive = false
    /// True keeps one shell alive, so `cd` and `export` carry over from one
    /// command to the next; false runs each command in its own subshell.
    var persistent = true
    var workingDirectory: String? = nil
    var environment: [String: String] = [:]
}

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
    private var bootTask: Task<String?, Never>?

    /// User-supplied setup, run once after the guest comes up. Held here rather
    /// than read per command because it is a property of the boot.
    private var initCommand = ""

    /// Output produced by `initCommand`, shown once on the next command so the
    /// user is not left guessing whether their setup ran.
    private var pendingInitOutput: String?

    /// Initialization commands this process has already run. The guest boots once
    /// per launch, so boot-time setup runs once; a per-command initialization
    /// command has to be remembered separately or it would run every time.
    private var appliedInitCommands: Set<String> = []

    /// Returned by the shim when the shell reading commands has exited. Negative
    /// and distinct from -1 (never started) and 124 (deadline passed).
    private static let shellExitedCode: Int32 = -3

    private init() {}

    var isRunning: Bool { state == .running }

    /// Records the setup command run once after the guest boots. Call before the
    /// first command; later calls only take effect if the guest never booted.
    func configure(initCommand: String) {
        self.initCommand = initCommand
    }

    /// Boots the guest if it is not already up. Safe to call from anywhere and as
    /// often as you like; concurrent callers wait for the same boot.
    func startIfNeeded() async {
        if state == .running { return }
        // A boot has already been attempted and failed. The interpreter cannot be
        // initialised twice, so retrying here could only produce a second, less
        // accurate error (cblk_session_start answers -1 for "already booted").
        // A boot that failed before the interpreter initialised (no pipes, no
        // thread) is still retryable; once it has initialised it is not, and the
        // shim says which happened. Treating both as permanent meant one transient
        // failure disabled the guest -- and with it every toolchain probe -- for
        // the rest of the session.
        if case .failed = state, LinuxGuestEngine.hasBooted { return }
        if case .failed = state { state = .idle }
        if let bootTask {
            let failure = await bootTask.value
            if let failure { state = .failed(failure) } else { state = .running }
            return
        }
        guard LinuxGuestEngine.isLinked else {
            state = .unavailable("The Linux engine is not linked into this build.")
            return
        }
        guard LinuxGuestEngine.isRootBundled else {
            state = .unavailable("No Linux rootfs image is bundled with this build.")
            return
        }

        state = .starting
        // The result type is spelled out: with `return nil` as its own statement
        // the closure's type cannot be inferred from a single ternary any more.
        let task = Task.detached(priority: .userInitiated) { () -> String? in
            do {
                let root = try LinuxGuestEngine.prepareWritableRoot()
                #if canImport(CrossBuildLinux)
                let code = cblk_session_start(root, "/root")
                if code == 0 { return nil }
                if code == -4 {
                    return "The guest started but its shell did not answer within "
                        + "\(Self.readinessWindowSeconds) seconds, so no command can be run. "
                        + "Relaunch Cross Build to try again."
                }
                return "The guest failed to start (code \(code))."
                #else
                return "The Linux engine was not linked into this build."
                #endif
            } catch {
                return error.localizedDescription
            }
        }
        bootTask = task
        let failure = await task.value
        bootTask = nil
        if let failure {
            state = .failed(failure)
            return
        }
        state = .running

        let setup = initCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !setup.isEmpty, appliedInitCommands.insert(setup).inserted {
            // The guest is up, so this goes straight to the running shell. A
            // failing setup command is reported through the console rather than
            // treated as a boot failure: it is user shell, not part of the boot.
            let result = await run(setup, timeout: 120)
            if !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pendingInitOutput = "$ \(setup)\n\(result.output)"
            }
        }
    }

    /// Runs a command's initialization command once, if it has not run already.
    ///
    /// `CommandRequest.initCommand` was assembled from the "Initialization
    /// command" setting and then dropped on the floor: nothing read it, so
    /// changing that setting after launch changed nothing. This is where it takes
    /// effect -- once per distinct command, for the life of the process.
    func runInitCommandIfNeeded(_ command: String?) async {
        let setup = (command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !setup.isEmpty else { return }
        await startIfNeeded()
        guard state == .running, !appliedInitCommands.contains(setup) else { return }
        appliedInitCommands.insert(setup)
        let result = await run(setup, timeout: 120)
        if !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingInitOutput = "$ \(setup)\n\(result.output)"
        }
    }

    /// Runs one command in the running shell and returns its combined output.
    ///
    /// `timeout` follows the app-wide convention: a value of 0 (or less) means
    /// "no timeout", not "expire immediately". It must be handled here as well as
    /// in the backend, because a bare `max(1, timeout)` would silently turn the
    /// documented Unlimited setting into a one-second kill.
    func run(_ command: String,
             timeout: TimeInterval = 120,
             invocation: GuestShellInvocation = GuestShellInvocation()) async -> (code: Int32, output: String) {
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
        let seconds = Self.effectiveTimeout(timeout)
        let milliseconds = Int32(min(seconds, Self.maximumTimeoutSeconds) * 1000)
        let script = Self.script(for: command, invocation: invocation)
        let task = Task { () -> (Int32, String) in
            await previous?.value
            let result = await Task.detached(priority: .userInitiated) { () -> (Int32, String) in
                #if canImport(CrossBuildLinux)
                var outPointer: UnsafeMutablePointer<CChar>?
                let code = cblk_session_run(script, milliseconds, &outPointer)
                let output = outPointer.map { String(cString: $0) } ?? ""
                // cblk_session_run returns its internal scratch buffer on success,
                // but strdup()s the message on its error paths (negative code).
                // Those are the only ones we own, and leaking them leaks once per
                // failure for the life of the process.
                if code < 0, let outPointer { cblk_free(outPointer) }
                return (code, output)
                #else
                return (Int32(-1), "The Linux engine was not linked into this build.")
                #endif
            }.value
            if result.0 == Self.shellExitedCode {
                // Terminal: there is no shell left to send anything to, and the
                // interpreter cannot be booted again in this process.
                self.state = .failed(result.1)
            }
            return result
        }
        queue = Task { _ = await task.value }
        var result = await task.value
        if let setupOutput = pendingInitOutput {
            pendingInitOutput = nil
            result.1 = result.1.isEmpty ? setupOutput : setupOutput + "\n" + result.1
        }
        return result
    }

    /// Turns a command plus its invocation into the shell script actually sent to
    /// the guest.
    ///
    /// The settings for the embedded shell — login shell, initialization command,
    /// configured environment, working directory — used to stop at
    /// `CommandRequest`; the guest backend ignored every one of them, so the only
    /// thing that ever reached the guest was the bare command. This is where they
    /// take effect.
    private static func script(for command: String, invocation: GuestShellInvocation) -> String {
        let configured = invocation.executable.trimmingCharacters(in: .whitespacesAndNewlines)
        let shell = configured.isEmpty ? "/bin/sh" : configured
        // The session shell is /bin/sh, so a different shell has to be started as
        // a child, and a child cannot inherit the session's `cd`/`export` state.
        // That is also what "Persistent terminal session: off" asks for.
        // `interactive` is part of this decision, not only of the wrapper below:
        // with the default settings (persistent session, /bin/sh) nothing wrapped
        // the command, so turning "Interactive shell" on changed nothing at all.
        let wraps = !invocation.persistent || shell != "/bin/sh" || invocation.interactive

        var lines: [String] = []
        // When the command is wrapped, the shell's own -l reads /etc/profile;
        // otherwise it is sourced explicitly so the toggle means the same thing
        // either way.
        if invocation.login && !wraps { lines.append(". /etc/profile >/dev/null 2>&1 || true") }
        for (key, value) in invocation.environment.sorted(by: { $0.key < $1.key }) where isShellIdentifier(key) {
            lines.append("export \(key)=\(quoted(value))")
        }
        if let directory = invocation.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directory.isEmpty {
            // The guest has its own filesystem, so an iOS container path is not a
            // directory in it. Say so and carry on in the guest's current
            // directory rather than failing the command with a bare "not found".
            lines.append("cd \(quoted(directory)) 2>/dev/null || "
                + "printf 'crossbuild: %s is not a directory inside the guest; running in %s\\n' "
                + "\(quoted(directory)) \"$PWD\"")
        }
        lines.append(command)
        let body = lines.joined(separator: "\n")
        guard wraps else { return body }

        var words = [quoted(shell)]
        if invocation.login { words.append("-l") }
        if invocation.interactive { words.append("-i") }
        words.append("-c")
        words.append(quoted(body))
        return words.joined(separator: " ")
    }

    /// POSIX single-quoting. Everything is literal between single quotes, and an
    /// embedded quote is closed, escaped and reopened.
    private static func quoted(_ text: String) -> String {
        guard !text.isEmpty else { return "''" }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isShellIdentifier(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// How long the boot waits for the guest's shell to answer a marker, in
    /// seconds. Mirrors the window in `cblk_session_start`; the two are quoted
    /// together in the failure message so they cannot drift silently.
    static let readinessWindowSeconds = 120

    /// Upper bound for a single command, in seconds. This is what "no timeout"
    /// means in practice: the C shim is handed `Int32` milliseconds, so ~24.8 days
    /// is the arithmetic ceiling, and a command still running a day later is not
    /// going to finish. It used to be one hour, which quietly contradicted the
    /// Settings screen's "Unlimited" label.
    private static let maximumTimeoutSeconds: TimeInterval = 24 * 60 * 60

    private static func effectiveTimeout(_ timeout: TimeInterval) -> TimeInterval {
        guard timeout > 0 else { return maximumTimeoutSeconds }
        return timeout
    }
}
