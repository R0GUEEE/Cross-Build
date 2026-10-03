import Foundation

struct CommandRequest: Identifiable, Sendable {
    let id = UUID()
    var command: String
    var workingDirectory: String?
    var environment: [String:String] = [:]
    var shell: String? = nil
    var loginShell = false
    var interactiveShell = false
    var initCommand: String? = nil
    var timeout: Int = 0
    var sessionID: String? = nil
}

struct CommandResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var duration: TimeInterval
    var succeeded: Bool { exitCode == 0 }
}

struct ExecutionCapabilities: Sendable {
    var canSpawnProcesses: Bool
    var canUseNetwork: Bool
    var canAccessWorkspace: Bool
    var canInstallPackages: Bool
}

protocol ExecutionBackend {
    var name: String { get }
    var capabilities: ExecutionCapabilities { get }
    func execute(_ request: CommandRequest) async -> CommandResult
}

struct SideloadExecutionBackend: ExecutionBackend {
    let name = "Sideload / Embedded"
    let capabilities = ExecutionCapabilities(canSpawnProcesses:false, canUseNetwork:true, canAccessWorkspace:true, canInstallPackages:false)
    func execute(_ request: CommandRequest) async -> CommandResult {
        CommandResult(exitCode:126, stdout:"", stderr:"Cross Build cannot spawn arbitrary executables in the stock sideload sandbox. Use an embedded engine or CrossBuild Helper backend.", duration:0)
    }
}

struct HelperExecutionBackend: ExecutionBackend {
    let name: String
    let client: CrossBuildHelperClient
    let localWorkspace: Bool
    let packageAccess: Bool

    var capabilities: ExecutionCapabilities {
        .init(canSpawnProcesses:true, canUseNetwork:true, canAccessWorkspace:localWorkspace, canInstallPackages:packageAccess)
    }

    func execute(_ request: CommandRequest) async -> CommandResult {
        let health = await client.health()
        guard health.0 else {
            return .init(exitCode:125, stdout:"", stderr:"\(name) unavailable: \(health.1)", duration:0)
        }
        return await client.execute(request)
    }
}

@MainActor
enum ExecutionBackendFactory {
    static func make(mode:String, settings:AppSettings?) -> any ExecutionBackend {
        switch mode {
        case "Jailbreak Local":
            let client = CrossBuildHelperClient(
                host: settings?.jailbreakHelperHost ?? "127.0.0.1",
                port: settings?.jailbreakHelperPort ?? 8765,
                scheme: settings?.helperScheme ?? "http",
                token: SecureExecutionSecrets.shared.jailbreakToken,
                timeout: settings?.connectionTimeout ?? 15
            )
            return HelperExecutionBackend(name:"Jailbreak Local", client:client, localWorkspace:true, packageAccess:true)
        case "Remote / Helper", "Remote / SSH":
            let host = settings?.remoteHost.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            guard !host.isEmpty else { return UnavailableExecutionBackend(name:"Remote / Helper", reason:"Configure a remote host.") }
            let client = CrossBuildHelperClient(
                host:host,
                port:settings?.helperPort ?? 8765,
                scheme:settings?.helperScheme ?? "http",
                token:SecureExecutionSecrets.shared.remoteToken,
                timeout:settings?.connectionTimeout ?? 15
            )
            return HelperExecutionBackend(name:"Remote / Helper", client:client, localWorkspace:false, packageAccess:true)
        case "Linux Guest":
            return LinuxGuestExecutionBackend()
        default:
            return SideloadExecutionBackend()
        }
    }
}

struct UnavailableExecutionBackend: ExecutionBackend {
    let name:String
    let reason:String
    let capabilities = ExecutionCapabilities(canSpawnProcesses:false,canUseNetwork:true,canAccessWorkspace:false,canInstallPackages:false)
    func execute(_ request:CommandRequest) async -> CommandResult {
        .init(exitCode:125,stdout:"",stderr:reason,duration:0)
    }
}
