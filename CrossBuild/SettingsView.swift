import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        NavigationStack {
            Form {
                Section("Editor") {
                    HStack { Text("Font Size"); Slider(value:$settings.editorFontSize,in:11...24,step:1); Text("\(Int(settings.editorFontSize))").monospacedDigit() }
                    Stepper("Tab width: \(settings.tabWidth)", value:$settings.tabWidth,in:2...8)
                    Toggle("Line numbers",isOn:$settings.showLineNumbers)
                    Toggle("Word wrap",isOn:$settings.wordWrap)
                    Toggle("Code folding",isOn:$settings.codeFolding)
                    Toggle("Minimap",isOn:$settings.showMinimap)
                    Toggle("Show whitespace",isOn:$settings.showWhitespace)
                    Toggle("Autosave",isOn:$settings.autosave)
                    Toggle("Trim trailing whitespace",isOn:$settings.trimWhitespace)
                }
                Section("Build") {
                    Toggle("Auto-detect compiler on open",isOn:$settings.autoDetect)
                    Toggle("Parallel builds",isOn:$settings.parallelBuilds)
                    Stepper("Build jobs: \(settings.buildJobs)",value:$settings.buildJobs,in:1...16)
                    Toggle("Clean before build",isOn:$settings.cleanBeforeBuild)
                    Toggle("Verbose build output",isOn:$settings.verboseBuild)
                    Toggle("Warnings as errors",isOn:$settings.warningsAsErrors)
                    NavigationLink("SDK, Linker, Packaging & Signing") { CompilerConfigurationView(config:workspace.compilerConfiguration) }
                }
                Section("Diagnostics") {
                    Toggle("Live diagnostics",isOn:$settings.liveDiagnostics)
                    Toggle("Clear diagnostics before build",isOn:$settings.clearDiagnosticsOnBuild)
                }
                Section("AI Agent") {
                    LabeledContent("Provider",value:settings.agentProvider)
                    LabeledContent("Model",value:settings.agentModel.isEmpty ? "Not configured" : settings.agentModel)
                    Toggle("Allow source edits",isOn:$settings.allowAgentEdits)
                    Toggle("Allow compiler/build control",isOn:$settings.allowAgentBuilds)
                    Toggle("Allow dependency changes",isOn:$settings.allowAgentDependencies)
                    Toggle("Confirm command execution",isOn:$settings.confirmAgentCommands)
                }
                Section("Git & Source Control") {
                    Toggle("Fetch on project open",isOn:$settings.gitFetchOnOpen)
                    Toggle("Confirm destructive Git operations",isOn:$settings.confirmDestructiveGit)
                    NavigationLink("Workspace Git Defaults") { WorkspaceConfigurationView(config:workspace.configuration).environmentObject(workspace) }
                }
                Section("Execution Runtime") {
                    Picker("Backend",selection:$settings.executionBackend) {
                        Text("Automatic").tag("Automatic"); Text("Sideload / Embedded").tag("Sideload / Embedded"); Text("Jailbreak Local").tag("Jailbreak Local"); Text("Remote / SSH").tag("Remote / SSH")
                    }
                    if settings.executionBackend == "Remote / SSH" {
                        TextField("Remote host",text:$settings.remoteHost).textInputAutocapitalization(.never)
                        Stepper("SSH port: \(settings.remotePort)",value:$settings.remotePort,in:1...65535)
                    }
                }
                Section("Files & Storage") {
                    Toggle("Show hidden files",isOn:$settings.showHiddenFiles)
                    LabeledContent("Workspace",value:workspace.files.workspaceRoot.lastPathComponent)
                    LabeledContent("Projects",value:workspace.github.projectsDirectory.lastPathComponent)
                }
                Section("Appearance") { Toggle("Compact interface",isOn:$settings.compactUI) }
                Section("Cross Build") {
                    LabeledContent("Target",value:"iOS 16+")
                    LabeledContent("Architecture",value:workspace.compilerConfiguration.architectures)
                    Text("Portable compiler workbench with integrated projects, toolchains, source control and agent automation.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Settings")
        }
    }
}
