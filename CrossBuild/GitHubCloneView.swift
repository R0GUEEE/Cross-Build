import SwiftUI

struct GitHubCloneView: View {
    @ObservedObject var github: GitHubWorkspaceService
    @Environment(\.dismiss) private var dismiss
    @State private var repositoryURL = ""
    @State private var branch = ""
    @State private var shallow = true
    @State private var mode: GitCloneMode = .automatic

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Clone from GitHub", systemImage: "arrow.down.circle.fill").font(.title2.bold())
                    Text("Import a repository into Cross Build's private Projects directory and open it as a workspace.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Repository") {
                    TextField("https://github.com/owner/repository", text: $repositoryURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Branch (optional)", text: $branch)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Method", selection: $mode) {
                        ForEach(GitCloneMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Shallow clone", isOn: $shallow)
                }
                Section("Storage") {
                    LabeledContent("Location", value: "Documents/Projects")
                    Text(github.projectsDirectory.path).font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
                Section("Clone Strategy") {
                    Label("Git Clone", systemImage: "terminal")
                    Text("Uses a local Git executable when the active runtime supports process execution.")
                        .font(.caption).foregroundStyle(.secondary)
                    Label("Archive Import", systemImage: "archivebox")
                    Text("Provides the sideload-compatible path: download a GitHub source archive and extract it into app storage.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Progress") {
                    ProgressView(value: github.progress) {
                        HStack { Text(github.progressStage); Spacer(); Text("\(Int(github.progress * 100))%").monospacedDigit() }
                    }
                    if !github.status.isEmpty { Text(github.status).font(.caption) }
                    if !github.verboseLog.isEmpty {
                        ScrollView {
                            Text(github.verboseLog.joined(separator: "\n"))
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }.frame(maxHeight: 160)
                    }
                }
                if let error = github.errorMessage { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button(github.isImporting ? "Cloning…" : "Clone Repository", systemImage: "arrow.down.to.line") { clone() }
                        .buttonStyle(.borderedProminent)
                        .disabled(repositoryURL.trimmingCharacters(in: .whitespaces).isEmpty || github.isImporting)
                }
                if !github.repositories.isEmpty {
                    Section("Recent Repositories") {
                        ForEach(github.repositories) { repo in
                            VStack(alignment: .leading) {
                                Text("\(repo.owner)/\(repo.name)").font(.headline)
                                Text(repo.localPath).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("GitHub")
        }
    }

    private func clone() {
        Task {
            switch mode {
            case .archive, .automatic:
                await github.cloneArchive(url: repositoryURL, branch: branch)
            case .git:
                do {
                    let repo = try github.registerImportedRepository(url: repositoryURL, branch: branch)
                    github.errorMessage = "Local git execution is not available through the sideload backend yet. Use Archive Import; destination: \(repo.localPath)"
                } catch {
                    github.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
