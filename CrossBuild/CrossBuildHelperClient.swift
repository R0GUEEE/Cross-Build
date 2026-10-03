import Foundation

private struct HelperExecuteRequest: Codable {
    var command: String
    var workingDirectory: String?
    var environment: [String:String]
    var shell: String?
    var loginShell: Bool
    var interactiveShell: Bool
    var initCommand: String?
    var timeout: Int
    var sessionID: String?
}

private struct HelperExecuteResponse: Codable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var duration: Double?
}

private struct HelperHealth: Codable {
    var ready: Bool
    var version: String?
    var capabilities: [String]?
}

struct CrossBuildHelperClient: Sendable {
    let host: String
    let port: Int
    let scheme: String
    let token: String
    let timeout: Int

    private func url(_ path: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme.isEmpty ? "http" : scheme
        c.host = host
        c.port = port
        c.path = path
        return c.url
    }

    func health() async -> (Bool, String) {
        guard let endpoint = url("/v1/health") else { return (false, "Invalid helper endpoint") }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = TimeInterval(max(2, timeout))
        authorize(&request)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return (false, "Helper health check failed")
            }
            let status = try JSONDecoder().decode(HelperHealth.self, from: data)
            return (status.ready, status.version.map { "CrossBuild Helper \($0)" } ?? "CrossBuild Helper")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func execute(_ command: CommandRequest) async -> CommandResult {
        let started = Date()
        guard let endpoint = url("/v1/execute") else {
            return .init(exitCode: 125, stdout: "", stderr: "Invalid CrossBuild Helper endpoint.", duration: 0)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout > 0 ? TimeInterval(timeout) : 3600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        do {
            request.httpBody = try JSONEncoder().encode(HelperExecuteRequest(command: command.command, workingDirectory: command.workingDirectory, environment: command.environment, shell: command.shell, loginShell: command.loginShell, interactiveShell: command.interactiveShell, initCommand: command.initCommand, timeout: command.timeout, sessionID: command.sessionID))
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .init(exitCode: 125, stdout: "", stderr: "Helper returned no HTTP response.", duration: Date().timeIntervalSince(started))
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                return .init(exitCode: 125, stdout: "", stderr: "Helper HTTP \(http.statusCode): \(body)", duration: Date().timeIntervalSince(started))
            }
            let result = try JSONDecoder().decode(HelperExecuteResponse.self, from: data)
            return .init(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr, duration: result.duration ?? Date().timeIntervalSince(started))
        } catch {
            return .init(exitCode: 125, stdout: "", stderr: "Helper transport error: \(error.localizedDescription)", duration: Date().timeIntervalSince(started))
        }
    }

    private func authorize(_ request: inout URLRequest) {
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    }
}
