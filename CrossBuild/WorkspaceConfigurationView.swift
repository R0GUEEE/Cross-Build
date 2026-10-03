import SwiftUI

struct WorkspaceConfigurationView: View {
    @ObservedObject var config: WorkspaceConfiguration
    @EnvironmentObject private var workspace: WorkspaceModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Automatic Project Setup") {
                    LabeledContent("Project", value: activeProjectName)
                    LabeledContent("Toolchain", value: workspace.activeCompiler?.name ?? workspace.selectedToolchain.rawValue)
                    if let root = workspace.activeProjectRoot {
                        Text(root)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Button("Detect & Generate Settings", systemImage: "wand.and.stars") {
                        workspace.detectSampleProject()
                    }
                    .buttonStyle(.borderedProminent)

                    if !workspace.generatedConfigurationSummary.isEmpty {
                        ForEach(workspace.generatedConfigurationSummary, id: \.self) { item in
                            Label(item, systemImage: "checkmark.circle")
                                .font(.caption)
                        }
                    }
                }

                Section("Build Overrides") {
                    Picker("Configuration", selection: $config.buildTarget) {
                        Text("Debug").tag("Debug")
                        Text("Release").tag("Release")
                    }
                    TextField("Working directory", text: $config.workingDirectory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("SDK / sysroot path (optional)", text: $config.sdkPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Additional build arguments", text: $config.buildArguments, axis: .vertical)
                    TextField("Environment (KEY=VALUE, one per line)", text: $config.environmentVariables, axis: .vertical)
                        .lineLimit(2...8)
                    Text("Leave overrides empty to use automatically generated project settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Editor & Documents") {
                    Toggle("Workspace autosave", isOn: $config.autosave)
                    Toggle("Restore open tabs", isOn: $config.restoreOpenTabs)
                    Toggle("Confirm closing unsaved files", isOn: $config.confirmCloseDirty)
                    Picker("Text encoding", selection: $config.defaultEncoding) {
                        Text("UTF-8").tag("UTF-8")
                        Text("UTF-16").tag("UTF-16")
                    }
                    Picker("Line endings", selection: $config.lineEndings) {
                        Text("LF").tag("LF")
                        Text("CRLF").tag("CRLF")
                    }
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

                Section("File Discovery") {
                    Toggle("Include hidden files", isOn: $config.searchHiddenFiles)
                    Toggle("Case-sensitive search", isOn: $config.searchCaseSensitive)
                    Toggle("Follow symbolic links", isOn: $config.followSymlinks)
                    TextField("Excluded directory names", text: $config.excludePatterns, axis: .vertical)
                    Text("Separate exclusions with commas. Core exclusions such as .git, DerivedData, .build and node_modules remain protected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Workspace Information") {
                    LabeledContent("Project files", value: "\(workspace.projectFiles.count)")
                    LabeledContent("Open editors", value: "\(workspace.editor.documents.count)")
                    LabeledContent("Execution", value: workspace.executionStatus)
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
        }
    }

    private var activeProjectName: String {
        guard let root = workspace.activeProjectRoot else { return "Not detected" }
        return URL(fileURLWithPath: root).lastPathComponent
    }
}
