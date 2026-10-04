import SwiftUI

struct BundledResourcesView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @State private var items: [BundledResource] = []
    @State private var pythonSelfTestOutput: String?
    @State private var isRunningSelfTest = false
    @State private var guestTestOutput: String?
    @State private var isRunningGuestTest = false
    @ObservedObject private var session = LinuxGuestSession.shared

    var body: some View {
        Form {
            Section {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.present ? item.icon : "xmark.circle")
                            .frame(width: 22)
                            .foregroundStyle(item.present ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.subheadline.weight(.medium))
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            Text("\(item.location) • \(item.execution.rawValue)")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(item.present ? "Ready" : "Missing")
                            .font(.caption)
                            .foregroundStyle(item.present ? .green : .red)
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                Text("Installed app components")
            } footer: {
                Text("This is a live scan of the installed app bundle. A manifest or catalogue entry does not count as a compiler library.")
                    .font(.caption)
            }

            Section {
                let missing = items.filter { !$0.present }
                if missing.isEmpty {
                    Label("All declared in-app components were discovered.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    ForEach(missing) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.subheadline.weight(.medium))
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Bundle scan")
            } footer: {
                Text("Missing components must be linked or bundled into the IPA; setup no longer offers host package installation or helper workarounds.")
                    .font(.caption)
            }

            Section {
                Button { runPythonSelfTest() } label: {
                    if isRunningSelfTest { ProgressView() }
                    else { Label("Run Python self-test", systemImage: "checklist") }
                }
                .disabled(isRunningSelfTest)
                if let pythonSelfTestOutput {
                    Text(pythonSelfTestOutput)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                Text("Verify Python")
            }

            Section {
                Button { runGuestTest() } label: {
                    if isRunningGuestTest { ProgressView() }
                    else { Label("Boot embedded Linux runtime", systemImage: "play.circle") }
                }
                .disabled(isRunningGuestTest)
                LabeledContent("Guest", value: guestStateDescription)
                if let guestTestOutput {
                    Text(guestTestOutput)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                Text("Verify ios-linuxkit")
            }
        }
        .navigationTitle("Bundled Components")
        .onAppear { items = BundledResources.inventory() }
    }

    private func runPythonSelfTest() {
        isRunningSelfTest = true
        pythonSelfTestOutput = "Running…"
        Task {
            let result = await workspace.embeddedToolchains.run(id: "python3", source: PythonSelfTest.script)
            var text = result.output
            if !result.diagnostics.isEmpty {
                text += (text.isEmpty ? "" : "\n") + result.diagnostics.joined(separator: "\n")
            }
            pythonSelfTestOutput = text.isEmpty ? (result.succeeded ? "Passed." : "Did not run.") : text
            isRunningSelfTest = false
        }
    }

    private var guestStateDescription: String {
        switch session.state {
        case .idle: return "not started"
        case .starting: return "starting…"
        case .running: return "running"
        case .unavailable(let message): return "unavailable — \(message)"
        case .failed(let message): return "failed — \(message)"
        }
    }

    private func runGuestTest() {
        isRunningGuestTest = true
        guestTestOutput = "Booting…"
        Task {
            let result = await LinuxGuestExecutionBackend().execute(CommandRequest(command: LinuxGuestSmokeTest.command))
            var text = result.stdout
            if !result.stderr.isEmpty { text += (text.isEmpty ? "" : "\n") + result.stderr }
            guestTestOutput = "exit \(result.exitCode) in \(String(format: "%.1f", result.duration))s\n\n" + text
            isRunningGuestTest = false
        }
    }
}
