import Foundation
import SwiftUI

/// The project browser: the file tree of the workspace you are working in.
///
/// This used to be a list of project folders with a separate "editor" tab; opening
/// a file moved the whole app. Now the tree is the screen, tapping a file opens it
/// in a popup, and the project you are in is a menu in the header rather than a
/// destination.
struct ProjectsView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings
    /// Switches the app to the build tab.
    var openBuild: () -> Void

    @State private var projects: [ProjectEntry] = []
    @State private var editing = false
    @State private var showSettings = false
    @State private var showNewProject = false
    @State private var newProjectName = ""
    @State private var showGitHub = false

    struct ProjectEntry: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let path: String
        let manifest: String?
    }

    private var projectName: String {
        guard let root = workspace.activeProjectRoot, !root.isEmpty else { return "Workspace" }
        let name = URL(fileURLWithPath: root).lastPathComponent
        return name.isEmpty ? "Workspace" : name
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            WorkspaceBrowserView(files: workspace.files,
                                 onDelete: workspace.deleteFile,
                                 onRename: workspace.renameFile,
                                 confirmDeletes: settings.confirmDestructiveActions,
                                 onOpen: open,
                                 onSetActiveProject: { folder in
                                     workspace.useFolderAsActiveProject(folder)
                                     Task { await reload() }
                                 })
        }
        .background(ForgeTheme.Surface.background)
        .task { await reload() }
        .onChange(of: workspace.files.roots.count) { _ in Task { await reload() } }
        .sheet(isPresented: $editing) {
            EditorSheet(settings: settings).environmentObject(workspace)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                WorkspaceConfigurationView(config: workspace.configuration)
                    .environmentObject(workspace)
                    .navigationTitle("Project")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showGitHub, onDismiss: {
            workspace.files.reload()
            if let imported = workspace.github.lastImportedPath {
                workspace.detectProject(at: imported)
            }
            Task { await reload() }
        }) {
            GitHubCloneView(github: workspace.github)
        }
        .alert("New Project", isPresented: $showNewProject) {
            TextField("Folder name", text: $newProjectName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Create") { createProject() }
            Button("Cancel", role: .cancel) { newProjectName = "" }
        } message: {
            Text("A folder is created in the workspace. Add files to it from the file list.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                Section("Projects") {
                    ForEach(projects) { project in
                        Button {
                            workspace.detectProject(at: project.path)
                        } label: {
                            if project.path == workspace.activeProjectRoot {
                                Label(project.name, systemImage: "checkmark")
                            } else {
                                Text(project.name)
                            }
                        }
                    }
                    if projects.isEmpty {
                        Text("No projects yet")
                    }
                }
                Divider()
                Button("New Project", systemImage: "plus") {
                    newProjectName = ""
                    showNewProject = true
                }
                Button("Import from GitHub", systemImage: "arrow.down.circle") { showGitHub = true }
                Button("Use Workspace Root", systemImage: "folder") {
                    workspace.detectProject(at: workspace.files.workspaceRoot.path)
                }
            } label: {
                HStack(spacing: 5) {
                    Text(projectName)
                        .font(.headline)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                openBuild()
            } label: {
                Label("Build", systemImage: "hammer.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Project settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Actions

    private func open(_ file: WorkspaceFile) {
        guard !file.isDirectory else { return }
        workspace.openFile(file)
        guard workspace.editor.selected != nil else { return }
        editing = true
    }

    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        newProjectName = ""
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."), name != ".." else { return }
        var url = workspace.files.workspaceRoot.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) {
            url = workspace.files.uniqueURL(url)
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            workspace.console += "error: could not create \(name): \(error.localizedDescription)\n"
            return
        }
        workspace.files.reload()
        workspace.detectProject(at: url.path)
        Task { await reload() }
    }

    private func reload() async {
        let root = workspace.files.workspaceRoot.path
        let manifests: Set<String> = ["project.yml", "Package.swift", "Cargo.toml", "go.mod",
                                      "build.zig", "CMakeLists.txt", "meson.build", "Makefile",
                                      "makefile", "GNUmakefile", "package.json", "pyproject.toml",
                                      "controls", "control"]
        let entries = await Task.detached(priority: .utility) { () -> [ProjectEntry] in
            let fm = FileManager.default
            guard let children = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root, isDirectory: true),
                                                             includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: [.skipsHiddenFiles]) else { return [] }
            var result: [ProjectEntry] = []
            for url in children {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
                let manifest = names.first { manifests.contains($0) }
                result.append(ProjectEntry(id: url.path,
                                           name: url.lastPathComponent,
                                           path: url.path,
                                           manifest: manifest))
            }
            return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }.value
        projects = entries
    }
}
