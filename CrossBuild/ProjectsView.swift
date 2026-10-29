import Foundation
import SwiftUI

/// The app's home screen.
///
/// It answers one question -- "what am I working on?" -- and offers the three ways
/// to answer it: a project in the workspace, a repository from GitHub, or a new
/// folder. Everything that used to compete with that question (toolchain metrics,
/// detection confidence, execution status, four action tiles) is either here only
/// when it is true (a project's language) or gone.
struct ProjectsView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings
    /// Switches the app to the editor tab.
    var openEditor: () -> Void

    @State private var projects: [ProjectEntry] = []
    @State private var isLoading = true
    @State private var showGitHub = false
    @State private var showFiles = false
    @State private var showNewProject = false
    @State private var newProjectName = ""

    struct ProjectEntry: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let path: String
        let manifest: String?
        let modified: Date

        var subtitle: String {
            if let manifest { return manifest }
            return "No build file yet"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                primaryActions
                currentProjectCard
                projectList
                if !workspace.files.recent.isEmpty { recentFiles }
            }
            .padding(18)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(ForgeTheme.Surface.background)
        .task { await reload() }
        .refreshable { await reload() }
        .onChange(of: workspace.files.roots.count) { _ in Task { await reload() } }
        .sheet(isPresented: $showGitHub, onDismiss: {
            workspace.files.reload()
            if let imported = workspace.github.lastImportedPath {
                workspace.detectProject(at: imported)
                openEditor()
            }
            Task { await reload() }
        }) {
            GitHubCloneView(github: workspace.github)
        }
        .sheet(isPresented: $showFiles) {
            NavigationStack {
                WorkspaceBrowserView(files: workspace.files,
                                     onDelete: workspace.deleteFile,
                                     onRename: workspace.renameFile,
                                     confirmDeletes: settings.confirmDestructiveActions,
                                     onOpen: { file in
                                         workspace.openFile(file)
                                         showFiles = false
                                         openEditor()
                                     },
                                     onSetActiveProject: { folder in
                                         workspace.useFolderAsActiveProject(folder)
                                         showFiles = false
                                         openEditor()
                                     })
                    .navigationTitle("Browse Files")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showFiles = false } } }
            }
        }
        .alert("New Project", isPresented: $showNewProject) {
            TextField("Folder name", text: $newProjectName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Create") { createProject() }
            Button("Cancel", role: .cancel) { newProjectName = "" }
        } message: {
            Text("A folder is created in the workspace. Add files to it and open it from the list.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cross Build").font(.largeTitle.bold())
            Text("Build C, C++ and Theos projects on device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var primaryActions: some View {
        HStack(spacing: 10) {
            action("New", icon: "plus", prominent: true) {
                newProjectName = ""
                showNewProject = true
            }
            action("Import", icon: "arrow.down.circle") { showGitHub = true }
            action("Browse", icon: "folder") { showFiles = true }
            Spacer(minLength: 0)
        }
    }

    private func action(_ title: String, icon: String, prominent: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(prominent ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
        }
        .buttonStyle(prominent ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
    }

    /// What the app is currently pointed at, with the one action that matters.
    @ViewBuilder private var currentProjectCard: some View {
        if let root = workspace.activeProjectRoot, !root.isEmpty {
            currentProjectBody(root: root)
        }
    }

    private func currentProjectBody(root: String) -> some View {
        let name = URL(fileURLWithPath: root).lastPathComponent
        let files = workspace.projectFiles.count
        let language = workspace.analysis?.primaryToolchain.rawValue ?? workspace.selectedToolchain.rawValue
        let build = workspace.buildCommand()
        return ForgeCard("Current Project", subtitle: "\(language) • \(files) file\(files == 1 ? "" : "s")") {
            VStack(alignment: .leading, spacing: 10) {
                Text(name).font(.title3.weight(.semibold))
                Text(build)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Button {
                        openEditor()
                    } label: {
                        Label("Open", systemImage: "chevron.right").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AnyButtonStyle(.borderedProminent))

                    Button {
                        openEditor()
                        workspace.runBuild(settings: settings)
                    } label: {
                        Label("Build", systemImage: "hammer.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AnyButtonStyle(.bordered))
                    .disabled(workspace.isExecuting)
                }
            }
        }
    }

    private var projectList: some View {
        ForgeCard("Projects", subtitle: isLoading ? "Looking…" : "\(projects.count) in this workspace") {
            if projects.isEmpty {
                Text(isLoading ? "Loading…" : "No projects yet. Create one, or import a repository.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(projects) { project in
                        Button { open(project) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.tint)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text(project.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if workspace.activeProjectRoot == project.path {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if project.id != projects.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var recentFiles: some View {
        ForgeCard("Recent Files", subtitle: "Continue where you left off") {
            VStack(spacing: 0) {
                ForEach(workspace.files.recent.prefix(5)) { file in
                    Button {
                        workspace.files.open(file)
                        workspace.openSelectedFile()
                        openEditor()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: WorkspaceFileIcon.symbol(for: file.name)).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name).font(.subheadline).lineLimit(1)
                                Text(URL(fileURLWithPath: file.path).deletingLastPathComponent().lastPathComponent)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if file.id != workspace.files.recent.prefix(5).last?.id { Divider() }
                }
            }
        }
    }

    // MARK: - Actions

    private func open(_ project: ProjectEntry) {
        workspace.detectProject(at: project.path)
        openEditor()
    }

    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        newProjectName = ""
        guard !name.isEmpty,
              !name.contains("/"),
              !name.hasPrefix("."),
              name != ".." else { return }
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
        openEditor()
    }

    private func reload() async {
        let root = workspace.files.workspaceRoot.path
        let manifests: Set<String> = ["project.yml", "Package.swift", "Cargo.toml", "go.mod",
                                      "build.zig", "CMakeLists.txt", "meson.build", "Makefile",
                                      "makefile", "GNUmakefile", "package.json", "pyproject.toml",
                                      "controls", "control"]
        let entries = await Task.detached(priority: .utility) { () -> [ProjectEntry] in
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
            guard let children = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root, isDirectory: true),
                                                             includingPropertiesForKeys: keys,
                                                             options: [.skipsHiddenFiles]) else { return [] }
            var result: [ProjectEntry] = []
            for url in children {
                guard (try? url.resourceValues(forKeys: Set(keys)).isDirectory) == true else { continue }
                let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
                let manifest = names.first { manifests.contains($0) }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                result.append(ProjectEntry(id: url.path,
                                           name: url.lastPathComponent,
                                           path: url.path,
                                           manifest: manifest,
                                           modified: modified))
            }
            return result.sorted {
                $0.modified == $1.modified ? $0.name < $1.name : $0.modified > $1.modified
            }
        }.value
        projects = entries
        isLoading = false
    }
}
