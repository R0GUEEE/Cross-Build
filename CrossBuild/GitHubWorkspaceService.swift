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
    case emptyArchive
    case invalidArchive

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid GitHub repository URL such as https://github.com/owner/repository."
        case .emptyArchive:
            return "The downloaded repository archive did not contain any project files."
        case .invalidArchive:
            return "The downloaded repository archive could not be prepared safely."
        }
    }
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
    @Published var lastImportedPath: String?

    private let repositoriesKey = "crossbuild.github.repositories"

    var projectsDirectory: URL {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("Workspace", isDirectory: true)
    }

    init() {
        try? FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        if let data = UserDefaults.standard.data(forKey: repositoriesKey),
           let saved = try? JSONDecoder().decode([GitRepository].self, from: data) {
            repositories = saved.filter { FileManager.default.fileExists(atPath: $0.localPath) }
        }
    }

    func parse(_ input: String) throws -> (owner: String, name: String, normalized: String) {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("git@github.com:") {
            raw = "https://github.com/" + raw.dropFirst("git@github.com:".count)
        }
        if !raw.contains("://"), raw.split(separator: "/").count >= 2 {
            raw = "https://github.com/" + raw
        }

        guard let url = URL(string: raw),
              url.host?.lowercased() == "github.com" else {
            throw GitHubImportError.invalidURL
        }

        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { throw GitHubImportError.invalidURL }

        let owner = parts[0]
        var name = parts[1]
        if name.hasSuffix(".git") { name.removeLast(4) }
        guard !owner.isEmpty, !name.isEmpty else { throw GitHubImportError.invalidURL }

        return (owner, name, "https://github.com/\(owner)/\(name).git")
    }

    func destination(owner: String, name: String) -> URL {
        projectsDirectory.appendingPathComponent(name, isDirectory: true)
    }

    func registerImportedRepository(url: String, branch: String) throws -> GitRepository {
        let parsed = try parse(url)
        let dest = destination(owner: parsed.owner, name: parsed.name)
        let entry = GitRepository(
            owner: parsed.owner,
            name: parsed.name,
            url: parsed.normalized,
            branch: branch.isEmpty ? "default" : branch,
            localPath: dest.path
        )
        upsert(entry)
        status = "Repository destination prepared at \(dest.lastPathComponent)"
        return entry
    }

    func cloneArchive(url: String, branch: String) async {
        errorMessage = nil
        verboseLog.removeAll()
        progress = 0
        progressStage = "Starting"
        lastImportedPath = nil

        guard !isImporting else {
            errorMessage = "A repository import is already in progress."
            return
        }

        isImporting = true
        defer { isImporting = false }

        let fm = FileManager.default
        let transactionRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossBuildImport-\(UUID().uuidString)", isDirectory: true)
        var backupURL: URL?
        var destinationURL: URL?

        do {
            let parsed = try parse(url)
            log("Parsed repository: \(parsed.owner)/\(parsed.name)")
            progressStage = "Resolving repository"
            progress = 0.08

            let ref = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            let selectedRef = ref.isEmpty ? "HEAD" : ref
            guard let encodedRef = selectedRef.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let archiveURL = URL(string: "https://github.com/\(parsed.owner)/\(parsed.name)/archive/\(encodedRef).zip") else {
                throw GitHubImportError.invalidURL
            }

            try fm.createDirectory(at: transactionRoot, withIntermediateDirectories: true)
            let downloadedZip = transactionRoot.appendingPathComponent("source.zip")
            let extractRoot = transactionRoot.appendingPathComponent("extract", isDirectory: true)

            progressStage = "Downloading source archive"
            progress = 0.15
            let (temporaryURL, response) = try await URLSession.shared.download(from: archiveURL)
            if let http = response as? HTTPURLResponse {
                log("HTTP status: \(http.statusCode)")
                guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            }
            try fm.moveItem(at: temporaryURL, to: downloadedZip)
            progress = 0.60

            progressStage = "Validating archive"
            try fm.createDirectory(at: extractRoot, withIntermediateDirectories: true)
            try fm.unzipItem(at: downloadedZip, to: extractRoot)

            let extracted = try fm.contentsOfDirectory(
                at: extractRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            guard !extracted.isEmpty else { throw GitHubImportError.emptyArchive }

            let sourceRoot: URL
            if extracted.count == 1,
               (try? extracted[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                sourceRoot = extracted[0]
            } else {
                sourceRoot = extractRoot
            }

            let projectItems = try fm.contentsOfDirectory(
                at: sourceRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            guard !projectItems.isEmpty else { throw GitHubImportError.emptyArchive }

            progressStage = "Installing project"
            progress = 0.82

            let dest = destination(owner: parsed.owner, name: parsed.name)
            destinationURL = dest
            if fm.fileExists(atPath: dest.path) {
                let backup = projectsDirectory.appendingPathComponent(
                    ".\(parsed.name)-backup-\(UUID().uuidString)",
                    isDirectory: true
                )
                try fm.moveItem(at: dest, to: backup)
                backupURL = backup
                log("Existing project moved to a temporary backup")
            }

            do {
                try fm.moveItem(at: sourceRoot, to: dest)
            } catch {
                if let backup = backupURL, fm.fileExists(atPath: backup.path), !fm.fileExists(atPath: dest.path) {
                    try? fm.moveItem(at: backup, to: dest)
                    backupURL = nil
                }
                throw error
            }

            if let backup = backupURL {
                try? fm.removeItem(at: backup)
                backupURL = nil
            }

            let entry = GitRepository(
                owner: parsed.owner,
                name: parsed.name,
                url: parsed.normalized,
                branch: ref.isEmpty ? "default" : ref,
                localPath: dest.path
            )
            upsert(entry)

            lastImportedPath = dest.path
            progressStage = "Complete"
            progress = 1
            status = "Repository imported to \(dest.path)"
            log("Saved project to: \(dest.path)")
        } catch {
            if let dest = destinationURL,
               let backup = backupURL,
               fm.fileExists(atPath: backup.path),
               !fm.fileExists(atPath: dest.path) {
                try? fm.moveItem(at: backup, to: dest)
            }
            errorMessage = error.localizedDescription
            progressStage = "Failed"
            log("ERROR: \(error.localizedDescription)")
        }

        try? fm.removeItem(at: transactionRoot)
    }

    func remove(_ repository: GitRepository) {
        repositories.removeAll { $0.id == repository.id }
        persist()
    }

    private func upsert(_ repository: GitRepository) {
        repositories.removeAll { $0.owner == repository.owner && $0.name == repository.name }
        repositories.insert(repository, at: 0)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(repositories) {
            UserDefaults.standard.set(data, forKey: repositoriesKey)
        }
    }

    private func log(_ message: String) {
        verboseLog.append(message)
        status = message
    }
}
