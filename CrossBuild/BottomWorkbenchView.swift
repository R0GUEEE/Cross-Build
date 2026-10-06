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
            if workspace.runProgress.isRunning {
                RunProgressBar(progress: workspace.runProgress, compact: true)
                    .frame(maxWidth: 240)
            } else if workspace.isExecuting {
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
        case .build: buildPanel
        case .problems: problemsView
        case .agent: agentView
        }
    }

    /// What the Build tab is for.
    ///
    /// It rendered the console, which the Terminal tab already renders, so it
    /// could only ever be a second way to see the same bytes. It is now the app's
    /// build controls: the four project actions, what is running, and what ran
    /// last.
    private var buildPanel: some View {
        VStack(spacing: 0) {
            BuildStatusBar(progress: workspace.runProgress, last: workspace.lastRun)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Divider()
            HStack(spacing: 8) {
                Button("Build", systemImage: "hammer.fill") {
                    workspace.runBuild(settings: workspace.appSettings)
                }
                .buttonStyle(.borderedProminent)
                Button("Clean", systemImage: "trash") {
                    workspace.runWorkflowCommand(workspace.cleanCommand(), settings: workspace.appSettings)
                }
                .buttonStyle(.bordered)
                Button("Test", systemImage: "checkmark.seal") {
                    workspace.runWorkflowCommand(workspace.testCommand(), settings: workspace.appSettings)
                }
                .buttonStyle(.bordered)
                Button("Package", systemImage: "shippingbox") {
                    Task { _ = await workspace.runPackage(settings: workspace.appSettings) }
                }
                .buttonStyle(.bordered)
                Spacer(minLength: ForgeTheme.Space.sm)
                if !workspace.buildDiagnostics.isEmpty {
                    ForgeBadge(text: "\(workspace.buildDiagnostics.count)",
                               icon: "exclamationmark.triangle.fill",
                               tint: .orange)
                        .accessibilityLabel("\(workspace.buildDiagnostics.count) problems")
                }
            }
            .controlSize(.small)
            .disabled(workspace.isExecuting)
            .padding(10)
            Divider()
            consoleView
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
        workspace.runTerminalCommand(command, settings: workspace.appSettings)
        terminalCommand = ""
    }

    private var consoleView: some View {
        ScrollView {
            if workspace.console.isEmpty {
                ForgeEmptyState(icon: "terminal",
                                title: "No Output Yet",
                                message: "Output from anything the app runs appears here.")
            } else {
                Text(workspace.console)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
    }

    private var problemLines: [String] {
        workspace.console.split(separator: "\n").map(String.init).filter {
            ($0.localizedCaseInsensitiveContains("error:") || $0.localizedCaseInsensitiveContains("warning:")) &&
            (problemFilter.isEmpty || $0.localizedCaseInsensitiveContains(problemFilter))
        }
    }

    /// Diagnostics parsed out of the last command, when the output was in a
    /// recognisable `file:line:col: error: message` form.
    private var structuredProblems: [BuildDiagnostic] {
        workspace.buildDiagnostics.filter { diagnostic in
            guard !problemFilter.isEmpty else { return true }
            return diagnostic.message.localizedCaseInsensitiveContains(problemFilter)
                || (diagnostic.file ?? "").localizedCaseInsensitiveContains(problemFilter)
        }
    }

    private var problemsView: some View {
        VStack(spacing: 0) {
            TextField("Filter problems", text: $problemFilter)
                .textFieldStyle(.roundedBorder).padding(8)
            if structuredProblems.isEmpty && problemLines.isEmpty {
                ForgeEmptyState(icon: "checkmark.circle",
                                title: "No Problems",
                                message: problemFilter.isEmpty
                                    ? "Nothing has been reported yet. Build the project and any errors the compiler printed are listed here."
                                    : "No problem matches “\(problemFilter)”.")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(structuredProblems) { diagnostic in
                            // Tappable: a problem that names a file should open it.
                            // The row used to be inert, so the one actionable part
                            // of a diagnostic -- where it is -- did nothing.
                            Button {
                                workspace.openDiagnostic(diagnostic)
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: diagnostic.severity.symbol)
                                        .foregroundStyle(diagnostic.severity.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(diagnostic.message)
                                            .font(.system(.caption, design: .monospaced))
                                            .multilineTextAlignment(.leading)
                                        Text(location(for: diagnostic))
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if diagnostic.file != nil {
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(ForgeTheme.Surface.raised,
                                            in: RoundedRectangle(cornerRadius: ForgeTheme.Radius.small))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(diagnostic.file == nil)
                        }
                        // Only fall back to raw console lines when nothing was
                        // parsed; otherwise the same problem would be listed twice.
                        if structuredProblems.isEmpty {
                            ForEach(Array(problemLines.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: line.localizedCaseInsensitiveContains("error:") ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    Spacer()
                                }.padding(8).background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }.padding(10)
                }
            }
        }
    }

    private func location(for diagnostic: BuildDiagnostic) -> String {
        var parts = [diagnostic.tool]
        if let file = diagnostic.file { parts.append(URL(fileURLWithPath: file).lastPathComponent) }
        if let line = diagnostic.line { parts.append("line \(line)") }
        if let column = diagnostic.column { parts.append("col \(column)") }
        if let code = diagnostic.code { parts.append(code) }
        return parts.joined(separator: " · ")
    }

    private var agentView: some View {
        VStack(spacing: 8) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(workspace.agentActivity.enumerated()), id: \.offset) { _, activity in
                        Label(activity, systemImage: "sparkles").font(.caption)
                    }
                    if workspace.agentActivity.isEmpty {
                        ForgeEmptyState(icon: "sparkles",
                                        title: "No Agent Activity",
                                        message: "Run a task from the Agent tab and every step it takes is listed here.")
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
