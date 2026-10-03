import SwiftUI

struct BottomWorkbenchView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @Binding var panel: ForgePanel
    @State private var terminalCommand = ""
    @State private var problemFilter = ""

    var body: some View {
        VStack(spacing: 0) {
            panelSelector
            Divider()
            panelContent
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var panelSelector: some View {
        HStack(spacing: 4) {
            ForEach(ForgePanel.allCases) { item in
                Button { panel = item } label: {
                    Label(item.rawValue, systemImage: item.icon)
                        .font(.caption)
                        .fontWeight(panel == item ? .semibold : .regular)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(panel == item ? Color.secondary.opacity(0.12) : Color.clear))
                }.buttonStyle(.plain)
            }
            Spacer()
            if workspace.isExecuting {
                ProgressView().controlSize(.small)
                Text(workspace.executionStatus).font(.caption2).foregroundStyle(.secondary)
            }
            Button { workspace.console = "" } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).disabled(workspace.console.isEmpty)
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder private var panelContent: some View {
        switch panel {
        case .terminal: terminalView
        case .build: consoleView
        case .problems: problemsView
        case .agent: agentView
        }
    }

    private var terminalView: some View {
        VStack(spacing: 6) {
            consoleView
            HStack {
                TextField("Command", text: $terminalCommand)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(runTerminal)
                Button(action: runTerminal) { Image(systemName: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(terminalCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.isExecuting)
            }
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
    }

    private func runTerminal() {
        let command = terminalCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        workspace.runCommand(command, settings: workspace.appSettings)
        terminalCommand = ""
    }

    private var consoleView: some View {
        ScrollView {
            Text(workspace.console.isEmpty ? "No output yet." : workspace.console)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(workspace.console.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled).padding(10)
        }
    }

    private var problemLines: [String] {
        workspace.console.split(separator: "\n").map(String.init).filter {
            ($0.localizedCaseInsensitiveContains("error:") || $0.localizedCaseInsensitiveContains("warning:")) &&
            (problemFilter.isEmpty || $0.localizedCaseInsensitiveContains(problemFilter))
        }
    }

    private var problemsView: some View {
        VStack(spacing: 0) {
            TextField("Filter problems", text: $problemFilter)
                .textFieldStyle(.roundedBorder).padding(8)
            if problemLines.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No Problems").font(.headline)
                    Text("No matching errors or warnings are in the current output.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(problemLines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: line.localizedCaseInsensitiveContains("error:") ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                Spacer()
                            }.padding(8).background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }.padding(10)
                }
            }
        }
    }

    private var agentView: some View {
        VStack(spacing: 8) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(workspace.agentActivity.enumerated()), id: \.offset) { _, activity in
                        Label(activity, systemImage: "sparkles").font(.caption)
                    }
                    if workspace.agentActivity.isEmpty {
                        Text("Agent activity will appear here.").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                TextField("Ask agent to edit, build, fix, test, package…", text: $workspace.agentPrompt)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !workspace.isExecuting { workspace.runAgent() } }
                    .disabled(workspace.isExecuting)
                Button(action: workspace.runAgent) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain).disabled(workspace.isExecuting || workspace.agentPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(10)
    }
}
