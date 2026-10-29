import SwiftUI
import UIKit

/// Settings, grouped by what a person came here to change.
///
/// The old screen was one list of ten sections and six navigation links in no
/// particular order, mixing a font slider with the embedded runtime's inventory.
/// This one has four short groups at the top (the things people actually change),
/// then a single "Advanced" group holding the diagnostic screens that used to be
/// top-level tabs.
struct SettingsView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        NavigationStack {
            Form {
                Section("Editor") {
                    HStack {
                        Text("Font size")
                        Slider(value: $settings.editorFontSize, in: 11...24, step: 1)
                        Text("\(Int(settings.editorFontSize))").monospacedDigit()
                    }
                    Toggle("Autosave", isOn: $settings.autosave)
                    Toggle("Trim trailing whitespace", isOn: $settings.trimWhitespace)
                    Toggle("Line numbers", isOn: $settings.editorLineNumbers)
                    Toggle("Word wrap", isOn: $settings.editorWordWrap)
                    Toggle("Highlight current line", isOn: $settings.editorHighlightCurrentLine)
                    Toggle("Auto-close brackets & quotes", isOn: $settings.editorAutoClosePairs)
                    Picker("Tab width", selection: $settings.editorTabWidth) {
                        Text("2").tag(2)
                        Text("4").tag(4)
                        Text("8").tag(8)
                    }
                    Toggle("Insert spaces for tabs", isOn: $settings.editorInsertSpaces)
                }

                Section("Build") {
                    Toggle("Clean before build", isOn: $settings.cleanBeforeBuild)
                    Toggle("Parallel builds", isOn: $settings.parallelBuilds)
                    if settings.parallelBuilds {
                        Stepper("Build jobs: \(settings.buildJobs)", value: $settings.buildJobs, in: 1...32)
                    }
                    Toggle("Warnings as errors", isOn: $settings.warningsAsErrors)
                    Toggle("Verbose output", isOn: $settings.verboseBuild)
                    Toggle("Stop on first failure", isOn: $settings.stopOnFirstError)
                    Stepper(settings.buildTimeout == 0 ? "Timeout: Unlimited" : "Timeout: \(settings.buildTimeout)s",
                            value: $settings.buildTimeout, in: 0...3600, step: 30)
                }

                Section("Project") {
                    Toggle("Detect project automatically", isOn: $settings.autoDetect)
                    Toggle("Open last workspace", isOn: $settings.openLastWorkspace)
                    NavigationLink("Project Settings") {
                        WorkspaceConfigurationView(config: workspace.configuration).environmentObject(workspace)
                    }
                    NavigationLink("Compiler, SDK & Toolchain") {
                        CompilerConfigurationView(config: workspace.compilerConfiguration).environmentObject(workspace)
                    }
                }

                Section("Advanced") {
                    // One screen per question. "Components in this build", "Setup &
                    // System Scan" and "Feature Diagnostics" were three more views of
                    // the same toolchain inventory, two of them with hardcoded rows.
                    NavigationLink("Toolchains & Compilers") {
                        CompilerDashboardView(settings: settings).environmentObject(workspace)
                    }
                    NavigationLink("Sandbox Diagnostics") {
                        SandboxDiagnosticsView(settings: settings).environmentObject(workspace)
                    }
                    NavigationLink("App Configuration") {
                        AppConfigurationView(settings: settings)
                    }
                    NavigationLink("Agent Configuration") {
                        AgentConfigurationView(settings: settings)
                    }
                    Toggle("Show hidden files", isOn: Binding(
                        get: { settings.showHiddenFiles },
                        set: { settings.showHiddenFiles = $0; workspace.syncFileConfiguration() }))
                }

                Section("About") {
                    LabeledContent("Version", value: Self.version)
                    LabeledContent("Workspace", value: workspace.files.workspaceRoot.lastPathComponent)
                    NavigationLink("Licences") { LicenceView() }
                    Button("Copy workspace path") {
                        UIPasteboard.general.string = workspace.files.workspaceRoot.path
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
