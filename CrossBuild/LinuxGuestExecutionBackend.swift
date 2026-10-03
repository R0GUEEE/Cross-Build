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
        guard let root = try? LinuxGuestEngine.prepareWritableRoot() else {
            return .init(exitCode: 125, stdout: "",
                         stderr: "No Linux rootfs image is bundled, or it could not be copied to a writable location.",
                         duration: 0)
        }
        guard !LinuxGuestEngine.hasBooted else {
            return .init(exitCode: 125, stdout: "",
                         stderr: "The Linux guest is already booted in this process. The interpreter cannot be restarted, so relaunch the app to run another command.",
                         duration: Date().timeIntervalSince(started))
        }

        // Booting blocks for as long as the command takes, and the guest does its
        // work on its own thread, so keep it off the main actor.
        let command = request.command
        let workingDirectory = request.workingDirectory
        let result = await Task.detached(priority: .userInitiated) {
            LinuxGuestEngine.run(command: command, fakefsRoot: root, workingDirectory: workingDirectory)
        }.value

        var stdout = result.output
        var stderr = result.error
        if !stdout.isEmpty && !stdout.hasSuffix("\n") { stdout += "\n" }
        if !stderr.isEmpty && !stderr.hasSuffix("\n") { stderr += "\n" }

        return .init(exitCode: result.exitCode,
                     stdout: stdout,
                     stderr: stderr,
                     duration: Date().timeIntervalSince(started))
    }
}

/// The one command worth running first. If this returns output, the guest booted,
/// the interpreter ran a real Linux process, and captured its stdout — which is
/// the single thing that cannot be verified without a device.
enum LinuxGuestSmokeTest {
    static let command = "uname -a && echo '--- hello from the Linux guest ---' && cat /etc/os-release && echo '--- /bin ---' && ls /bin | head -20"
}
