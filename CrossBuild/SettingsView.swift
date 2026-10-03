import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        NavigationStack {
            Form {
                Section("Configuration") {
                    NavigationLink("Workspace & Project") {
                        WorkspaceConfigurationView(config: workspace.configuration).environmentObject(workspace)
                    }
                    NavigationLink("Compiler, SDK & Toolchain") {
                        CompilerConfigurationView(config: workspace.compilerConfiguration).environmentObject(workspace)
                    }
                    NavigationLink("Custom Compilers") {
                        CompilerManagerView().environmentObject(workspace)
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
                    LabeledContent("Editor engine", value: "System TextEditor")
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

                Section("Agent Permissions") {
                    LabeledContent("Engine", value: "Local project planner")
                    Toggle("Allow source edits", isOn: $settings.allowAgentEdits)
                    Toggle("Allow compiler/build control", isOn: $settings.allowAgentBuilds)
                    Toggle("Allow dependency changes", isOn: $settings.allowAgentDependencies)
                    Toggle("Allow destructive actions", isOn: $settings.allowAgentDestructiveActions)
                    Toggle("Confirm command execution", isOn: $settings.confirmAgentCommands)
                }

                Section("Agent Workflow") {
                    Stepper("Maximum steps: \(settings.agentMaxSteps)", value: $settings.agentMaxSteps, in: 1...50)
                    Toggle("Auto-retry failed steps", isOn: $settings.agentAutoRetry)
                    if settings.agentAutoRetry {
                        Stepper("Maximum retries: \(settings.agentMaxRetries)", value: $settings.agentMaxRetries, in: 0...5)
                    }
                    Toggle("Stop on build failure", isOn: $settings.agentStopOnBuildFailure)
                    Toggle("Include project files in context", isOn: $settings.agentContextFiles)
                    Toggle("Include diagnostics in context", isOn: $settings.agentContextDiagnostics)
                    Toggle("Include Git diff in context", isOn: $settings.agentContextGitDiff)
                }

                Section("Execution Runtime") {
                    Picker("Backend", selection: $settings.executionBackend) {
                        Text("Automatic").tag("Automatic")
                        Text("Sideload / Embedded").tag("Sideload / Embedded")
                        Text("Jailbreak Local").tag("Jailbreak Local")
                        Text("Remote / SSH").tag("Remote / SSH")
                    }
                    Stepper(settings.commandTimeout == 0 ? "Command timeout: Unlimited" : "Command timeout: \(settings.commandTimeout)s",
                            value: $settings.commandTimeout, in: 0...3600, step: 15)
                    Toggle("Forward configured environment", isOn: $settings.forwardEnvironment)

                    if settings.executionBackend == "Remote / SSH" {
                        TextField("Remote host", text: $settings.remoteHost).textInputAutocapitalization(.never)
                        TextField("Remote user", text: $settings.remoteUser).textInputAutocapitalization(.never)
                        Stepper("SSH port: \(settings.remotePort)", value: $settings.remotePort, in: 1...65535)
                        TextField("Remote workspace path", text: $settings.remoteWorkspace)
                        Stepper("Connection timeout: \(settings.connectionTimeout)s", value: $settings.connectionTimeout, in: 5...120, step: 5)
                        Toggle("Keep connection alive", isOn: $settings.keepAlive)
                        Text("The SSH transport is still a backend integration point; these values are persisted for the transport implementation.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
