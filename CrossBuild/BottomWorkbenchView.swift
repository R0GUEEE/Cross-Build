import SwiftUI

struct BottomWorkbenchView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @Binding var panel: ForgePanel

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
                panelButton(item)
            }
            Spacer()
            IDEStatusPill(icon: "checkmark.circle", text: "Ready")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func panelButton(_ item: ForgePanel) -> some View {
        Button { panel = item } label: {
            Label(item.rawValue, systemImage: item.icon)
                .font(.caption)
                .fontWeight(panel == item ? .semibold : .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(panel == item ? Color.secondary.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var panelContent: some View {
        switch panel {
        case .terminal, .build:
            consoleView
        case .problems:
            emptyProblemsView
        case .agent:
            agentView
        }
    }

    private var consoleView: some View {
        ScrollView {
            Text(workspace.console)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(10)
        }
    }

    private var emptyProblemsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.secondary)
            Text("No Problems").font(.headline)
            Text("Compiler diagnostics will appear here.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                TextField("Ask agent to edit, build, fix, test, package…", text: $workspace.agentPrompt)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { workspace.runAgent() }
                Button(action: workspace.runAgent) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
    }
}
