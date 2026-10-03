import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("editor.fontSize") var editorFontSize = 15.0
    @AppStorage("editor.autosave") var autosave = true
    @AppStorage("editor.trimWhitespace") var trimWhitespace = true
    @AppStorage("editor.tabWidth") var editorTabWidth = 4
    @AppStorage("editor.insertSpaces") var editorInsertSpaces = true
    @AppStorage("editor.wordWrap") var editorWordWrap = true
    @AppStorage("editor.lineNumbers") var editorLineNumbers = true
    @AppStorage("editor.highlightLine") var editorHighlightCurrentLine = true
    @AppStorage("editor.autoClosePairs") var editorAutoClosePairs = true
    @AppStorage("editor.invisibles") var editorShowInvisibles = false

    @AppStorage("app.compactUI") var compactUI = false
    @AppStorage("app.showStatusBadges") var showStatusBadges = true
    @AppStorage("app.confirmDestructive") var confirmDestructiveActions = true
    @AppStorage("app.openLastWorkspace") var openLastWorkspace = true
    @AppStorage("app.showWelcome") var showWelcomeScreen = true
    @AppStorage("app.bottomPanelDefault") var defaultBottomPanel = "Terminal"
    @AppStorage("app.bottomPanelExpanded") var defaultBottomPanelExpanded = true
    @AppStorage("app.navigatorWidth") var navigatorWidth = 300.0
    @AppStorage("app.activityLimit") var activityHistoryLimit = 100

    @AppStorage("build.parallel") var parallelBuilds = true
    @AppStorage("build.autoDetect") var autoDetect = true
    @AppStorage("build.cleanBefore") var cleanBeforeBuild = false
    @AppStorage("build.verbose") var verboseBuild = true
    @AppStorage("build.warningsErrors") var warningsAsErrors = false
    @AppStorage("build.jobs") var buildJobs = 4
    @AppStorage("build.timeout") var buildTimeout = 0
    @AppStorage("build.stopOnFirstError") var stopOnFirstError = true
    @AppStorage("build.captureEnvironment") var captureEnvironment = true
    @AppStorage("build.timestampOutput") var timestampBuildOutput = false

    @AppStorage("diagnostics.clearBuild") var clearDiagnosticsOnBuild = true
    @AppStorage("diagnostics.maxProblems") var maxProblems = 200
    @AppStorage("diagnostics.includeWarnings") var includeWarnings = true
    @AppStorage("diagnostics.includeNotes") var includeNotes = true

    @AppStorage("agent.confirmCommands") var confirmAgentCommands = true
    @AppStorage("agent.allowEdits") var allowAgentEdits = true
    @AppStorage("agent.allowBuild") var allowAgentBuilds = true
    @AppStorage("agent.allowDependencies") var allowAgentDependencies = false
    @AppStorage("agent.allowDestructive") var allowAgentDestructiveActions = false
    @AppStorage("agent.autoRetry") var agentAutoRetry = true
    @AppStorage("agent.maxSteps") var agentMaxSteps = 12
    @AppStorage("agent.maxRetries") var agentMaxRetries = 2
    @AppStorage("agent.stopOnBuildFailure") var agentStopOnBuildFailure = true
    @AppStorage("agent.autoDetect") var agentAutoDetectProject = true
    @AppStorage("agent.autoConfigure") var agentAutoConfigureProject = true
    @AppStorage("agent.clearActivity") var agentClearActivityBeforeRun = false
    @AppStorage("agent.diagnosticsLimit") var agentDiagnosticsLimit = 40
    @AppStorage("agent.preferredAction") var agentPreferredAction = "Build"

    @AppStorage("files.showHidden") var showHiddenFiles = false

    // Full Setup
    @AppStorage("setup.allowInstalls") var allowSetupInstalls = true
    @AppStorage("setup.completedAt") var setupCompletedAt = ""
    @AppStorage("setup.lastSummary") var setupLastSummary = ""

    @AppStorage("runtime.backend") var executionBackend = "Automatic"
    @AppStorage("runtime.remoteHost") var remoteHost = ""
    @AppStorage("runtime.remoteWorkspace") var remoteWorkspace = ""
    @AppStorage("runtime.connectTimeout") var connectionTimeout = 15
    @AppStorage("runtime.commandTimeout") var commandTimeout = 0
    @AppStorage("runtime.forwardEnvironment") var forwardEnvironment = true
    @AppStorage("runtime.helperScheme") var helperScheme = "http"
    @AppStorage("runtime.helperPort") var helperPort = 8765
    @AppStorage("runtime.jailbreakHost") var jailbreakHelperHost = "127.0.0.1"
    @AppStorage("runtime.jailbreakPort") var jailbreakHelperPort = 8765
    @AppStorage("runtime.shell") var shellPath = "Auto"
    @AppStorage("runtime.shellLogin") var shellLogin = false
    @AppStorage("runtime.shellInteractive") var shellInteractive = false
    @AppStorage("runtime.shellInit") var shellInitCommand = ""
    @AppStorage("runtime.terminalPersistent") var terminalPersistentSession = true
}

enum AppSection: String, CaseIterable, Identifiable {
    case workspace = "Workspace", compiler = "Compiler", agent = "Agent", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .workspace: return "rectangle.split.3x1"
        case .compiler: return "cpu"
        case .agent: return "sparkles"
        case .settings: return "gearshape"
        }
    }
}
