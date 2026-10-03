import SwiftUI

struct AgentDashboardView: View {
    @EnvironmentObject private var workspace:WorkspaceModel
    @ObservedObject var settings:AppSettings
    @State private var instruction=""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    VStack(alignment:.leading,spacing:4) {
                        HStack {
                            Image(systemName:"sparkles").font(.largeTitle)
                            VStack(alignment:.leading) {
                                Text("Cross Build Agent").font(.largeTitle.bold())
                                Text("Project-aware build and code automation").foregroundStyle(.secondary)
                            }
                        }
                    }

                    ForgeCard("Ask the Agent",subtitle:"Describe the result you want. Cross Build will detect the project and plan the actions.") {
                        TextEditor(text:$instruction)
                            .frame(minHeight:110).padding(8)
                            .background(.background,in:RoundedRectangle(cornerRadius:10))
                        HStack {
                            Button("Run Task",systemImage:"arrow.up.circle.fill",action:run).buttonStyle(.borderedProminent)
                                .disabled(instruction.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || workspace.isExecuting)
                            Menu("Quick Actions",systemImage:"bolt.fill") {
                                Button("Detect, Configure & Build") { instruction="Detect this project, configure it automatically, and build it" }
                                Button("Fix Build") { instruction="Inspect build errors, fix what can be fixed, and rebuild" }
                                Button("Clean & Package") { instruction="Clean the project and package the final artifact" }
                                Button("Run Tests") { instruction="Run the project tests" }
                            }
                            Spacer()
                            if workspace.isExecuting { ProgressView(); Text(workspace.executionStatus).font(.caption).foregroundStyle(.secondary) }
                        }
                    }

                    ForgeCard("Automatic Project Context",subtitle:"Configuration is generated from the current workspace") {
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:140),spacing:12)],spacing:12) {
                            ForgeMetric(title:"Toolchain",value:workspace.analysis?.primaryToolchain.rawValue ?? "Not detected",icon:"cpu")
                            ForgeMetric(title:"Files",value:"\(workspace.projectFiles.count)",icon:"doc.on.doc")
                            ForgeMetric(title:"Backend",value:settings.executionBackend,icon:"terminal")
                            ForgeMetric(title:"Status",value:workspace.executionStatus,icon:"waveform")
                        }
                        if !workspace.generatedConfigurationSummary.isEmpty {
                            Divider()
                            ForEach(workspace.generatedConfigurationSummary,id:\.self) { item in Label(item,systemImage:"checkmark.circle").font(.caption) }
                        }
                        Button("Refresh Project Detection",systemImage:"arrow.clockwise",action:workspace.detectSampleProject)
                    }

                    ForgeCard("Agent Access",subtitle:"Simple defaults; expand control only when needed") {
                        Toggle("Allow code edits",isOn:$settings.allowAgentEdits)
                        Toggle("Allow builds and compiler actions",isOn:$settings.allowAgentBuilds)
                        Toggle("Allow dependency changes",isOn:$settings.allowAgentDependencies)
                    }

                    ForgeCard("Activity",subtitle:"Actions performed in this session") {
                        if workspace.agentActivity.isEmpty {
                            VStack(spacing:8) {
                                Image(systemName:"sparkles").font(.largeTitle).foregroundStyle(.secondary)
                                Text("No Activity").font(.headline)
                                Text("Run a task to see the agent plan and actions.").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth:.infinity).padding(.vertical,24)
                        } else {
                            ForEach(Array(workspace.agentActivity.enumerated()),id:\.offset) { index,item in
                                HStack(alignment:.top) {
                                    Image(systemName:"checkmark.circle.fill")
                                    VStack(alignment:.leading) { Text(item); Text("Step \(index+1)").font(.caption2).foregroundStyle(.secondary) }
                                    Spacer()
                                }.padding(.vertical,5)
                            }
                        }
                    }
                }.padding().frame(maxWidth:900).frame(maxWidth:.infinity)
            }.navigationTitle("Agent")
        }
    }

    private func run() {
        if workspace.analysis == nil { workspace.detectSampleProject() }
        workspace.agentPrompt=instruction
        workspace.runAgent()
        instruction=""
    }
}
