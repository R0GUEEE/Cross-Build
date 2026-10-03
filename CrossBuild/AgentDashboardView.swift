import SwiftUI

struct AgentDashboardView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings
    @State private var instruction = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: "sparkles").font(.largeTitle)
                                    VStack(alignment: .leading) {
                                        Text("Build Agent").font(.title2.bold())
                                        Text("Code, compiler, diagnostics and workspace automation").foregroundStyle(.secondary)
                                    }
                                }
                                TextEditor(text: $instruction)
                                    .frame(minHeight: 100).padding(6)
                                    .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                                HStack {
                                    Button("Run Task", systemImage: "play.fill") {
                                        workspace.agentPrompt = instruction
                                        workspace.runAgent()
                                        instruction = ""
                                    }.buttonStyle(.borderedProminent)
                                    Menu("Quick Tasks", systemImage: "bolt.fill") {
                                        Button("Detect and Build") { instruction = "Detect the compiler and build the project" }
                                        Button("Fix Build Errors") { instruction = "Inspect diagnostics, fix build errors, and rebuild" }
                                        Button("Clean & Package") { instruction = "Clean, build, and package the project" }
                                        Button("Theos Package") { instruction = "Use Theos to build and package this project" }
                                    }
                                }
                            }
                        }

                        GroupBox("Provider & Model") {
                            VStack {
                                Picker("Provider", selection: $settings.agentProvider) {
                                    Text("OpenAI Compatible").tag("OpenAI Compatible")
                                    Text("Local / Custom").tag("Local / Custom")
                                    Text("Remote Agent").tag("Remote Agent")
                                }
                                TextField("Model", text: $settings.agentModel)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                TextField("Endpoint (optional)", text: $settings.agentEndpoint)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                Stepper("Maximum task steps: \(settings.agentMaxSteps)", value: $settings.agentMaxSteps, in: 1...50)
                            }
                        }

                        GroupBox("Context") {
                            VStack {
                                Toggle("Include workspace files", isOn: $settings.agentContextFiles)
                                Toggle("Include diagnostics", isOn: $settings.agentContextDiagnostics)
                                Toggle("Include Git diff", isOn: $settings.agentContextGitDiff)
                                Toggle("Retry recoverable failures", isOn: $settings.agentAutoRetry)
                            }
                        }

                        GroupBox("Permissions") {
                            VStack {
                                Toggle("Edit source code", isOn: $settings.allowAgentEdits)
                                Toggle("Control compilers and builds", isOn: $settings.allowAgentBuilds)
                                Toggle("Install/update dependencies", isOn: $settings.allowAgentDependencies)
                                Toggle("Confirm command execution", isOn: $settings.confirmAgentCommands)
                            }
                        }

                        GroupBox("Activity") {
                            if workspace.agentActivity.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.secondary)
                                    Text("No Agent Activity").font(.headline)
                                    Text("Run a task to see each agent operation here.").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity).padding(.vertical, 24)
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(workspace.agentActivity.enumerated()), id: \.offset) { index, activity in
                                        HStack(alignment: .top) {
                                            Image(systemName: "checkmark.circle.fill")
                                            VStack(alignment: .leading) {
                                                Text(activity)
                                                Text("Step \(index + 1)").font(.caption2).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                        }.padding(8).background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                        }
                    }.padding()
                }
            }.navigationTitle("AI Agent")
        }
    }
}
