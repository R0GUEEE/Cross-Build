import SwiftUI

struct WorkspaceConfigurationView: View {
    @ObservedObject var config: WorkspaceConfiguration
    @EnvironmentObject private var workspace: WorkspaceModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Project name", text: $config.projectName)
                    TextField("Working directory", text: $config.workingDirectory)
                    Toggle("Index source files", isOn: $config.indexSources)
                    Toggle("Autosave", isOn: $config.autosave)
                }
                Section("Build") {
                    Picker("Configuration", selection: $config.buildTarget) {
                        Text("Debug").tag("Debug"); Text("Release").tag("Release")
                    }
                    TextField("Deployment target", text: $config.deploymentTarget)
                    TextField("Architecture", text: $config.architecture)
                    TextField("SDK / sysroot path", text: $config.sdkPath)
                    TextField("Build arguments", text: $config.buildArguments)
                    TextField("Environment (KEY=VALUE)", text: $config.environmentVariables, axis: .vertical)
                }
                Section("Compiler") {
                    Toggle("Auto-detect toolchain", isOn: $config.autoDetectToolchain)
                    TextField("Toolchain override", text: $config.compilerOverride)
                    LabeledContent("Current", value: workspace.activeCompiler?.name ?? workspace.selectedToolchain.rawValue)
                    Button("Run Detection", systemImage: "sparkle.magnifyingglass", action: workspace.detectSampleProject)
                }
                Section("Git") {
                    TextField("Default branch", text: $config.gitDefaultBranch)
                    Toggle("Shallow clone", isOn: $config.gitShallowClone)
                    Toggle("Clone submodules", isOn: $config.gitSubmodules)
                }
                Section("Workspace Information") {
                    LabeledContent("Files", value: "\(workspace.files.flattened.filter { !$0.isDirectory }.count)")
                    LabeledContent("Projects storage", value: "Documents/Projects")
                }
            }.navigationTitle("Workspace Configuration")
        }
    }
}
