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
                    LabeledContent("Word wrap", value: "System editor")
                    Text("Code folding, minimap and whitespace visualization are hidden until the advanced editor engine is available.")
                        .font(.caption).foregroundStyle(.secondary)
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
                    Toggle("Clear previous output before build",isOn:$settings.clearDiagnosticsOnBuild)
                    Text("Live parsed diagnostics will become available with the compiler diagnostic engine.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Agent") {
                    LabeledContent("Engine", value: "Local project planner")
                    Toggle("Allow source edits",isOn:$settings.allowAgentEdits)
                    Toggle("Allow compiler/build control",isOn:$settings.allowAgentBuilds)
                    Toggle("Allow dependency changes",isOn:$settings.allowAgentDependencies)
                    Toggle("Confirm command execution",isOn:$settings.confirmAgentCommands)
                    Text("Remote model/provider settings are not presented as active until an LLM transport is connected.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Git & Source Control") {
                    NavigationLink("Workspace Git Defaults") { WorkspaceConfigurationView(config:workspace.configuration).environmentObject(workspace) }
                    Text("Sideload mode uses transactional GitHub archive import. Native Git operations remain disabled until a process backend is connected.")
                        .font(.caption).foregroundStyle(.secondary)
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
                Section("Cross Build") {
                    LabeledContent("Target",value:"iOS 16+")
                    LabeledContent("Architecture",value:workspace.compilerConfiguration.architectures)
                    Text("Portable compiler workbench with integrated projects, toolchains, source control and agent automation.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .onChange(of: settings.showHiddenFiles) { _ in workspace.syncFileConfiguration() }
        }
    }
}
