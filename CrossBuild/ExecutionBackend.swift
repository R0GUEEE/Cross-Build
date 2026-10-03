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

struct EmbeddedExecutionBackend: ExecutionBackend {
    let name = "Embedded Runtime"
    private let guest = LinuxGuestExecutionBackend()

    var capabilities: ExecutionCapabilities { guest.capabilities }

    func execute(_ request: CommandRequest) async -> CommandResult {
        await guest.execute(request)
    }
}

@MainActor
enum ExecutionBackendFactory {
    // mode is retained only to migrate old persisted settings. Every legacy
    // helper/remote/jailbreak value resolves to the in-app runtime.
    static func make(mode:String, settings:AppSettings?) -> any ExecutionBackend {
        EmbeddedExecutionBackend()
    }
}
