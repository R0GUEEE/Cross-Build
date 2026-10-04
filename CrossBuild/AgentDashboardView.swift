import SwiftUI

struct AgentDashboardView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings
    @State private var instruction = ""
    @State private var showConfiguration = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").font(.largeTitle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cross Build Agent").font(.largeTitle.bold())
                            Text("Project-aware build, diagnostics and code automation").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Configure", systemImage: "gearshape") { showConfiguration = true }
                            .buttonStyle(.bordered)
                    }

                    ForgeCard("Task", subtitle: "Describe the project operation. The local planner converts it into executable IDE actions.") {
                        TextEditor(text: $instruction)
                            .frame(minHeight: 120)
                            .padding(8)
                            .background(.background, in: RoundedRectangle(cornerRadius: 10))

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], spacing: 8) {
                            // Driven by the workspace's own preset list rather than
                            // a parallel set of hardcoded prompts.
                            ForEach(workspace.tasks.filter(\.enabled)) { task in
                                quick(task.title, task.instruction)
                            }
                        }

                        HStack {
                            Button("Run Task", systemImage: "arrow.up.circle.fill", action: run)
                                .buttonStyle(.borderedProminent)
                                .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.isExecuting)
                            Button("Clear", systemImage: "xmark") { instruction = "" }
                                .buttonStyle(.bordered)
                                .disabled(instruction.isEmpty)
                            Spacer()
                            if workspace.runProgress.isRunning {
                                RunProgressBar(progress: workspace.runProgress)
                                    .frame(maxWidth: 240)
                            } else if workspace.isExecuting {
                                ProgressView()
                                Text(workspace.executionStatus).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    ForgeCard("Agent State", subtitle: "The values below are the context the planner will use.") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                            ForgeMetric(title: "Toolchain", value: workspace.analysis?.primaryToolchain.rawValue ?? workspace.selectedToolchain.rawValue, icon: "cpu")
                            ForgeMetric(title: "Files", value: "\(workspace.projectFiles.count)", icon: "doc.on.doc")
                            ForgeMetric(title: "Runtime", value: "Embedded", icon: "terminal")
                            ForgeMetric(title: "Status", value: workspace.executionStatus, icon: "waveform")
                        }
                        Divider()
                        HStack {
                            Label(settings.allowAgentEdits ? "Edits enabled" : "Read only", systemImage: settings.allowAgentEdits ? "pencil" : "lock")
                            Label(settings.allowAgentBuilds ? "Build enabled" : "Build blocked", systemImage: "hammer")
                            Label("Max \(settings.agentMaxSteps) steps", systemImage: "list.number")
                            Spacer()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Button("Refresh Project Context", systemImage: "arrow.clockwise") { workspace.detectSampleProject() }
                    }

                    ForgeCard("Activity", subtitle: "Actions performed by the current Agent session") {
                        HStack {
                            Text("\(workspace.agentActivity.count) events").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear Activity", systemImage: "trash") { workspace.agentActivity.removeAll() }
                                .buttonStyle(.borderless)
                                .disabled(workspace.agentActivity.isEmpty)
                        }
                        if workspace.agentActivity.isEmpty {
                            ForgeEmptyState(icon: "sparkles",
                                            title: "No Activity",
                                            message: "Run a task to see each planned action and result.")
                        } else {
                            ForEach(Array(workspace.agentActivity.enumerated()), id: \.offset) { index, item in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "checkmark.circle.fill")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item)
                                        Text("Event \(index + 1)").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 5)
                            }
                        }
                    }
                }
                .padding(settings.compactUI ? 10 : 16)
                .frame(maxWidth: 950)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Agent")
            .toolbar { ToolbarItem(placement: .topBarLeading) { AppMenuButton(settings: settings) } }
            .sheet(isPresented: $showConfiguration) {
                NavigationStack {
                    AgentConfigurationView(settings: settings)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showConfiguration = false }
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func quick(_ title: String, _ prompt: String) -> some View {
        Button(title) { instruction = prompt }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
    }

    private func run() {
        let request = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        workspace.agentPrompt = request
        workspace.runAgent()
        instruction = ""
    }
}
