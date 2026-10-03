import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("editor.fontSize") var editorFontSize = 15.0
    @AppStorage("editor.lineNumbers") var showLineNumbers = true
    @AppStorage("editor.wordWrap") var wordWrap = true
    @AppStorage("editor.autosave") var autosave = true
    @AppStorage("build.parallel") var parallelBuilds = true
    @AppStorage("build.autoDetect") var autoDetect = true
    @AppStorage("build.cleanBefore") var cleanBeforeBuild = false
    @AppStorage("agent.confirmCommands") var confirmAgentCommands = true
    @AppStorage("agent.allowEdits") var allowAgentEdits = true
    @AppStorage("agent.allowBuild") var allowAgentBuilds = true
    @AppStorage("agent.allowDependencies") var allowAgentDependencies = false
    @AppStorage("files.showHidden") var showHiddenFiles = false
    @AppStorage("appearance.compact") var compactUI = false
    @AppStorage("editor.minimap") var showMinimap = false
    @AppStorage("editor.folding") var codeFolding = true
    @AppStorage("editor.whitespace") var showWhitespace = false
    @AppStorage("editor.tabWidth") var tabWidth = 4
    @AppStorage("editor.trimWhitespace") var trimWhitespace = true
    @AppStorage("build.verbose") var verboseBuild = true
    @AppStorage("build.warningsErrors") var warningsAsErrors = false
    @AppStorage("build.jobs") var buildJobs = 4
    @AppStorage("diagnostics.live") var liveDiagnostics = true
    @AppStorage("diagnostics.clearBuild") var clearDiagnosticsOnBuild = true
    @AppStorage("git.fetchOpen") var gitFetchOnOpen = false
    @AppStorage("git.confirmDestructive") var confirmDestructiveGit = true
    @AppStorage("agent.provider") var agentProvider = "OpenAI Compatible"
    @AppStorage("agent.model") var agentModel = ""
    @AppStorage("agent.endpoint") var agentEndpoint = ""
    @AppStorage("agent.contextFiles") var agentContextFiles = true
    @AppStorage("agent.contextDiagnostics") var agentContextDiagnostics = true
    @AppStorage("agent.contextGitDiff") var agentContextGitDiff = true
    @AppStorage("agent.autoRetry") var agentAutoRetry = true
    @AppStorage("agent.maxSteps") var agentMaxSteps = 12
    @AppStorage("runtime.backend") var executionBackend = "Automatic"
    @AppStorage("runtime.remoteHost") var remoteHost = ""
    @AppStorage("runtime.remotePort") var remotePort = 22
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
