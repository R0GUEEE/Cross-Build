import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        NavigationStack {
            Form {
                Section("Editor") {
                    HStack { Text("Font Size"); Slider(value: $settings.editorFontSize, in: 11...24, step: 1); Text("\(Int(settings.editorFontSize))").monospacedDigit() }
                    Toggle("Line Numbers", isOn: $settings.showLineNumbers)
                    Toggle("Word Wrap", isOn: $settings.wordWrap)
                    Toggle("Autosave", isOn: $settings.autosave)
                }
                Section("Build & Compiler") {
                    Toggle("Auto-detect compiler on project open", isOn: $settings.autoDetect)
                    Toggle("Parallel builds", isOn: $settings.parallelBuilds)
                    Toggle("Clean before build", isOn: $settings.cleanBeforeBuild)
                    NavigationLink("Compiler Manager") { Text("Use the Compiler tab to add, configure, and select custom toolchains.").padding() }
                }
                Section("AI Agent") {
                    Toggle("Allow source edits", isOn: $settings.allowAgentEdits)
                    Toggle("Allow compiler/build control", isOn: $settings.allowAgentBuilds)
                    Toggle("Allow dependency changes", isOn: $settings.allowAgentDependencies)
                    Toggle("Confirm command execution", isOn: $settings.confirmAgentCommands)
                }
                Section("Files") {
                    Toggle("Show hidden files", isOn: $settings.showHiddenFiles)
                    LabeledContent("Workspace files", value: "Managed by project")
                }
                Section("Appearance") {
                    Toggle("Compact interface", isOn: $settings.compactUI)
                }
                Section("Cross Build") {
                    LabeledContent("Target", value: "iOS 16+")
                    LabeledContent("Architecture", value: "arm64")
                    LabeledContent("Build", value: "Development")
                    Text("Cross Build is a portable compiler workbench with integrated project detection, file management, compiler control, and AI automation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Settings")
        }
    }
}
