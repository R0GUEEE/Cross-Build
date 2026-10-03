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
