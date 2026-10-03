import Foundation

struct CommandRequest: Identifiable, Sendable {
    let id = UUID()
    var command: String
    var workingDirectory: String?
    var environment: [String:String] = [:]
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
        CommandResult(exitCode:126, stdout:"", stderr:"Cross Build cannot spawn arbitrary compiler executables in the stock sideload sandbox. Select an embedded toolchain or a supported remote/local backend.", duration:0)
    }
}

struct JailbreakExecutionBackend: ExecutionBackend {
    let name = "Jailbreak Local"
    let capabilities = ExecutionCapabilities(canSpawnProcesses:false, canUseNetwork:true, canAccessWorkspace:true, canInstallPackages:false)
    func execute(_ request: CommandRequest) async -> CommandResult {
        // The interface is live; privileged process spawning is intentionally isolated here
        // so a jailbreak helper/daemon can be attached without leaking platform assumptions.
        CommandResult(exitCode:125, stdout:"", stderr:"Jailbreak local backend selected, but no privileged execution helper is connected.", duration:0)
    }
}

struct RemoteExecutionBackend: ExecutionBackend {
    let host: String
    let port: Int
    var name: String { "Remote / SSH" }
    let capabilities = ExecutionCapabilities(canSpawnProcesses:false, canUseNetwork:true, canAccessWorkspace:false, canInstallPackages:false)
    func execute(_ request: CommandRequest) async -> CommandResult {
        CommandResult(exitCode:125, stdout:"", stderr: host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Remote / SSH requires a configured host." : "Remote backend configured for \(host):\(port), but the SSH transport has not been connected yet.", duration:0)
    }
}

enum ExecutionBackendFactory {
    static func make(mode:String, host:String, port:Int) -> any ExecutionBackend {
        switch mode {
        case "Jailbreak Local": return JailbreakExecutionBackend()
        case "Remote / SSH": return RemoteExecutionBackend(host:host,port:port)
        default: return SideloadExecutionBackend()
        }
    }
}
