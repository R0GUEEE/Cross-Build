import Foundation

struct GitRepository: Identifiable, Codable, Hashable {
    var id = UUID()
    var owner: String
    var name: String
    var url: String
    var branch: String
    var localPath: String
    var clonedAt = Date()
}

enum GitCloneMode: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case git = "Git Clone"
    case archive = "Archive Import"
    var id: String { rawValue }
}

enum GitHubImportError: LocalizedError {
    case invalidURL
    var errorDescription: String? { "Enter a valid GitHub repository URL such as https://github.com/owner/repository." }
}

@MainActor
final class GitHubWorkspaceService: ObservableObject {
    @Published var repositories: [GitRepository] = []
    @Published var isImporting = false
    @Published var status = ""
    @Published var errorMessage: String?

    let projectsFolderName = "Projects"

    var projectsDirectory: URL {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent(projectsFolderName, isDirectory: true)
    }

    init() {
        try? FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
    }

    func parse(_ input: String) throws -> (owner: String, name: String, normalized: String) {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("git@github.com:") {
            raw = "https://github.com/" + raw.dropFirst("git@github.com:".count)
        }
        guard let url = URL(string: raw), url.host?.lowercased() == "github.com" else { throw GitHubImportError.invalidURL }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { throw GitHubImportError.invalidURL }
        let owner = parts[0]
        let name = parts[1].replacingOccurrences(of: ".git", with: "")
        guard !owner.isEmpty, !name.isEmpty else { throw GitHubImportError.invalidURL }
        return (owner, name, "https://github.com/\(owner)/\(name).git")
    }

    func destination(owner: String, name: String) -> URL {
        projectsDirectory.appendingPathComponent("\(owner)-\(name)", isDirectory: true)
    }

    func registerImportedRepository(url: String, branch: String) throws -> GitRepository {
        let parsed = try parse(url)
        let dest = destination(owner: parsed.owner, name: parsed.name)
        let entry = GitRepository(owner: parsed.owner, name: parsed.name, url: parsed.normalized,
                                  branch: branch.isEmpty ? "default" : branch, localPath: dest.path)
        repositories.removeAll { $0.owner == entry.owner && $0.name == entry.name }
        repositories.insert(entry, at: 0)
        status = "Repository destination prepared at \(dest.lastPathComponent)"
        return entry
    }

    func remove(_ repository: GitRepository) {
        repositories.removeAll { $0.id == repository.id }
    }
}
