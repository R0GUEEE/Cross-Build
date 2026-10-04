import SwiftUI

struct FullSetupView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings
    @StateObject private var service = SetupService()
    @State private var showStepOutput: SetupStep?

    var body: some View {
        Form {
            Section("In-App Runtime") {
                LabeledContent("Execution", value: service.environment.runtime)
                LabeledContent("POSIX runtime", value: service.environment.linuxRuntime)
                LabeledContent("Linux rootfs", value: service.environment.rootfsPresent ? "Ready" : "Missing")
                LabeledContent("Bundled SDKs", value: "\(service.environment.sdkCount)")
                Button {
                    Task { await service.prepare(workspace: workspace, settings: settings) }
                } label: {
                    if service.isRunning { ProgressView() }
                    else { Label("Rescan Installed App", systemImage: "arrow.clockwise") }
                }
                .disabled(service.isRunning)
            }

            Section {
                ForEach(service.environment.toolchains) { tool in
                    HStack(alignment: .top, spacing: 10) {
                        // A catalogue entry with no in-app payload is not an
                        // error, so it is not painted red and does not read as an
                        // error either.
                        Image(systemName: tool.present ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(tool.present ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name).font(.subheadline.weight(.medium))
                            Text(tool.detail).font(.caption).foregroundStyle(.secondary)
                            Text(tool.location).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(tool.present ? "Ready" : "Not bundled")
                            .font(.caption)
                            .foregroundStyle(tool.present ? .green : .secondary)
                    }
                }
            } header: {
                Text(service.didPrepare
                     ? "Compiler Libraries — \(service.presentTools.count) of \(service.environment.toolchains.count) ready"
                     : "Compiler Libraries")
            } footer: {
                Text("Setup scans the installed IPA. It does not install host packages or accept catalogue manifests as proof that a compiler is present.")
                    .font(.caption)
            }

            Section("Setup Plan") {
                ForEach(service.steps) { step in
                    Button {
                        if !step.output.isEmpty { showStepOutput = step }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title).font(.subheadline.weight(.medium))
                                Text(step.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(step.status.rawValue)
                                .font(.caption)
                                .foregroundStyle(statusColor(step.status))
                        }
                    }
                    .disabled(step.output.isEmpty)
                    .buttonStyle(.plain)
                }

                Button {
                    Task { await service.run(workspace: workspace, settings: settings) }
                } label: {
                    Label(service.isRunning ? "Scanning…" : "Verify & Configure", systemImage: "checkmark.shield")
                }
                .disabled(service.isRunning)
            }

            if !service.environment.notes.isEmpty {
                Section("Issues Found") {
                    ForEach(service.environment.notes, id: \.self) {
                        Label($0, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                    }
                }
            }

            if !service.summary.isEmpty {
                Section("Last Result") {
                    Text(service.summary)
                    if !settings.setupCompletedAt.isEmpty {
                        LabeledContent("Completed", value: settings.setupCompletedAt)
                    }
                }
            } else if !settings.setupLastSummary.isEmpty {
                // The summary was persisted on every run and then never shown, so
                // the result of the last scan vanished on the next launch.
                Section("Last Result") {
                    Text(settings.setupLastSummary)
                    if !settings.setupCompletedAt.isEmpty {
                        LabeledContent("Completed", value: settings.setupCompletedAt)
                    }
                }
            }
        }
        .navigationTitle("Setup & System Scan")
        .task { await service.prepare(workspace: workspace, settings: settings) }
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

    private func statusColor(_ status: SetupStepStatus) -> Color {
        switch status {
        case .succeeded: return .green
        case .failed: return .red
        case .running: return .accentColor
        case .pending, .notBundled, .skipped: return .secondary
        }
    }
}
