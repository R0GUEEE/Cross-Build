import SwiftUI

struct FeatureStatus: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let ready: Bool
    let icon: String
}

struct FeatureDiagnosticsView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings

    private var features: [FeatureStatus] {
        let remoteConfigured = !settings.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return [
            .init(name: "Code Editor", detail: "Syntax-aware UIKit editor, tabs, find/replace and editing commands", ready: true, icon: "chevron.left.forwardslash.chevron.right"),
            .init(name: "Workspace Files", detail: "Sandbox file management, import, search and project roots", ready: true, icon: "folder"),
            .init(name: "GitHub Archive Import", detail: "Transactional repository archive import", ready: true, icon: "arrow.down.circle"),
            .init(name: "Project Detection", detail: "Multi-language and build-system detection", ready: true, icon: "sparkle.magnifyingglass"),
            .init(name: "Automatic Configuration", detail: "Toolchain, target, package and Theos configuration generation", ready: true, icon: "wand.and.stars"),
            .init(name: "Local Agent Planner", detail: "Sequenced IDE/build actions with permissions and retries", ready: true, icon: "sparkles"),
            .init(name: "JavaScriptCore", detail: "Embedded JavaScript evaluation with console output", ready: workspace.embeddedToolchains.isAvailable("javascriptcore"), icon: "curlybraces"),
            .init(name: "Embedded Clang", detail: workspace.embeddedToolchains.clang.version, ready: workspace.embeddedToolchains.clang.isLinked, icon: "hammer"),
            .init(name: "Remote Helper", detail: remoteConfigured ? "CrossBuild Helper host configured" : "Configure a CrossBuild Helper host", ready: remoteConfigured, icon: "network"),
            .init(name: "Jailbreak Helper", detail: "CrossBuild Helper protocol and shell execution are integrated; helper service must be running on the configured endpoint", ready: true, icon: "lock.open"),
            .init(name: "Full Logos Lowering", detail: "Directive recognition is embedded; full Logos parser payload required", ready: false, icon: "wrench.and.screwdriver")
        ]
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
        }
        .navigationTitle("Feature Diagnostics")
    }
}
