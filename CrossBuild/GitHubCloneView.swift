import SwiftUI

struct GitHubCloneView: View {
    @ObservedObject var github: GitHubWorkspaceService
    @Environment(\.dismiss) private var dismiss
    @State private var repositoryURL = ""
    @State private var branch = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Import from GitHub", systemImage: "arrow.down.circle.fill")
                        .font(.title2.bold())
                    Text("Import a GitHub repository safely into Documents/Workspace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Repository") {
                    TextField("https://github.com/owner/repository", text: $repositoryURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Branch (optional)", text: $branch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Storage") {
                    LabeledContent("Location", value: "Documents/Workspace")
                    Text(github.projectsDirectory.path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Section("Import Method") {
                    Label("Transactional Archive Import", systemImage: "archivebox")
                    Text("Downloads GitHub's source archive, validates it, and only replaces an existing tracked copy after extraction succeeds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Progress") {
                    ProgressView(value: github.progress) {
                        HStack {
                            Text(github.progressStage)
                            Spacer()
                            Text("\(Int(github.progress * 100))%").monospacedDigit()
                        }
                    }
                    if !github.status.isEmpty {
                        Text(github.status).font(.caption)
                    }
                    if !github.verboseLog.isEmpty {
                        ScrollView {
                            Text(github.verboseLog.joined(separator: "\n"))
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 160)
                    }
                }

                if let error = github.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(github.isImporting ? "Importing…" : "Import Repository",
                           systemImage: "arrow.down.to.line") {
                        clone()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || github.isImporting)

                    if github.progressStage == "Complete" {
                        Button("Done") { dismiss() }
                    }
                }

                if !github.repositories.isEmpty {
                    Section("Recent Repositories") {
                        ForEach(github.repositories) { repo in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(repo.owner)/\(repo.name)").font(.headline)
                                Text(repo.localPath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
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
            await github.cloneArchive(url: repositoryURL, branch: branch)
        }
    }
}
