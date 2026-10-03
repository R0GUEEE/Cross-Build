import SwiftUI

struct WorkspaceConfigurationView: View {
    @ObservedObject var config: WorkspaceConfiguration
    @EnvironmentObject private var workspace: WorkspaceModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Project Detection") {
                    LabeledContent("Active project", value: activeProjectName)
                    LabeledContent("Toolchain", value: workspace.activeCompiler?.name ?? workspace.selectedToolchain.rawValue)
                    Toggle("Auto-detect toolchain", isOn: $config.autoDetectToolchain)
                    Toggle("Detect nested projects", isOn: $config.detectNestedProjects)
                    Toggle("Prefer nearest manifest", isOn: $config.preferNearestManifest)
                    Toggle("Index source files", isOn: $config.indexSources)
                    TextField("Additional manifest names", text: $config.customManifestNames, axis: .vertical)
                    Button("Detect & Generate Settings", systemImage: "wand.and.stars") { workspace.detectSampleProject() }
                        .buttonStyle(.borderedProminent)
                    if let root = workspace.activeProjectRoot {
                        Text(root).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }

                Section("Build Profile") {
                    Picker("Configuration", selection: $config.buildTarget) {
                        Text("Debug").tag("Debug")
                        Text("Release").tag("Release")
                    }
                    TextField("Working directory override", text: $config.workingDirectory)
                    TextField("SDK / sysroot override", text: $config.sdkPath)
                    TextField("Build arguments", text: $config.buildArguments, axis: .vertical)
                    TextField("Clean arguments", text: $config.cleanArguments, axis: .vertical)
                    TextField("Test arguments", text: $config.testArguments, axis: .vertical)
                    TextField("Package arguments", text: $config.packageArguments, axis: .vertical)
                    TextField("Environment — KEY=VALUE per line", text: $config.environmentVariables, axis: .vertical)
                        .lineLimit(3...10)
                }

                Section("Artifacts") {
                    TextField("Artifact output directory", text: $config.artifactDirectory)
                    Toggle("Keep build artifacts", isOn: $config.keepBuildArtifacts)
                    Toggle("Clean artifact directory before build", isOn: $config.cleanArtifactDirectory)
                }

                Section("Editor & Documents") {
                    Toggle("Workspace autosave", isOn: $config.autosave)
                    Toggle("Restore open tabs", isOn: $config.restoreOpenTabs)
                    Toggle("Confirm closing unsaved files", isOn: $config.confirmCloseDirty)
                    Picker("Default new-file extension", selection: $config.defaultNewFileExtension) {
                        ForEach(["swift","m","mm","c","cpp","h","xm","x","rs","go","zig","py","js","ts"], id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Text encoding", selection: $config.defaultEncoding) {
                        Text("UTF-8").tag("UTF-8")
                        Text("UTF-16").tag("UTF-16")
                    }
                    Picker("Line endings", selection: $config.lineEndings) {
                        Text("LF").tag("LF")
                        Text("CRLF").tag("CRLF")
                    }
                    Stepper("Recent files limit: \(config.maxRecentFiles)", value: $config.maxRecentFiles, in: 5...100, step: 5)
                }

                Section("Loaded Directories") {
                    Toggle("Show app directories", isOn: $config.showAppDirectories)
                    if config.showAppDirectories {
                        Toggle("Show application bundle", isOn: $config.showAppBundle)
                        Toggle("Show app Library", isOn: $config.showContainerLibrary)
                        Toggle("Show temporary files", isOn: $config.showTemporaryFiles)
                    }
                    LabeledContent("Workspace", value: workspace.files.workspaceRoot.path)
                }

                Section("Search & Traversal") {
                    Toggle("Include hidden files", isOn: $config.searchHiddenFiles)
                    Toggle("Case-sensitive search", isOn: $config.searchCaseSensitive)
                    Toggle("Search file contents", isOn: $config.searchFileContents)
                    Toggle("Follow symbolic links", isOn: $config.followSymlinks)
                    TextField("Excluded directory names", text: $config.excludePatterns, axis: .vertical)
                }

                Section("Generated Configuration") {
                    if workspace.generatedConfigurationSummary.isEmpty {
                        Text("No generated project configuration yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(workspace.generatedConfigurationSummary, id: \.self) {
                            Label($0, systemImage: "checkmark.circle")
                        }
                    }
                }

                Section("Workspace Information") {
                    LabeledContent("Project files", value: "\(workspace.projectFiles.count)")
                    LabeledContent("Open editors", value: "\(workspace.editor.documents.count)")
                    LabeledContent("Execution", value: workspace.executionStatus)
                    if let code = workspace.lastExitCode { LabeledContent("Last exit code", value: "\(code)") }
                }
            }
            .navigationTitle("Workspace Configuration")
            .onAppear { workspace.syncFileConfiguration() }
            .onChange(of: config.showAppDirectories) { _ in workspace.syncFileConfiguration() }
            .onChange(of: config.showAppBundle) { _ in workspace.syncFileConfiguration() }
            .onChange(of: config.showContainerLibrary) { _ in workspace.syncFileConfiguration() }
            .onChange(of: config.showTemporaryFiles) { _ in workspace.syncFileConfiguration() }
            .onChange(of: config.searchHiddenFiles) { _ in workspace.syncFileConfiguration() }
            .onChange(of: config.searchCaseSensitive) { _ in workspace.syncFileConfiguration() }
            .onChange(of: config.followSymlinks) { _ in workspace.syncFileConfiguration() }
            .onChange(of: config.excludePatterns) { _ in workspace.syncFileConfiguration() }
            .onChange(of: config.maxRecentFiles) { _ in workspace.syncFileConfiguration() }
        }
    }

    private var activeProjectName: String {
        guard let root = workspace.activeProjectRoot else { return "Not detected" }
        return URL(fileURLWithPath: root).lastPathComponent
    }
}
