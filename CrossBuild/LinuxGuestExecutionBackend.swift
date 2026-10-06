import Foundation

/// Runs commands inside the embedded Linux guest.
///
/// This is the backend that makes real Linux toolchains reachable on a stock
/// sideload: the guest is an emulated AArch64 Linux userland running in-process,
/// so "spawning" a process here means the interpreter forks inside its own guest
/// kernel — nothing is exec'd on the host, and no entitlement is involved.
///
/// One important constraint, stated rather than hidden: the engine's interpreter
/// keeps process-global state, so the guest can be booted **once per app launch**.
/// The first command boots it; anything after that reports the limitation instead
/// of silently returning nothing.
struct LinuxGuestExecutionBackend: ExecutionBackend {
    let name = "Linux Guest / Embedded"
    let capabilities = ExecutionCapabilities(
        canSpawnProcesses: true,      // true within the guest, not on the host
        canUseNetwork: false,          // guest networking is not wired up yet
        canAccessWorkspace: false,     // the guest has its own fakefs root
        canInstallPackages: true       // apk runs inside the guest
    )

    /// Timeout used when the caller asks for "no timeout" (0).
    ///
    /// This used to be 900 s while the Settings screen said "Unlimited" and
    /// `CommandRequest` documents 0 as unlimited, so a build marked unlimited was
    /// killed after fifteen minutes. The guest session applies the same ceiling.
    private static let unlimitedCommandTimeout: TimeInterval = 24 * 60 * 60

    func execute(_ request: CommandRequest) async -> CommandResult {
        let started = Date()

        guard LinuxGuestEngine.isLinked else {
            return .init(exitCode: 125, stdout: "", stderr: "The Linux engine is not linked into this build.", duration: 0)
        }

        // A request timeout of 0 means unlimited -- that is what the "Command
        // timeout: Unlimited" setting and `CommandRequest`'s own default both
        // document. Passing it straight through as `max(1, ...)` used to give
        // every guest command one second, which made the whole backend useless
        // for anything but the fastest command.
        let timeout = request.timeout > 0
            ? TimeInterval(request.timeout)
            : Self.unlimitedCommandTimeout

        // Uses the shared session, so the root is booted once and stays up: every
        // command afterwards runs in the same guest, which is what makes this a
        // usable backend rather than a single command.
        // Everything the caller configured about *how* to run this command now
        // travels into the guest. Before this, only `request.command` did: the
        // working directory, the environment (every Compiler -> Environment
        // variable included), the shell, login/interactive mode and the
        // initialization command were all built into CommandRequest and then
        // dropped here, so those settings had no effect on anything.
        let invocation = GuestShellInvocation(
            executable: request.shell ?? "/bin/sh",
            login: request.loginShell,
            interactive: request.interactiveShell,
            persistent: request.persistentSession,
            workingDirectory: request.workingDirectory,
            environment: request.environment
        )
        // The per-request initialization command was built from the setting and
        // then dropped, so editing it after launch did nothing. Run it once, the
        // first time a command carries it.
        await LinuxGuestSession.shared.runInitCommandIfNeeded(request.initCommand)
        let result = await LinuxGuestSession.shared.run(request.command, timeout: timeout, invocation: invocation)
        guard result.code >= 0 else {
            return .init(exitCode: 125, stdout: "", stderr: result.output, duration: Date().timeIntervalSince(started))
        }

        var stdout = result.output
        if !stdout.isEmpty && !stdout.hasSuffix("\n") { stdout += "\n" }
        return .init(exitCode: result.code, stdout: stdout, stderr: "",
                     duration: Date().timeIntervalSince(started))
    }
}

/// The one command worth running first. If this returns output, the guest booted,
/// the interpreter ran a real Linux process, and captured its stdout — which is
/// the single thing that cannot be verified without a device.
enum LinuxGuestSmokeTest {
    static let command = "uname -a && echo '--- hello from the Linux guest ---' && cat /etc/os-release && echo '--- /bin ---' && ls /bin | head -20"
}
