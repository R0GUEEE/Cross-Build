import SwiftUI

struct BundledResourcesView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @State private var items: [BundledResource] = []
    @State private var pythonSelfTestOutput: String?
    @State private var isRunningSelfTest = false
    @State private var guestTestOutput: String?
    @State private var isRunningGuestTest = false
    @ObservedObject private var session = LinuxGuestSession.shared

    /// One component row.
    ///
    /// Extracted from `body` deliberately. The row used to sit inline, and the
    /// whole body then exceeded what the type checker would solve in reasonable
    /// time -- "unable to type-check this expression in reasonable time", reported
    /// against `var body` itself. That is a build failure, not a layout problem,
    /// so it stopped the entire IPA.
    ///
    /// A function returning `some View` gives inference a fresh and much smaller
    /// problem to solve. The status values are resolved before the view for the
    /// same reason: a nested ternary mixing `.green`, `Color.accentColor` and
    /// `.secondary` is exactly the kind of expression that tips it over.
    private func componentRow(_ item: BundledResource) -> some View {
        let statusLabel: String = item.present ? "Ready"
            : (item.guestBacked == nil ? "Not bundled" : "Via guest")
        let statusTint: Color = item.present ? .green
            : (item.guestBacked == nil ? .secondary : .accentColor)
        return HStack(alignment: .top, spacing: 12) {
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
            Text(statusLabel).font(.caption).foregroundStyle(statusTint)
        }
        .padding(.vertical, 3)
    }

    var body: some View {
        Form {
            Section {
                ForEach(items) { item in
                    componentRow(item)
                }
            } header: {
                Text("Installed app components")
            } footer: {
                Text("This is a live scan of the installed app bundle. A manifest or catalogue entry does not count as a compiler library.")
                    .font(.caption)
            }

            Section {
                // A row the guest satisfies is not absent from the IPA, so it is
                // shown as "Via guest" above rather than under "Missing".
                let missing = items.filter { !$0.present && $0.guestBacked == nil }
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
                Text("These components are absent from this IPA. Entries the Linux guest provides are shown as \u{201C}Via guest\u{201D} above instead. Setup no longer offers host package installation or helper workarounds.")
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
        // Re-read when the guest's tool list arrives. A row is only marked "Via
        // guest" once the probe has answered, and computing the inventory once in
        // .onAppear left the screen saying "Not bundled" for the rest of the visit
        // even after the probe succeeded.
        .task(id: workspace.guestToolchain) { items = BundledResources.inventory() }
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
