import SwiftUI

/// The build tab: the project's target, its commands, and what the guest can
/// actually run them with.
///
/// The four actions (Build / Clean / Test / Package) used to be scattered between a
/// menu in the editor, a bottom panel and a dashboard; the settings that change
/// what those actions do lived two screens away. This puts the command, the way it
/// runs and the result in one place, and shows the log in a popup while it runs.
struct BuildView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings

    @State private var showLog = false
    @State private var showToolchains = false
    @State private var showAgent = false

    private var projectName: String {
        guard let root = workspace.activeProjectRoot, !root.isEmpty else { return "Workspace" }
        let name = URL(fileURLWithPath: root).lastPathComponent
        return name.isEmpty ? "Workspace" : name
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                runCard
                commandCard
                optionsCard
                toolchainCard
            }
            .padding(14)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(ForgeTheme.Surface.background)
        .sheet(isPresented: $showLog) {
            BuildLogSheet().environmentObject(workspace)
        }
        .sheet(isPresented: $showAgent) {
            NavigationStack {
                AgentDashboardView(settings: settings)
                    .environmentObject(workspace)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showAgent = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showToolchains) {
            NavigationStack {
                CompilerDashboardView(settings: settings)
                    .environmentObject(workspace)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showToolchains = false }
                        }
                    }
            }
        }
        // A build opens its log by itself. The old behaviour appended output to a
        // panel that might be collapsed, so a build could run and finish without the
        // user ever seeing a line of it.
        .onChange(of: workspace.runProgress.isRunning) { running in
            if running { showLog = true }
        }
        .onChange(of: workspace.isExecuting) { running in
            if running { showLog = true }
        }
        // The options follow the project. Opening this tab used to show whatever the
        // previous project had left behind, including a command that no longer
        // applied.
        .task(id: workspace.activeProjectRoot) {
            workspace.autoConfigureBuildOptions(settings: settings)
        }
    }

    // MARK: - Run

    private var runCard: some View {
        ForgeCard(projectName, subtitle: "\(workspace.analysis?.primaryToolchain.rawValue ?? workspace.selectedToolchain.rawValue) • \(workspace.projectFiles.count) files") {
            VStack(spacing: 12) {
                if workspace.runProgress.isRunning {
                    RunProgressBar(progress: workspace.runProgress)
                } else if !workspace.lastRun.label.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: workspace.lastRun.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(workspace.lastRun.succeeded ? .green : .red)
                        Text("\(workspace.lastRun.label) \(workspace.lastRun.succeeded ? "succeeded" : "failed")")
                            .font(.subheadline.weight(.medium))
                        Text(RunProgressBar.clock(workspace.lastRun.seconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Log") { showLog = true }.buttonStyle(.bordered).controlSize(.small)
                    }
                }

                Button {
                    workspace.runBuild(settings: settings)
                    showLog = true
                } label: {
                    HStack {
                        if workspace.isExecuting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "hammer.fill")
                        }
                        Text(workspace.isExecuting ? "Building…" : "Build")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(workspace.isExecuting)

                HStack(spacing: 8) {
                    secondary("Clean", icon: "trash") {
                        workspace.runWorkflowCommand(workspace.cleanCommand(), settings: settings)
                    }
                    secondary("Test", icon: "checkmark.seal") {
                        workspace.runWorkflowCommand(workspace.testCommand(), settings: settings)
                    }
                    secondary("Package", icon: "shippingbox") {
                        Task { _ = await workspace.runPackage(settings: settings) }
                    }
                    secondary("All Files", icon: "square.stack.3d.down.right") {
                        workspace.compileAllIndividualSources(settings: settings)
                    }
                }
                .disabled(workspace.isExecuting)
            }
        }
    }

    private func secondary(_ title: String, icon: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: icon)
                .font(.caption)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
        }
        .buttonStyle(AnyButtonStyle(.bordered))
    }

    // MARK: - Command

    private var commandCard: some View {
        ForgeCard("Command", subtitle: workspace.buildCommand().isEmpty ? "None" : "What Build runs") {
            VStack(alignment: .leading, spacing: 10) {
                Text(workspace.buildCommand())
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)

                TextField("Override build command", text: $settings.buildCommandOverride)
                    .font(.system(.footnote, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                HStack {
                    Picker("Toolchain", selection: $workspace.selectedToolchain) {
                        ForEach(ToolchainKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                    Button("Detect", systemImage: "sparkle.magnifyingglass") {
                        workspace.detectSampleProject()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var optionsCard: some View {
        ForgeCard("Options", subtitle: "Applied to every action on this screen") {
            VStack(spacing: 8) {
                Toggle("Clean before build", isOn: $settings.cleanBeforeBuild)
                Toggle("Parallel builds", isOn: $settings.parallelBuilds)
                if settings.parallelBuilds {
                    Stepper("Jobs: \(settings.buildJobs)", value: $settings.buildJobs, in: 1...16)
                }
                Toggle("Verbose output", isOn: $settings.verboseBuild)
                Toggle("Warnings as errors", isOn: $settings.warningsAsErrors)
                Toggle("Stop on first failure", isOn: $settings.stopOnFirstError)
                Toggle("Copy build output back to the project", isOn: $settings.copyBuildOutputBack)
                Picker("Configuration", selection: Binding(
                    get: { workspace.configuration.buildTarget },
                    set: { workspace.configuration.buildTarget = $0 }
                )) {
                    Text("Debug").tag("Debug")
                    Text("Release").tag("Release")
                }
                Stepper(settings.buildTimeout == 0 ? "Timeout: Unlimited" : "Timeout: \(settings.buildTimeout)s",
                        value: $settings.buildTimeout, in: 0...3600, step: 60)
            }
            .font(.subheadline)
        }
    }

    // MARK: - Toolchains

    private var toolchainCard: some View {
        ForgeCard("Toolchains", subtitle: toolchainSubtitle) {
            VStack(alignment: .leading, spacing: 8) {
                if workspace.guestToolchain.isEmpty {
                    Text("Asking the guest…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(workspace.guestToolchain.sorted().joined(separator: "  ·  "))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                let missing = ToolchainRuntimeArchitecture.unbundledToolchains
                if !missing.isEmpty {
                    Divider()
                    Text("Not bundled")
                        .font(.caption.weight(.semibold))
                    ForEach(missing) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "minus.circle")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.id).font(.caption)
                                Text(item.reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button("Agent") { showAgent = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("All toolchains…") { showToolchains = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Test toolchains") {
                        workspace.runToolchainSelfTest()
                        showLog = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(workspace.isExecuting)
                }
            }
        }
    }

    private var toolchainSubtitle: String {
        if let error = workspace.guestToolchainError { return error }
        return workspace.guestToolchain.isEmpty ? "Checking the embedded Linux guest" : "In the embedded Linux guest"
    }
}

/// The live build log.
///
/// The console is the same string the app has always appended to; what is new is
/// that a run brings it to the front, follows the end, and can be dismissed without
/// cancelling anything.
struct BuildLogSheet: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var follow = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if workspace.runProgress.isRunning {
                    RunProgressBar(progress: workspace.runProgress)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    Divider()
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(workspace.console.isEmpty ? "No output yet." : workspace.console)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .id("end")
                    }
                    .onChange(of: workspace.console.count) { _ in
                        guard follow else { return }
                        withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
                Divider()
                HStack {
                    Toggle("Follow output", isOn: $follow)
                        .toggleStyle(.switch)
                        .font(.caption)
                    Spacer()
                    Button("Clear", systemImage: "trash") { workspace.console = "" }
                        .disabled(workspace.console.isEmpty)
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .navigationTitle(workspace.runProgress.isRunning ? workspace.runProgress.label : "Build Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
