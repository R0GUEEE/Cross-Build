import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("editor.fontSize") var editorFontSize = 15.0
    @AppStorage("editor.autosave") var autosave = true
    @AppStorage("editor.trimWhitespace") var trimWhitespace = true

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
    @AppStorage("agent.contextFiles") var agentContextFiles = true
    @AppStorage("agent.contextDiagnostics") var agentContextDiagnostics = true
    @AppStorage("agent.contextGitDiff") var agentContextGitDiff = true

    @AppStorage("files.showHidden") var showHiddenFiles = false

    @AppStorage("runtime.backend") var executionBackend = "Automatic"
    @AppStorage("runtime.remoteHost") var remoteHost = ""
    @AppStorage("runtime.remotePort") var remotePort = 22
    @AppStorage("runtime.remoteUser") var remoteUser = ""
    @AppStorage("runtime.remoteWorkspace") var remoteWorkspace = ""
    @AppStorage("runtime.connectTimeout") var connectionTimeout = 15
    @AppStorage("runtime.commandTimeout") var commandTimeout = 0
    @AppStorage("runtime.keepAlive") var keepAlive = true
    @AppStorage("runtime.forwardEnvironment") var forwardEnvironment = true
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
