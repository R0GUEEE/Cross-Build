import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        NavigationStack {
            Form {
                Section("Configuration") {
                    NavigationLink("Full Setup") {
                        FullSetupView(settings: settings).environmentObject(workspace)
                    }
                    NavigationLink("Bundled with the app") {
                        BundledResourcesView().environmentObject(workspace)
                    }
                    NavigationLink("App Configuration") {
                        AppConfigurationView(settings: settings)
                    }
                    NavigationLink("Agent Configuration") {
                        AgentConfigurationView(settings: settings)
                    }
                    NavigationLink("Workspace & Project") {
                        WorkspaceConfigurationView(config: workspace.configuration).environmentObject(workspace)
                    }
                    NavigationLink("Compiler, SDK & Toolchain") {
                        CompilerConfigurationView(config: workspace.compilerConfiguration).environmentObject(workspace)
                    }
                    NavigationLink("Feature Diagnostics") {
                        FeatureDiagnosticsView(settings: settings).environmentObject(workspace)
                    }
                }

                Section("Editor") {
                    HStack {
                        Text("Font Size")
                        Slider(value: $settings.editorFontSize, in: 11...24, step: 1)
                        Text("\(Int(settings.editorFontSize))").monospacedDigit()
                    }
                    Toggle("Global autosave", isOn: $settings.autosave)
                    Toggle("Trim trailing whitespace", isOn: $settings.trimWhitespace)
                    Toggle("Line numbers", isOn: $settings.editorLineNumbers)
                    Toggle("Highlight current line", isOn: $settings.editorHighlightCurrentLine)
                    Toggle("Word wrap", isOn: $settings.editorWordWrap)
                    Toggle("Auto-close brackets & quotes", isOn: $settings.editorAutoClosePairs)
                    Toggle("Show invisible characters", isOn: $settings.editorShowInvisibles)
                    Toggle("Insert spaces for tabs", isOn: $settings.editorInsertSpaces)
                    Picker("Tab width", selection: $settings.editorTabWidth) {
                        Text("2").tag(2)
                        Text("4").tag(4)
                        Text("8").tag(8)
                    }
                    LabeledContent("Editor engine", value: "Cross Build Code Editor")
                }

                Section("Build Policy") {
                    Toggle("Auto-detect project on launch", isOn: $settings.autoDetect)
                    Toggle("Parallel builds", isOn: $settings.parallelBuilds)
                    if settings.parallelBuilds {
                        Stepper("Build jobs: \(settings.buildJobs)", value: $settings.buildJobs, in: 1...32)
                    }
                    Toggle("Clean before build", isOn: $settings.cleanBeforeBuild)
                    Toggle("Verbose build output", isOn: $settings.verboseBuild)
                    Toggle("Warnings as errors", isOn: $settings.warningsAsErrors)
                    Toggle("Stop workflow on first failure", isOn: $settings.stopOnFirstError)
                    Toggle("Capture execution environment", isOn: $settings.captureEnvironment)
                    Toggle("Timestamp build output", isOn: $settings.timestampBuildOutput)
                    Stepper(settings.buildTimeout == 0 ? "Build timeout: Unlimited" : "Build timeout: \(settings.buildTimeout)s",
                            value: $settings.buildTimeout, in: 0...3600, step: 30)
                }

                Section("Diagnostics") {
                    Toggle("Clear previous output before build", isOn: $settings.clearDiagnosticsOnBuild)
                    Toggle("Include warnings", isOn: $settings.includeWarnings)
                    Toggle("Include notes", isOn: $settings.includeNotes)
                    Stepper("Maximum problems: \(settings.maxProblems)", value: $settings.maxProblems, in: 25...1000, step: 25)
                }

                Section("Files & Storage") {
                    Toggle("Show hidden files globally", isOn: $settings.showHiddenFiles)
                    LabeledContent("Workspace", value: workspace.files.workspaceRoot.path)
                    LabeledContent("Documents", value: workspace.files.documentsRoot.path)
                    LabeledContent("Library", value: workspace.files.libraryRoot.path)
                    LabeledContent("Temporary", value: workspace.files.temporaryRoot.path)
                }

                Section("Runtime Status") {
                    LabeledContent("Selected toolchain", value: workspace.selectedToolchain.rawValue)
                    LabeledContent("Execution", value: workspace.executionStatus)
                    LabeledContent("Open editors", value: "\(workspace.editor.documents.count)")
                    LabeledContent("Project files", value: "\(workspace.projectFiles.count)")
                    if let code = workspace.lastExitCode {
                        LabeledContent("Last exit code", value: "\(code)")
                    }
                }
            }
            .navigationTitle("Settings")
            .onChange(of: settings.showHiddenFiles) { _ in workspace.syncFileConfiguration() }
        }
    }
}
