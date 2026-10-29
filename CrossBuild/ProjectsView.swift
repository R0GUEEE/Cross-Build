import Foundation
import SwiftUI

/// The project browser: the file tree of the project you are working in.
///
/// The project menu lists the folders this app actually brought in — created here or
/// imported from GitHub — and choosing one points the app at it: the tree is
/// rescoped to that folder, detection runs against it, and the Build tab follows.
struct ProjectsView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings
    /// Switches the app to the build tab.
    var openBuild: () -> Void

    @State private var editing = false
    @State private var showSettings = false
    @State private var showNewProject = false
    @State private var newProjectName = ""
    @State private var showGitHub = false

    private var projectName: String {
        if let root = workspace.activeProjectRoot, !root.isEmpty {
            let name = URL(fileURLWithPath: root).lastPathComponent
            if !name.isEmpty { return name }
        }
        return "Workspace"
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
                                 })
        }
        .background(ForgeTheme.Surface.background)
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
            if let imported = workspace.github.lastImportedPath {
                workspace.registerProject(path: imported)
                workspace.detectProject(at: imported)
                workspace.files.focus(on: URL(fileURLWithPath: imported))
            }
            workspace.files.reload()
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
            Text("A folder is created in the workspace and becomes the active project.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                Section("Projects") {
                    ForEach(workspace.knownProjects) { project in
                        Button {
                            open(project)
                        } label: {
                            if project.path == workspace.activeProjectRoot {
                                Label(project.name, systemImage: "checkmark")
                            } else {
                                Text(project.name)
                            }
                        }
                    }
                    if workspace.knownProjects.isEmpty {
                        Text("No projects yet")
                    }
                }
                Divider()
                Button("New Project", systemImage: "plus") {
                    newProjectName = ""
                    showNewProject = true
                }
                Button("Import from GitHub", systemImage: "arrow.down.circle") { showGitHub = true }
                if workspace.files.focusedRoot != nil {
                    Button("Show Entire Workspace", systemImage: "square.grid.2x2") {
                        workspace.files.focus(on: nil)
                    }
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
            .contextMenu {
                ForEach(workspace.knownProjects) { project in
                    Button("Remove \(project.name)", role: .destructive) {
                        workspace.forgetProject(project)
                    }
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

    /// Points the app at a project: detection, the explorer, and the build tab all
    /// follow from `activeProjectRoot`.
    private func open(_ project: WorkspaceModel.KnownProject) {
        workspace.registerProject(path: project.path, name: project.name)
        workspace.detectProject(at: project.path)
        workspace.files.focus(on: URL(fileURLWithPath: project.path))
    }

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
        workspace.registerProject(path: url.path, name: name)
        workspace.detectProject(at: url.path)
        workspace.files.focus(on: url)
    }
}
