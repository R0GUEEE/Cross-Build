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
            let lines = run.output.split(separator:"\n", omittingEmptySubsequences:true).map(String.init)
            let found = lines.first == "FOUND"
            result.append(.init(id:exe,name:name,readiness:found ? .functional : .availableToInstall,
                                version:found ? (lines.dropFirst().first ?? "installed") : "",
                                detail:found ? "Verified inside the Linux guest" : "Available through apk when repository support provides it",
                                executable:exe,packages:packages))
        }
        probes = result
    }

    func install(_ id: String) async -> (Bool,String) {
        guard let probe = probes.first(where:{$0.id == id}), !probe.packages.isEmpty else { return (false,"Unknown toolchain") }
        let packages = probe.packages.joined(separator:" ")
        let result = await LinuxGuestSession.shared.run("apk update && apk add --no-cache \(packages)", timeout: 900)
        await refresh()
        return (result.code == 0, result.output)
    }

    func probe(_ id:String) -> ToolchainProbe? { probes.first{$0.id == id} }
}
