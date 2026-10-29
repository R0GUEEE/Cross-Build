import Foundation

enum ToolchainReadiness: String, Codable, Sendable {
    case unavailable, availableToInstall, installed, configured, functional
}

struct ToolchainProbe: Identifiable, Sendable {
    let id: String
    var name: String
    var readiness: ToolchainReadiness
    var version: String
    var detail: String
    var executable: String
    var packages: [String]
}

@MainActor
final class ToolchainRuntimeManager: ObservableObject {
    @Published private(set) var probes: [ToolchainProbe] = []
    @Published private(set) var isRefreshing = false

    /// Only tools the shipped guest is allowed to carry.
    ///
    /// This list used to also offer clang, cmake, ninja, meson, python3, cargo,
    /// go, zig and node as `apk add` targets -- every one of which
    /// `ToolchainRuntimeArchitecture.forbiddenGuestBuildTools` says must not be in
    /// the image, and whose install needs `apk update` to reach a network that
    /// this backend declares it does not have.
    private static let guestTools: [(String,String,[String])] = [
        ("make","GNU Make",["make"]),
        ("git","Git",["git"]),
        ("dpkg-deb","dpkg",["dpkg"])
    ]

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        guard LinuxGuestEngine.isLinked, LinuxGuestEngine.isRootBundled else {
            probes = Self.guestTools.map { .init(id:$0.0,name:$0.1,readiness:.unavailable,version:"",detail:"Linux guest unavailable",executable:$0.0,packages:$0.2) }
            return
        }
        var result: [ToolchainProbe] = []
        for (exe,name,packages) in Self.guestTools {
            let command = "if command -v \(exe) >/dev/null 2>&1; then printf 'FOUND\\n'; \(exe) --version 2>&1 | head -1; else printf 'MISSING\\n'; fi"
            let run = await LinuxGuestSession.shared.run(command, timeout: 15)
            guard run.code >= 0 else {
                // The guest did not answer. That is not the same as "the tool is
                // missing", and it certainly does not mean "you can install it":
                // the old code read a non-FOUND first line as exactly that and
                // offered a working Install button against a guest that was not
                // running.
                result.append(.init(id:exe,name:name,readiness:.unavailable,version:"",
                                    detail:run.output.isEmpty ? "The Linux guest did not answer." : run.output,
                                    executable:exe,packages:packages))
                continue
            }
            let lines = run.output.split(separator:"\n", omittingEmptySubsequences:true).map(String.init)
            let found = lines.first == "FOUND"
            result.append(.init(id:exe,name:name,readiness:found ? .functional : .availableToInstall,
                                version:found ? (lines.dropFirst().first ?? "installed") : "",
                                detail:found ? "Verified inside the Linux guest" : "Not present in this guest root",
                                executable:exe,packages:packages))
        }
        probes = result
    }

    func install(_ id: String) async -> (Bool,String) {
        guard let probe = probes.first(where:{$0.id == id}), !probe.packages.isEmpty else { return (false,"Unknown toolchain") }
        let packages = probe.packages.joined(separator:" ")
        // `apk update` needs a network the guest does not have
        // (`ExecutionCapabilities.canUseNetwork` is false), so this can only fail.
        // Say so instead of running a command that cannot work and then reporting
        // success because the transport returned 0.
        guard LinuxGuestExecutionBackend().capabilities.canUseNetwork else {
            return (false, "The embedded Linux guest has no network access, so apk cannot fetch \(packages). Rebuild the bundled rootfs with the package included.")
        }
        let result = await LinuxGuestSession.shared.run("apk update && apk add --no-cache \(packages)", timeout: 900)
        let ok = result.code == 0 && result.status == 0
        await refresh()
        return (ok, result.output)
    }

}
