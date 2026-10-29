import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    /// Bridges `@AppStorage` to `ObservableObject`.
    ///
    /// This class is an `ObservableObject` but every property is `@AppStorage`,
    /// which writes to `UserDefaults` and publishes nothing. So a Toggle bound to
    /// one of these wrote its new value and then never saw a re-render: the
    /// control snapped back, which looks exactly like a button that does nothing.
    /// That was every control on the Settings screen.
    ///
    /// `UserDefaults` posts a change notification for every write, `@AppStorage`'s
    /// own included, so relaying it is enough. Weakly captured, so this does not
    /// keep the object alive.
    private var defaultsObserver: NSObjectProtocol?

    deinit {
        // The token was stored and never removed, so every instance left an
        // observer behind for the life of the process. `removeObserver(self)` did
        // not fix that: it matches *selector* registrations, and this is a block
        // observer, which is removed by the token it returned. Reading a stored
        // property in `deinit` is legal.
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    init() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

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
    @AppStorage("app.confirmDestructive") var confirmDestructiveActions = true
    @AppStorage("app.openLastWorkspace") var openLastWorkspace = true
    @AppStorage("app.activityLimit") var activityHistoryLimit = 100

    /// Replaces the detected build command when set. Kept empty by default so the
    /// project's own manifest keeps deciding what Build runs.
    @AppStorage("build.commandOverride") var buildCommandOverride = ""
    /// Copy files a build created or changed inside the guest back into the project.
    @AppStorage("build.copyBack") var copyBuildOutputBack = true
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

    // In-app setup records only scan/configuration state. Toolchains ship with the app.
    @AppStorage("setup.completedAt") var setupCompletedAt = ""
    @AppStorage("setup.lastSummary") var setupLastSummary = ""

    @AppStorage("runtime.commandTimeout") var commandTimeout = 0
    @AppStorage("runtime.forwardEnvironment") var forwardEnvironment = true
    @AppStorage("runtime.shell") var shellPath = "/bin/sh"
    @AppStorage("runtime.shellLogin") var shellLogin = false
    @AppStorage("runtime.shellInteractive") var shellInteractive = false
    @AppStorage("runtime.shellInit") var shellInitCommand = ""
    @AppStorage("runtime.terminalPersistent") var terminalPersistentSession = true
}

/// The app has three places to be: the projects you can open, the one you are
/// editing, and the settings that change either.
///
/// There used to be four tabs, two of which (Compiler, Agent) were dashboards of
/// facts about the app rather than places to do something. They are reachable from
/// Settings → Advanced and from the editor's menu, which is where someone looks
/// when they already want them.
enum AppSection: String, CaseIterable, Identifiable {
    case projects = "Projects", build = "Build", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .projects: return "folder"
        case .build: return "hammer"
        case .settings: return "gearshape"
        }
    }
}
