import SwiftUI
import UIKit

struct IDEView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showCompilerManager = false
    @State private var showGitHub = false
    @State private var showWorkspaceConfiguration = false
    @State private var bottomPanel: ForgePanel = .terminal
    @State private var bottomExpanded = true
    @State private var pendingCloseDocument: EditorDocument?

    var body: some View {
        NavigationSplitView {
            navigator
                .navigationTitle("Cross Build")
        } detail: {
            editorWorkspace
        }
        .sheet(isPresented: $showCompilerManager) {
            CompilerManagerView().environmentObject(workspace)
        }
        .sheet(isPresented: $showGitHub, onDismiss: {
            workspace.files.reload()
            if let importedPath = workspace.github.lastImportedPath {
                workspace.detectProject(at: importedPath)
            }
        }) {
            GitHubCloneView(github: workspace.github)
        }
        .sheet(isPresented: $showWorkspaceConfiguration) {
            WorkspaceConfigurationView(config: workspace.configuration).environmentObject(workspace)
        }
        .alert(item: $pendingCloseDocument) { doc in
            Alert(
                title: Text("Discard unsaved changes?"),
                message: Text("\(doc.name) has changes that have not been saved."),
                primaryButton: .destructive(Text("Discard")) { workspace.closeDocument(doc.id) },
                secondaryButton: .cancel()
            )
        }
    }

    private var navigator: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment:.leading,spacing:2) {
                    Text("Project").font(.headline)
                    Text("\(workspace.projectFiles.count) files").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { openGitHubImporter() } label: { Image(systemName:"arrow.down.circle") }.buttonStyle(.plain)
                Button { workspace.files.reload() } label: { Image(systemName:"arrow.clockwise") }.buttonStyle(.plain)
                Menu {
                    Section("Project") {
                        Button("Refresh All Directories", systemImage: "arrow.clockwise") { workspace.files.reload() }
                        Button("Show App Files & Folders", systemImage: "square.stack.3d.up") { workspace.files.revealAllAppDirectories() }
                        Button("Workspace Only", systemImage: "folder") { workspace.files.revealWorkspaceOnly() }
                        Button("Save Current File", systemImage: "square.and.arrow.down", action: workspace.saveEditor)
                        Button("Detect Project & Compiler", systemImage: "waveform.badge.magnifyingglass", action: workspace.detectSampleProject)
                    }
                    Section("Source Control") {
                        Button("Clone from GitHub", systemImage: "arrow.down.circle") { openGitHubImporter() }
                    }
                    Section("File Operations") {
                        Button("New File", systemImage: "doc.badge.plus") { workspace.files.createFile(named: "Untitled.swift") }
                        Button("New Folder", systemImage: "folder.badge.plus") { workspace.files.createFolder(named: "New Folder") }
                        if let selected = workspace.files.selected {
                            Button("Duplicate Selected", systemImage: "plus.square.on.square") { workspace.files.duplicate(selected) }
                            Button("Copy Selected Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = selected.path }
                        }
                    }
                    Section("Tools") {
                        Button("Manage Compilers", systemImage: "cpu") { showCompilerManager = true }
                        Button("Workspace Configuration", systemImage: "slider.horizontal.3") { showWorkspaceConfiguration = true }
                        Button("Toggle Bottom Panel", systemImage: "rectangle.bottomthird.inset.filled") { bottomExpanded.toggle() }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }.padding(10)

            Divider()
            WorkspaceBrowserView(files: workspace.files, onDelete: workspace.deleteFile)
                .onChange(of: workspace.files.selected) { _ in workspace.openSelectedFile() }
        }
    }

    private var editorWorkspace: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            tabBar
            Divider()
            detectionBar
            if workspace.editor.showFind {
                HStack {
                    TextField("Find", text: Binding(get: { workspace.editor.findText }, set: { workspace.editor.findText = $0 })).textFieldStyle(.roundedBorder)
                    TextField("Replace", text: Binding(get: { workspace.editor.replaceText }, set: { workspace.editor.replaceText = $0 })).textFieldStyle(.roundedBorder)
                    Button("Replace All") { workspace.editor.replaceAll(); if let doc = workspace.editor.selected { workspace.updateEditorText(doc.text) } }
                    Button { workspace.editor.showFind = false } label: { Image(systemName: "xmark") }
                }.padding(8).background(.secondary.opacity(0.04))
            }
            if workspace.editor.documents.isEmpty {
                WorkspaceHomeView(clone: { openGitHubImporter() }, configure: { showWorkspaceConfiguration = true }).environmentObject(workspace)
            } else {
                editor
            }
            Divider()
            if bottomExpanded {
                BottomWorkbenchView(panel: $bottomPanel)
                    .environmentObject(workspace)
                    .frame(height: sizeClass == .compact ? 210 : 260)
            } else {
                collapsedPanelBar
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.editor.selected?.name ?? "Workspace").font(.headline)
                Text(workspace.editor.selected == nil ? "Cross Build" : workspace.selectedToolchain.rawValue).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Picker("Toolchain", selection: $workspace.selectedToolchain) {
                    ForEach(ToolchainKind.allCases) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Button("Manage Compilers", systemImage: "slider.horizontal.3") { showCompilerManager = true }
                Button("Auto Detect", systemImage: "sparkle.magnifyingglass", action: workspace.detectSampleProject)
            } label: {
                IDEStatusPill(icon: "cpu", text: workspace.activeCompiler?.name ?? workspace.selectedToolchain.rawValue)
            }
            if workspace.editor.selected != nil {
                Button { workspace.editor.showFind.toggle() } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.bordered)
                Button(action: workspace.saveEditor) { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.bordered)
            }
            Button(action: { workspace.runBuild(settings: settings) }) {
                if workspace.isExecuting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Build", systemImage: "play.fill").font(.subheadline.weight(.semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(workspace.isExecuting)
        }.padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(workspace.editor.documents) { doc in
                    HStack(spacing: 5) {
                        Button {
                            workspace.selectDocument(doc.id)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                Text(doc.name)
                                if doc.isDirty { Circle().frame(width: 6, height: 6) }
                            }
                        }
                        .buttonStyle(.plain)

                        Button {
                            requestClose(doc)
                        } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close \(doc.name)")
                    }
                    .font(.caption)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: ForgeTheme.compactCorner)
                            .fill(workspace.editor.selectedID == doc.id ? Color.secondary.opacity(0.12) : Color.clear)
                    )
                }
                Button {
                    if let file = workspace.files.createFile(named: "Untitled.swift") {
                        workspace.files.open(file)
                        workspace.openSelectedFile()
                    }
                } label: {
                    Image(systemName: "plus").padding(8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New file")
            }.padding(.horizontal, 8).padding(.vertical, 5)
        }
        .background(.secondary.opacity(0.04))
    }

    private func requestClose(_ doc: EditorDocument) {
        if doc.isDirty && workspace.configuration.confirmCloseDirty {
            pendingCloseDocument = doc
        } else {
            workspace.closeDocument(doc.id)
        }
    }

    private func editorTab(_ title: String, icon: String, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title)
            if selected { Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.secondary) }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: ForgeTheme.compactCorner)
                .fill(selected ? Color.secondary.opacity(0.12) : Color.clear)
        )
    }

    @ViewBuilder private var detectionBar: some View {
        if let analysis = workspace.analysis {
            HStack(spacing: 8) {
                IDEStatusPill(icon: "cpu", text: analysis.primaryToolchain.rawValue)
                IDEStatusPill(icon: "chart.bar.fill", text: "\(Int(analysis.confidence * 100))%")
                if let type = analysis.theosType { IDEStatusPill(icon: "wrench.and.screwdriver", text: type.rawValue) }
                Spacer()
                if let candidate = analysis.candidates.first {
                    Text(candidate.command).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 10).padding(.vertical, 6).background(.secondary.opacity(0.04))
        }
    }

    private var editor: some View {
        TextEditor(text: Binding(get: { workspace.editorText }, set: { workspace.updateEditorText($0) }))
            .font(.system(size: settings.editorFontSize, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openGitHubImporter() {
        workspace.github.lastImportedPath = nil
        showGitHub = true
    }

    private var collapsedPanelBar: some View {
        HStack {
            ForEach(ForgePanel.allCases) { item in
                Button {
                    bottomPanel = item; bottomExpanded = true
                } label: { Label(item.rawValue, systemImage: item.icon).font(.caption) }
                .buttonStyle(.plain)
            }
            Spacer()
            Button { bottomExpanded = true } label: { Image(systemName: "chevron.up") }
        }.padding(8)
    }
}
