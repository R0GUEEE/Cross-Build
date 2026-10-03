import SwiftUI

struct FeatureStatus: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let ready: Bool
    let icon: String
}

/// Result of an actual reachability probe against a CrossBuild Helper endpoint.
/// A nil probe means "not checked yet" -- which is reported as neither Ready nor
/// broken, rather than assuming either.
private struct HelperProbe {
    var reachable: Bool
    var message: String
}

struct FeatureDiagnosticsView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings

    @State private var jailbreakProbe: HelperProbe?
    @State private var remoteProbe: HelperProbe?
    @State private var isProbing = false

    private var features: [FeatureStatus] {
        [
            .init(name: "Code Editor", detail: "Syntax-aware UIKit editor, tabs, find/replace and editing commands", ready: true, icon: "chevron.left.forwardslash.chevron.right"),
            .init(name: "Workspace Files", detail: "Sandbox file management, import, search and project roots", ready: true, icon: "folder"),
            .init(name: "GitHub Archive Import", detail: "Transactional repository archive import", ready: true, icon: "arrow.down.circle"),
            .init(name: "Project Detection", detail: "Multi-language and build-system detection", ready: true, icon: "sparkle.magnifyingglass"),
            .init(name: "Automatic Configuration", detail: "Toolchain, target, package and Theos configuration generation", ready: true, icon: "wand.and.stars"),
            .init(name: "Local Agent Planner", detail: "Sequenced IDE/build actions with permissions and retries", ready: true, icon: "sparkles"),
            .init(name: "JavaScriptCore", detail: "Embedded JavaScript evaluation with console output", ready: workspace.embeddedToolchains.isAvailable("javascriptcore"), icon: "curlybraces"),
            .init(name: "Embedded Clang", detail: "\(workspace.embeddedToolchains.clang.version) — bridge module linked; no vendored LLVM/clangDriver payload yet, so compile() reports a native but unimplemented failure", ready: false, icon: "hammer"),
            .init(name: "Remote Helper", detail: remoteDetail, ready: remoteProbe?.reachable ?? false, icon: "network"),
            .init(name: "Jailbreak Helper", detail: jailbreakDetail, ready: jailbreakProbe?.reachable ?? false, icon: "lock.open"),
            .init(name: "Full Logos Lowering", detail: "Directive recognition is embedded; full Logos parser payload required", ready: false, icon: "wrench.and.screwdriver")
        ]
    }

    private var jailbreakDetail: String {
        if let probe = jailbreakProbe {
            return probe.reachable
                ? "Reachable at \(settings.jailbreakHelperHost):\(settings.jailbreakHelperPort) — \(probe.message)"
                : "Not responding at \(settings.jailbreakHelperHost):\(settings.jailbreakHelperPort) — \(probe.message). Run Tools/crossbuild-helper.py on the device."
        }
        return "Checking \(settings.jailbreakHelperHost):\(settings.jailbreakHelperPort)…"
    }

    private var remoteDetail: String {
        let host = settings.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return "Configure a CrossBuild Helper host" }
        if let probe = remoteProbe {
            return probe.reachable
                ? "Reachable at \(host):\(settings.helperPort) — \(probe.message)"
                : "Not responding at \(host):\(settings.helperPort) — \(probe.message)"
        }
        return "Checking \(host):\(settings.helperPort)…"
    }

    var body: some View {
        List {
            Section("Feature Readiness") {
                ForEach(features) { feature in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: feature.icon).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(feature.name).font(.headline)
                            Text(feature.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Label(feature.ready ? "Ready" : "Requires Component",
                              systemImage: feature.ready ? "checkmark.circle.fill" : "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(feature.ready ? .green : .secondary)
                    }.padding(.vertical, 3)
                }
            }
            Section("Runtime") {
                LabeledContent("Selected toolchain", value: workspace.selectedToolchain.rawValue)
                LabeledContent("Execution backend", value: settings.executionBackend)
                LabeledContent("Project", value: workspace.activeProjectRoot ?? "Not detected")
                LabeledContent("Execution status", value: workspace.executionStatus)
            }
            Section {
                Button {
                    Task { await probeHelpers() }
                } label: {
                    if isProbing { ProgressView() } else { Label("Recheck helper endpoints", systemImage: "arrow.clockwise") }
                }
                .disabled(isProbing)
            } footer: {
                Text("Helper entries reflect a live reachability check, not a configured setting.")
                    .font(.caption)
            }
        }
        .navigationTitle("Feature Diagnostics")
        .task { await probeHelpers() }
    }

    /// Both helper entries report the outcome of a real request. Probing runs on
    /// appear and on demand so the screen cannot claim a component works when
    /// nothing is listening on the endpoint.
    private func probeHelpers() async {
        isProbing = true
        defer { isProbing = false }

        let jailbreakClient = CrossBuildHelperClient(
            host: settings.jailbreakHelperHost,
            port: settings.jailbreakHelperPort,
            scheme: settings.helperScheme,
            token: SecureExecutionSecrets.shared.jailbreakToken,
            timeout: min(5, max(2, settings.connectionTimeout))
        )
        let (jailbreakReady, jailbreakMessage) = await jailbreakClient.health()
        jailbreakProbe = HelperProbe(reachable: jailbreakReady, message: jailbreakMessage)

        let host = settings.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            remoteProbe = nil
            return
        }
        let remoteClient = CrossBuildHelperClient(
            host: host,
            port: settings.helperPort,
            scheme: settings.helperScheme,
            token: SecureExecutionSecrets.shared.remoteToken,
            timeout: min(5, max(2, settings.connectionTimeout))
        )
        let (remoteReady, remoteMessage) = await remoteClient.health()
        remoteProbe = HelperProbe(reachable: remoteReady, message: remoteMessage)
    }
}
