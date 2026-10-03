import Foundation
import ZIPFoundation

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
    @Published var progress: Double = 0
    @Published var progressStage = "Idle"
    @Published var verboseLog: [String] = []

    let projectsFolderName = "Projects"

    var projectsDirectory: URL {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("Workspace", isDirectory: true)
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
        projectsDirectory.appendingPathComponent(name, isDirectory: true)
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

    func cloneArchive(url: String, branch: String) async {
        errorMessage = nil
        verboseLog.removeAll()
        progress = 0
        isImporting = true
        defer { isImporting = false }
        do {
            let parsed = try parse(url)
            log("Parsed repository: \(parsed.owner)/\(parsed.name)")
            progressStage = "Resolving repository"; progress = 0.08
            let ref = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            let selectedRef = ref.isEmpty ? "HEAD" : ref
            let archiveURL = URL(string: "https://github.com/\(parsed.owner)/\(parsed.name)/archive/\(selectedRef).zip")!
            log("Archive: \(archiveURL.absoluteString)")
            progressStage = "Downloading source archive"; progress = 0.15
            let (temporaryURL, response) = try await URLSession.shared.download(from: archiveURL)
            if let http = response as? HTTPURLResponse {
                log("HTTP status: \(http.statusCode)")
                guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            }
            progress = 0.62
            let dest = destination(owner: parsed.owner, name: parsed.name)
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest); log("Removed existing destination") }
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let zip = dest.appendingPathComponent("source.zip")
            try fm.moveItem(at: temporaryURL, to: zip)
            log("Downloaded archive: \(zip.lastPathComponent)")
            progressStage = "Extracting repository"; progress = 0.78
            let staging = dest.appendingPathComponent(".extract", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try fm.unzipItem(at: zip, to: staging)
            let extracted = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            let sourceRoot: URL
            if extracted.count == 1, (try? extracted[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                sourceRoot = extracted[0]
            } else { sourceRoot = staging }
            let items = try fm.contentsOfDirectory(at: sourceRoot, includingPropertiesForKeys: nil)
            progressStage = "Saving project files"; progress = 0.90
            for item in items {
                let target = dest.appendingPathComponent(item.lastPathComponent)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: item, to: target)
            }
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: zip)
            log("Extracted \(items.count) top-level items")
            log("Saved project to: \(dest.path)")
            let entry = GitRepository(owner: parsed.owner, name: parsed.name, url: parsed.normalized,
                                      branch: ref.isEmpty ? "default" : ref, localPath: dest.path)
            repositories.removeAll { $0.owner == entry.owner && $0.name == entry.name }
            repositories.insert(entry, at: 0)
            progressStage = "Complete"; progress = 1
            status = "Repository imported to \(dest.path)"
        } catch {
            errorMessage = error.localizedDescription
            progressStage = "Failed"
            log("ERROR: \(error.localizedDescription)")
        }
    }

    private func log(_ message: String) {
        verboseLog.append(message)
        status = message
    }

    func remove(_ repository: GitRepository) {
        repositories.removeAll { $0.id == repository.id }
    }
}
