import SwiftUI

struct FullSetupView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings

    @StateObject private var service = SetupService()
    @State private var confirmRun = false
    @State private var showStepOutput: SetupStep?

    var body: some View {
        Form {
            environmentSection
            requirementsSection
            planSection
            runSection
            if !service.summary.isEmpty {
                Section("Last result") { Text(service.summary).font(.callout) }
            }
        }
        .navigationTitle("Full Setup")
        .task { await service.prepare(workspace: workspace, settings: settings) }
        .confirmationDialog("Run Full Setup?", isPresented: $confirmRun, titleVisibility: .visible) {
            Button("Run Setup") {
                Task { await service.run(workspace: workspace, settings: settings) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
        .sheet(item: $showStepOutput) { step in
            NavigationStack {
                ScrollView {
                    Text(step.output.isEmpty ? "No output captured." : step.output)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                }
                .navigationTitle(step.title)
            }
        }
    }

    private var confirmationMessage: String {
        var lines: [String] = []
        if let install = service.steps.first(where: { $0.kind == .install }) {
            lines.append("Will install: \(install.detail)")
            lines.append("Command: \(install.command)")
        } else {
            lines.append("Nothing to install — no missing tools that this host's package manager can provide.")
        }
        lines.append("Then applies host PATH, THEOS and SDK paths, and runs project detection.")
        return lines.joined(separator: "\n\n")
    }

    // MARK: Sections

    private var environmentSection: some View {
        Section {
            LabeledContent("Backend", value: service.environment.backendName)
            if !service.environment.osDescription.isEmpty {
                LabeledContent("Host", value: service.environment.osDescription)
            }
            LabeledContent("Package manager",
                           value: service.environment.packageManager.isEmpty ? "none detected" : service.environment.packageManager)
            LabeledContent("Privileges", value: privilegeDescription)
            Button {
                Task { await service.prepare(workspace: workspace, settings: settings) }
            } label: {
                if service.isRunning { ProgressView() } else { Label("Re-detect host", systemImage: "arrow.clockwise") }
            }
            .disabled(service.isRunning)
        } header: {
            Text("Environment")
        } footer: {
            if service.environment.notes.isEmpty {
                Text(service.statusLine).font(.caption)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(service.environment.notes, id: \.self) { note in
                        Text(note).font(.caption)
                    }
                }
            }
        }
    }

    private var privilegeDescription: String {
        if service.environment.isRoot { return "root" }
        if service.environment.hasSudo { return "non-root, sudo available" }
        return "non-root, no sudo"
    }

    private var requirementsSection: some View {
        Section {
            ForEach(SetupCatalog.tools) { tool in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: toolIcon(tool))
                        .frame(width: 22)
                        .foregroundStyle(service.presence[tool.binary] == true ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name).font(.subheadline.weight(.medium))
                        Text(tool.hint).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(statusText(tool))
                        .font(.caption)
                        .foregroundStyle(service.presence[tool.binary] == true ? .green : .secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text(service.presence.isEmpty
                 ? "Requirements — not detected"
                 : "Requirements — \(service.presentTools.count) of \(SetupCatalog.tools.count) present")
        } footer: {
            Text("“Manual” means no package name is known for this host's package manager, so Cross Build will not guess at an install command for it.")
                .font(.caption)
        }
    }

    private func toolIcon(_ tool: SetupTool) -> String {
        if service.presence.isEmpty { return "questionmark.circle" }
        if service.presence[tool.binary] == true { return "checkmark.circle.fill" }
        if tool.packages[service.environment.packageManager] != nil { return "arrow.down.circle" }
        return "questionmark.circle"
    }

    private func statusText(_ tool: SetupTool) -> String {
        if service.presence.isEmpty {
            return service.didPrepare ? "Unknown" : "…"
        }
        if service.presence[tool.binary] == true { return "Present" }
        if !service.didPrepare && service.environment.canSpawnProcesses { return "…" }
        if tool.packages[service.environment.packageManager] != nil { return "Will install" }
        return tool.essential ? "Manual" : "Optional"
    }

    private var planSection: some View {
        Section("Plan") {
            if service.steps.isEmpty {
                Text("No steps — detect the host first.").foregroundStyle(.secondary)
            }
            ForEach(service.steps) { step in
                Button {
                    if !step.output.isEmpty { showStepOutput = step }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: stepIcon(step))
                            .foregroundStyle(stepColor(step))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).font(.subheadline.weight(.medium))
                            Text(step.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(step.status.rawValue).font(.caption).foregroundStyle(stepColor(step))
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func stepIcon(_ step: SetupStep) -> String {
        if service.runningStepID == step.id { return "circle.dotted" }
        switch step.status {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .skipped: return "minus.circle"
        case .running: return "circle.dotted"
        case .pending: return "circle"
        }
    }

    private func stepColor(_ step: SetupStep) -> Color {
        switch step.status {
        case .succeeded: return .green
        case .failed: return .red
        case .skipped: return .secondary
        case .running: return .accentColor
        case .pending: return .secondary
        }
    }

    private var runSection: some View {
        Section {
            Toggle("Install missing packages", isOn: $settings.allowSetupInstalls)
            Button {
                confirmRun = true
            } label: {
                Label(service.isRunning ? "Running…" : "Run Full Setup", systemImage: "wand.and.stars")
            }
            .disabled(service.isRunning || !service.didPrepare)
        } header: {
            Text("Run")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(service.environment.canSpawnProcesses
                     ? "Installs go through the active backend onto \(service.environment.backendName). Nothing is installed while the toggle is off — the plan still runs and reports."
                     : "Unavailable: no backend can spawn processes. See Environment above.")
                    .font(.caption)
                Text("Toolchains are large: on Alpine, clang pulls in roughly 1 GB and zig about 1.4 GB of packages. Confirm there is enough free space before installing them all.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
