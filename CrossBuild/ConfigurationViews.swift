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
                        Text("Linux Guest").tag("Linux Guest")
                    Text("Remote / Helper").tag("Remote / Helper")
                }
                Toggle("Forward configured environment", isOn: $settings.forwardEnvironment)
                Stepper("Connection timeout: \(settings.connectionTimeout)s", value: $settings.connectionTimeout, in: 2...120)
            }

            Section("Shell Integration") {
                Picker("Shell", selection: $settings.shellPath) {
                    Text("Auto Detect").tag("Auto")
                    Text("Rootless zsh").tag("/var/jb/bin/zsh")
                    Text("Rootless bash").tag("/var/jb/bin/bash")
                    Text("Rootless sh").tag("/var/jb/bin/sh")
                    Text("zsh").tag("/bin/zsh")
                    Text("bash").tag("/bin/bash")
                    Text("sh").tag("/bin/sh")
                }
                Toggle("Login shell", isOn: $settings.shellLogin)
                Toggle("Interactive shell", isOn: $settings.shellInteractive)
                Toggle("Persistent terminal session", isOn: $settings.terminalPersistentSession)
                TextField("Shell initialization command", text: $settings.shellInitCommand, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Stepper("Command timeout: \(settings.commandTimeout)s", value: $settings.commandTimeout, in: 0...3600, step: 5)
                Text("Auto Detect prefers rootless jailbreak shells under /var/jb before system shells. A timeout of 0 disables the command timeout.")
                    .font(.caption).foregroundStyle(.secondary)
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
