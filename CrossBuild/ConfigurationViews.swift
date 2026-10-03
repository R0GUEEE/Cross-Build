import SwiftUI

struct AppConfigurationView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var secrets = SecureExecutionSecrets.shared

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

            Section("Default Runtime") {
                Picker("Execution backend", selection: $settings.executionBackend) {
                    Text("Automatic").tag("Automatic")
                    Text("Sideload / Embedded").tag("Sideload / Embedded")
                    Text("Jailbreak Local").tag("Jailbreak Local")
                    Text("Remote / SSH").tag("Remote / SSH")
                }
                Toggle("Forward configured environment", isOn: $settings.forwardEnvironment)
                Stepper("Connection timeout: \(settings.connectionTimeout)s", value: $settings.connectionTimeout, in: 2...120)
            }

            Section("Remote Build Helper") {
                TextField("Host", text: $settings.remoteHost)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Scheme", selection: $settings.helperScheme) {
                    Text("HTTP").tag("http")
                    Text("HTTPS").tag("https")
                }
                Stepper("Helper port: \(settings.helperPort)", value: $settings.helperPort, in: 1...65535)
                SecureField("Bearer token (optional)", text: $secrets.remoteToken)
                TextField("Remote workspace", text: $settings.remoteWorkspace)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }

            Section("Jailbreak Local Helper") {
                TextField("Helper host", text: $settings.jailbreakHelperHost)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Stepper("Helper port: \(settings.jailbreakHelperPort)", value: $settings.jailbreakHelperPort, in: 1...65535)
                SecureField("Bearer token (optional)", text: $secrets.jailbreakToken)
                Text("Default localhost helper endpoint is 127.0.0.1:8765.")
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

            Section("Context") {
                Toggle("Include project files", isOn: $settings.agentContextFiles)
                Toggle("Include open editor", isOn: $settings.agentIncludeOpenFile)
                Toggle("Include diagnostics", isOn: $settings.agentContextDiagnostics)
                Toggle("Include Git diff", isOn: $settings.agentContextGitDiff)
                Toggle("Include generated build command", isOn: $settings.agentIncludeBuildCommand)
                Stepper("Diagnostics context: \(settings.agentDiagnosticsLimit) lines",
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
