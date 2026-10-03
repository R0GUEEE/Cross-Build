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
        [
            .init(name: "Code Editor", detail: "Syntax-aware UIKit editor, tabs, find/replace and editing commands", ready: true, icon: "chevron.left.forwardslash.chevron.right"),
            .init(name: "Workspace Files", detail: "Sandbox file management, import, search and project roots", ready: true, icon: "folder"),
            .init(name: "GitHub Archive Import", detail: "Transactional repository archive import", ready: true, icon: "arrow.down.circle"),
            .init(name: "Project Detection", detail: "Multi-language and build-system detection", ready: true, icon: "sparkle.magnifyingglass"),
            .init(name: "Automatic Configuration", detail: "Toolchain, target, package and Theos configuration generation", ready: true, icon: "wand.and.stars"),
            .init(name: "Local Agent Planner", detail: "Sequenced IDE/build actions with permissions and retries", ready: true, icon: "sparkles"),
            .init(name: "Embedded Linux Runtime", detail: "ios-linuxkit executes shell and POSIX workflows entirely inside Cross Build", ready: true, icon: "terminal"),
            .init(name: "JavaScriptCore", detail: "Embedded JavaScript evaluation with console output", ready: workspace.embeddedToolchains.isAvailable("javascriptcore"), icon: "curlybraces"),
            .init(name: "Python 3", detail: "Embedded CPython interpreter and standard library, running in-process", ready: workspace.embeddedToolchains.isAvailable("python3"), icon: "chevron.left.forwardslash.chevron.right"),
            .init(name: "Embedded Clang", detail: "\(workspace.embeddedToolchains.clang.version) — bridge module linked; LLVM/clangDriver payload still needs native integration", ready: false, icon: "hammer"),
            .init(name: "External Helper", detail: "Removed. Execution no longer depends on a remote, jailbreak, HTTP, or SSH helper.", ready: true, icon: "checkmark.shield"),
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
                LabeledContent("Execution backend", value: "Embedded / In-App")
                LabeledContent("Compatibility runtime", value: "ios-linuxkit")
                LabeledContent("Project", value: workspace.activeProjectRoot ?? "Not detected")
                if let context = workspace.projectContext {
                    LabeledContent("Build system", value: context.buildSystem)
                    LabeledContent("Package format", value: context.packageFormat)
                    LabeledContent("Architecture", value: context.architecture)
                    LabeledContent("Deployment target", value: context.deploymentTarget)
                }
                LabeledContent("Execution status", value: workspace.executionStatus)
                LabeledContent("Parsed diagnostics", value: "\(workspace.buildDiagnostics.count)")
            }

            RuntimeToolchainSection(runtime: workspace.toolchainRuntime)
        }
        .navigationTitle("Feature Diagnostics")
    }
}
