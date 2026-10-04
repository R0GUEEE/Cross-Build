import SwiftUI

struct AppConfigurationView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Interface") {
                Toggle("Compact interface", isOn: $settings.compactUI)
                Toggle("Show status badges", isOn: $settings.showStatusBadges)
                Picker("Default bottom panel", selection: $settings.defaultBottomPanel) {
                    ForEach(ForgePanel.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Toggle("Open bottom panel by default", isOn: $settings.defaultBottomPanelExpanded)
                HStack {
                    Text("Navigator width")
                    Slider(value: $settings.navigatorWidth, in: 220...480, step: 10)
                    Text("\(Int(settings.navigatorWidth))").monospacedDigit()
                }
            }

            Section("Startup") {
                Toggle("Open last workspace", isOn: $settings.openLastWorkspace)
                Toggle("Show welcome screen for empty workspace", isOn: $settings.showWelcomeScreen)
                Toggle("Auto-detect project on launch", isOn: $settings.autoDetect)
            }

            Section("Safety & History") {
                Toggle("Confirm destructive actions", isOn: $settings.confirmDestructiveActions)
                Stepper("Activity history: \(settings.activityHistoryLimit)", value: $settings.activityHistoryLimit, in: 25...500, step: 25)
            }

            Section("Runtime") {
                LabeledContent("Execution", value: "Embedded / In-App")
                LabeledContent("POSIX runtime", value: "ios-linuxkit")
                Toggle("Forward configured environment", isOn: $settings.forwardEnvironment)
                Stepper(settings.commandTimeout == 0 ? "Command timeout: Unlimited" : "Command timeout: \(settings.commandTimeout)s",
                        value: $settings.commandTimeout, in: 0...3600, step: 15)
                Text("Compiler engines and support libraries are discovered from the app bundle. Shell/POSIX commands execute inside the embedded ios-linuxkit environment.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Embedded Shell") {
                Picker("Shell", selection: $settings.shellPath) {
                    Text("sh").tag("/bin/sh")
                    Text("bash").tag("/bin/bash")
                }
                Toggle("Login shell", isOn: $settings.shellLogin)
                Toggle("Interactive shell", isOn: $settings.shellInteractive)
                Toggle("Persistent terminal session", isOn: $settings.terminalPersistentSession)
                TextField("Initialization command", text: $settings.shellInitCommand, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Shell paths are resolved inside the bundled Linux root. Host and jailbreak /var/jb shell options were removed.")
                    .font(.caption).foregroundStyle(.secondary)
            }


        }
        .navigationTitle("App Configuration")
    }
}

struct AgentConfigurationView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Execution") {
                Picker("Preferred action", selection: $settings.agentPreferredAction) {
                    ForEach(["Build","Test","Package","Diagnose"], id: \.self) { Text($0).tag($0) }
                }
                Stepper("Maximum plan steps: \(settings.agentMaxSteps)", value: $settings.agentMaxSteps, in: 1...50)
                Toggle("Auto-retry failed commands", isOn: $settings.agentAutoRetry)
                if settings.agentAutoRetry {
                    Stepper("Maximum retries: \(settings.agentMaxRetries)", value: $settings.agentMaxRetries, in: 0...5)
                }
                Toggle("Stop plan on build failure", isOn: $settings.agentStopOnBuildFailure)
                Toggle("Clear activity before each run", isOn: $settings.agentClearActivityBeforeRun)
            }

            Section("Project Automation") {
                Toggle("Detect project automatically", isOn: $settings.agentAutoDetectProject)
                Toggle("Generate project configuration automatically", isOn: $settings.agentAutoConfigureProject)
            }

            Section("Permissions") {
                Toggle("Allow source edits", isOn: $settings.allowAgentEdits)
                Toggle("Allow build/compiler actions", isOn: $settings.allowAgentBuilds)
                Toggle("Allow dependency changes", isOn: $settings.allowAgentDependencies)
                Toggle("Allow destructive actions", isOn: $settings.allowAgentDestructiveActions)
                Toggle("Confirm command execution", isOn: $settings.confirmAgentCommands)
            }

            Section("Diagnostics") {
                // The former "Context" toggles are gone rather than sitting there
                // inert: the planner builds no model prompt, so "include project
                // files / open editor / diagnostics / Git diff / build command"
                // had nothing to act on and could not change any behaviour. The
                // one thing the planner really does consume is diagnostics, and
                // this stepper is what bounds that snapshot.
                Stepper("Diagnostics snapshot: \(settings.agentDiagnosticsLimit) lines",
                        value: $settings.agentDiagnosticsLimit, in: 10...200, step: 10)
            }

            Section {
                Text("Cross Build currently uses its local project-aware planner. Network model/provider integration is not presented as active until a provider backend is connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Agent Configuration")
    }
}
