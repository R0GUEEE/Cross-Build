import SwiftUI

struct BottomWorkbenchView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @Binding var panel: ForgePanel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(ForgePanel.allCases) { item in
                    Button {
                        panel = item
                    } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .font(.caption.weight(panel == item ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(panel == item ? .secondary.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
                Spacer()
                IDEStatusPill(icon: "checkmark.circle", text: "Ready")
            }.padding(.horizontal, 8).padding(.vertical, 5)

            Divider()
            Group {
                switch panel {
                case .terminal, .build:
                    ScrollView {
                        Text(workspace.console)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled).padding(10)
                    }
                case .problems:
                    ContentUnavailableView("No Problems", systemImage: "checkmark.circle",
                                           description: Text("Compiler diagnostics will appear here."))
                case .agent:
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
                                .textFieldStyle(.roundedBorder).onSubmit(workspace.runAgent)
                            Button("Run", systemImage: "arrow.up.circle.fill", action: workspace.runAgent)
                                .labelStyle(.iconOnly).font(.title2)
                        }
                    }.padding(10)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
    }
}
