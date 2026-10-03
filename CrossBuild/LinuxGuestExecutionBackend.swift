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

    func execute(_ request: CommandRequest) async -> CommandResult {
        let started = Date()

        guard LinuxGuestEngine.isLinked else {
            return .init(exitCode: 125, stdout: "", stderr: "The Linux engine is not linked into this build.", duration: 0)
        }

        // Uses the shared session, so the root is booted once and stays up: every
        // command afterwards runs in the same guest, which is what makes this a
        // usable backend rather than a single command.
        let result = await LinuxGuestSession.shared.run(request.command, timeout: TimeInterval(max(1, request.timeout)))
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
