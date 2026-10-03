import Foundation
import SwiftUI

enum ToolchainKind: String, CaseIterable, Identifiable {
    case clang = "LLVM / Clang"
    case swift = "Swift / SwiftPM"
    case theos = "Theos / Logos"
    case rust = "Rust / Cargo"
    case go = "Go"
    case zig = "Zig"
    case python = "Python"
    case javascript = "JavaScript / TypeScript"
    case custom = "Make / CMake / Ninja / Meson"
    var id: String { rawValue }
}

struct ToolchainProvider: Identifiable {
    let id = UUID()
    let kind: ToolchainKind
    let markers: [String]
    let buildCommands: [String]
}

enum ToolchainRegistry {
    static let providers: [ToolchainProvider] = [
        .init(kind: .theos, markers: ["control", "Tweak.xm", "Makefile"], buildCommands: ["make", "make package", "make clean"]),
        .init(kind: .swift, markers: ["Package.swift", ".swift"], buildCommands: ["swift build", "swift test"]),
        .init(kind: .rust, markers: ["Cargo.toml", ".rs"], buildCommands: ["cargo build", "cargo test"]),
        .init(kind: .go, markers: ["go.mod", ".go"], buildCommands: ["go build ./...", "go test ./..."]),
        .init(kind: .zig, markers: ["build.zig", ".zig"], buildCommands: ["zig build"]),
        .init(kind: .python, markers: ["pyproject.toml", "requirements.txt", ".py"], buildCommands: ["python3"]),
        .init(kind: .javascript, markers: ["package.json", ".ts", ".js"], buildCommands: ["npm run build", "npm test"]),
        .init(kind: .clang, markers: [".c", ".cc", ".cpp", ".m", ".mm"], buildCommands: ["clang", "clang++"]),
        .init(kind: .custom, markers: ["CMakeLists.txt", "meson.build", "Makefile"], buildCommands: ["make"])
    ]
}

struct AgentTask: Identifiable {
    let id = UUID()
    var title: String
    var instruction: String
    var enabled = true
}

@MainActor
final class WorkspaceModel: ObservableObject {
    private let compilersKey = "crossbuild.customCompilers"
    private let openDocumentsKey = "crossbuild.openDocuments"
    private let selectedDocumentKey = "crossbuild.selectedDocument"
    @Published var selectedToolchain: ToolchainKind = .theos
    @Published var editorText = "// Cross Build\n// Open or create a project to begin.\n"
    @Published var console = "Ready. Toolchain auto-detection enabled.\n" {
        didSet {
            // The console is appended to throughout the app and rendered whole by
            // a Text view, so without a bound it grows for the lifetime of the
            // session. Trim to the most recent output (that is what the user
            // wants to see) from a line boundary, guarded so the assignment here
            // does not recurse through didSet.
            guard !isTrimmingConsole, console.count > Self.consoleCharacterLimit else { return }
            isTrimmingConsole = true
            console = Self.trimConsole(console)
            isTrimmingConsole = false
        }
    }
    private var isTrimmingConsole = false
    private static let consoleCharacterLimit = 400_000
    private static let consoleRetainedCharacters = 300_000

    /// Keeps the tail of the console and drops the rest at a line boundary,
    /// leaving a marker so it is obvious output was dropped rather than silently
    /// missing.
    private static func trimConsole(_ text: String) -> String {
        let dropped = text.count - consoleRetainedCharacters
        let tail = String(text.suffix(consoleRetainedCharacters))
        let trimmedTail = tail.firstIndex(of: "\n").map { String(tail[tail.index(after: $0)...]) } ?? tail
        return "… earlier output trimmed (\(dropped) characters). Settings → Diagnostics → clear to reset.\n" + trimmedTail
    }

    @Published var agentPrompt = ""
    @Published var analysis: ProjectAnalysis?
    @Published var customCompilers: [CustomCompiler] = []
    @Published var selectedCustomCompilerID: UUID?
    @Published var agentActivity: [String] = []
    @Published var isExecuting = false
    @Published var lastExitCode: Int32?
    @Published var executionStatus = "Idle"
    @Published var generatedConfigurationSummary: [String] = []
    @Published var activeProjectRoot: String?
    @Published var recommendedBuildCommand: String?
    @Published var pendingAgentConfirmation: String?
    private var pendingAgentPlan: [AgentExecution] = []
    weak var appSettings: AppSettings?
    private var autosaveTask: Task<Void, Never>?
    let files = FileManagerService()
    let github = GitHubWorkspaceService()
    let configuration = WorkspaceConfiguration()
    let compilerConfiguration = CompilerConfiguration()
    let editor = EditorSession()
    let embeddedToolchains = EmbeddedToolchainManager()
    let toolchainRuntime = ToolchainRuntimeManager()
    @Published var projectContext: ProjectContext?
    @Published var buildDiagnostics: [BuildDiagnostic] = []

    var activeCompiler: CustomCompiler? { customCompilers.first { $0.id == selectedCustomCompilerID } }
    var projectFiles: [WorkspaceFile] {
        files.flattened.filter { !$0.isDirectory && ($0.path == files.workspaceRoot.path || $0.path.hasPrefix(files.workspaceRoot.path + "/")) }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: compilersKey),
           let saved = try? JSONDecoder().decode([CustomCompiler].self, from: data) {
            customCompilers = saved
        }
        syncFileConfiguration()
        restoreOpenDocuments()
    }

    func syncFileConfiguration() {
        files.configure(
            showAppDirectories: configuration.showAppDirectories,
            showBundle: configuration.showAppBundle,
            showLibrary: configuration.showContainerLibrary,
            showTemporary: configuration.showTemporaryFiles,
            showHidden: configuration.searchHiddenFiles || appSettings?.showHiddenFiles == true,
            followSymlinks: configuration.followSymlinks,
            searchCaseSensitive: configuration.searchCaseSensitive,
            searchFileContents: configuration.searchFileContents,
            maxRecentFiles: configuration.maxRecentFiles,
            excludePatterns: configuration.excludePatterns
        )
    }

    private func persistCompilers() {
        if let data = try? JSONEncoder().encode(customCompilers) {
            UserDefaults.standard.set(data, forKey: compilersKey)
        }
    }

    private func restoreOpenDocuments() {
        guard configuration.restoreOpenTabs else { return }
        let paths = UserDefaults.standard.stringArray(forKey: openDocumentsKey) ?? []
        let selectedPath = UserDefaults.standard.string(forKey: selectedDocumentKey)

        for path in paths where FileManager.default.fileExists(atPath: path) {
            guard path == files.workspaceRoot.path || path.hasPrefix(files.workspaceRoot.path + "/") else { continue }
            let file = files.flattened.first(where: { $0.path == path }) ??
                WorkspaceFile(name: URL(fileURLWithPath: path).lastPathComponent, path: path)
            if let text = files.contents(of: file, encoding: editorEncoding) {
                editor.open(file: file, text: text)
            }
        }

        if let selectedPath,
           let selected = editor.documents.first(where: { $0.path == selectedPath }) {
            editor.selectedID = selected.id
        }
        editorText = editor.selected?.text ?? editorText
    }

    private func persistOpenDocuments() {
        guard configuration.restoreOpenTabs else {
            UserDefaults.standard.removeObject(forKey: openDocumentsKey)
            UserDefaults.standard.removeObject(forKey: selectedDocumentKey)
            return
        }
        UserDefaults.standard.set(editor.documents.map(\.path), forKey: openDocumentsKey)
        if let path = editor.selected?.path {
            UserDefaults.standard.set(path, forKey: selectedDocumentKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedDocumentKey)
        }
    }

    private func inferProjectRoot(from files: [WorkspaceFile]) -> String {
        let markers: Set<String> = Set([
            "project.yml", "Package.swift", "Cargo.toml", "go.mod", "build.zig",
            "CMakeLists.txt", "meson.build", "package.json", "pyproject.toml",
            "setup.py", "build.gradle", "build.gradle.kts", "Makefile", "control"
        ]).union(customManifestNames())

        // When nested-project detection is off, every manifest found anywhere in
        // the workspace is still a "candidate" for the *contextual* (currently
        // selected file) branch below, but the workspace root is always the
        // fallback instead of picking the shallowest nested manifest -- i.e. we
        // stop treating subfolders as separate projects on their own.
        let detectNested = configuration.detectNestedProjects
        let candidates = Set(files.compactMap { file -> String? in
            guard markers.contains(file.name) else { return nil }
            return URL(fileURLWithPath: file.path).deletingLastPathComponent().path
        })

        if configuration.preferNearestManifest,
           let selectedPath = filesServiceSelectedPath(),
           let contextual = candidates
            .filter({ selectedPath == $0 || selectedPath.hasPrefix($0 + "/") })
            .sorted(by: { $0.count > $1.count })
            .first {
            return contextual
        }

        guard detectNested else { return self.files.workspaceRoot.path }

        if let candidate = candidates.sorted(by: {
            let leftDepth = $0.split(separator: "/").count
            let rightDepth = $1.split(separator: "/").count
            return leftDepth == rightDepth ? $0.localizedStandardCompare($1) == .orderedAscending : leftDepth < rightDepth
        }).first {
            return candidate
        }
        return self.files.workspaceRoot.path
    }

    private func customManifestNames() -> [String] {
        configuration.customManifestNames
            .components(separatedBy: .newlines)
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func filesServiceSelectedPath() -> String? {
        files.selected?.path
    }
    /// Preset prompts for the Agent dashboard. These drive the quick-action grid
    /// directly, so the list the model exposes is also the list the user sees.
    @Published var tasks: [AgentTask] = [
        .init(title: "Detect & Build", instruction: "Detect this project, configure it automatically, and build it"),
        .init(title: "Repair failed builds", instruction: "Inspect diagnostics, patch safe compiler errors, and rebuild."),
        .init(title: "Clean & Package", instruction: "Clean the project and package the final artifact"),
        .init(title: "Run Tests", instruction: "Run the project tests and inspect failures")
    ]

    func detectSampleProject() {
        detectProject(rootOverride: nil)
    }

    func detectProject(at root: String) {
        detectProject(rootOverride: root)
    }

    private func detectProject(rootOverride: String?) {
        let allFiles = projectFiles
        let root = rootOverride ?? inferProjectRoot(from: allFiles)
        activeProjectRoot = root
        // Deliberately NOT written into `configuration.workingDirectory`: that is
        // the user's "Working directory override" and `executeCommand` already
        // prefers it when it is set. Overwriting it here meant the override was
        // destroyed on every auto-detect at launch and could never be empty
        // again, so the fallback below never applied. The detected root is kept
        // where it belongs, in `activeProjectRoot`.
        let scopedFiles = allFiles.filter { $0.path == root || $0.path.hasPrefix(root + "/") }
        let manifestNames: Set<String> = ["project.yml","Makefile","control","Package.swift","Cargo.toml","go.mod","build.zig","CMakeLists.txt","meson.build","package.json","pyproject.toml","setup.py","build.gradle","build.gradle.kts"]
        // "Index source files" off means detection only looks at manifest
        // filenames, not every source file's extension -- useful for very large
        // trees where walking every path is unnecessary once a manifest already
        // identifies the toolchain.
        let projectPaths = configuration.indexSources ? scopedFiles.map(\.path) : scopedFiles.filter { manifestNames.contains($0.name) }.map(\.path)
        var contents: [String:String] = [:]
        for file in scopedFiles {
            if manifestNames.contains(file.name),
               let text = files.contents(of: file) { contents[file.name] = text }
        }
        let result = ProjectDetector.analyze(paths: projectPaths, fileContents: contents)
        analysis = result
        selectedToolchain = result.primaryToolchain
        let generated = ConfigurationGenerator.generate(from: result, files: scopedFiles, fileContents: contents)
        ConfigurationGenerator.apply(generated, workspace: self)
        generatedConfigurationSummary = generated.summary
        projectContext = ProjectContext.detected(root: root, analysis: result, compiler: compilerConfiguration)
        console += "Configuration: " + generated.summary.joined(separator: " • ") + "\n"
        console += "Auto-detect: \(result.primaryToolchain.rawValue) [\(Int(result.confidence * 100))%]\n"
        console += "Languages: \(result.languages.map(\.rawValue).sorted().joined(separator: ", "))\n"
        console += "Build systems: \(result.buildSystems.map(\.rawValue).sorted().joined(separator: ", "))\n"
        if let type = result.theosType {
            console += "Theos type: \(type.rawValue) • \(result.isRootlessHinted ? "rootless hint" : "scheme unspecified")\n"
        }
        if let candidate = result.candidates.first {
            console += "Recommended: \(candidate.command) — \(candidate.reason)\n"
        }
    }

    func runBuild(settings: AppSettings? = nil) {
        let resolved = settings ?? appSettings
        Task {
            if resolved?.clearDiagnosticsOnBuild == true {
                console = "Build started.\n"
                buildDiagnostics = []
            }

            let timeout = resolvedBuildTimeout(resolved)

            if resolved?.cleanBeforeBuild == true {
                let cleaned = await executeCommand(cleanCommand(), settings: resolved, timeoutOverride: timeout)
                let stopOnFailure = resolved?.stopOnFirstError ?? true
                if !cleaned.succeeded && stopOnFailure {
                    console += "Build stopped after clean failed (Settings → Build Policy → Stop workflow on first failure).\n"
                    return
                }
            }

            let command = configuredBuildCommand(settings: resolved)
            _ = await executeCommand(command, settings: resolved, timeoutOverride: timeout)
        }
    }

    private func configuredBuildCommand(settings: AppSettings?) -> String {
        var command = buildCommand()
        guard let settings else { return command }

        if settings.parallelBuilds {
            let jobs = max(1, settings.buildJobs)
            if command.hasPrefix("make") {
                command += " -j \(jobs)"
            } else if command.hasPrefix("swift build") {
                command += " -j \(jobs)"
            } else if command.hasPrefix("cargo build") {
                command += " -j \(jobs)"
            } else if command.hasPrefix("go build") {
                command = command.replacingOccurrences(of: "go build", with: "go build -p \(jobs)", options: .anchored)
            } else if command.hasPrefix("zig build") {
                command += " -j\(jobs)"
            }
        }

        if settings.verboseBuild {
            if command.hasPrefix("make") {
                command += " messages=yes"
            } else if command.hasPrefix("swift build") || command.hasPrefix("cargo build") {
                command += " -v"
            } else if command.hasPrefix("go build") {
                command = command.replacingOccurrences(of: "go build", with: "go build -x", options: .anchored)
            }
        }

        if settings.warningsAsErrors {
            if command.hasPrefix("swift build") {
                command += " -Xswiftc -warnings-as-errors"
            } else if command.hasPrefix("cargo build") {
                command = "RUSTFLAGS=\"-D warnings\" " + command
            }
        }

        if configuration.buildTarget == "Release" {
            if command.hasPrefix("swift build") && !command.contains(" -c release") {
                command += " -c release"
            } else if command.hasPrefix("cargo build") && !command.contains("--release") {
                command += " --release"
            } else if command.hasPrefix("zig build") && !command.contains("-Doptimize=") {
                command += " -Doptimize=ReleaseSafe"
            } else if command.hasPrefix("make") && !command.contains("DEBUG=") {
                command += " DEBUG=0"
            }
        }

        let extra = configuration.buildArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { command += " " + extra }
        return command
    }

    func newFileName() -> String {
        let ext = configuration.defaultNewFileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return ext.isEmpty ? "Untitled" : "Untitled." + ext
    }

    func buildCommand() -> String {
        if let custom = activeCompiler, !custom.buildCommand.isEmpty { return custom.buildCommand }
        if let recommendedBuildCommand, !recommendedBuildCommand.isEmpty { return recommendedBuildCommand }
        return ToolchainRegistry.providers.first { $0.kind == selectedToolchain }?.buildCommands.first ?? "make"
    }

    func cleanCommand() -> String {
        if let custom = activeCompiler, !custom.cleanCommand.isEmpty { return appendActionArguments(custom.cleanCommand, configuration.cleanArguments) }
        switch selectedToolchain {
        case .theos, .custom, .clang: return appendActionArguments("make clean", configuration.cleanArguments)
        case .swift: return appendActionArguments("swift package clean", configuration.cleanArguments)
        case .rust: return appendActionArguments("cargo clean", configuration.cleanArguments)
        case .go: return appendActionArguments("go clean", configuration.cleanArguments)
        case .zig: return appendActionArguments("rm -rf .zig-cache zig-cache zig-out", configuration.cleanArguments)
        case .python: return appendActionArguments("find . -name __pycache__ -type d -prune -exec rm -rf {} +", configuration.cleanArguments)
        case .javascript: return appendActionArguments("npm run clean", configuration.cleanArguments)
        }
    }

    func testCommand() -> String {
        if let custom = activeCompiler, !custom.testCommand.isEmpty { return appendActionArguments(custom.testCommand, configuration.testArguments) }
        switch selectedToolchain {
        case .theos: return appendActionArguments("make", configuration.testArguments)
        case .swift: return appendActionArguments("swift test", configuration.testArguments)
        case .rust: return appendActionArguments("cargo test", configuration.testArguments)
        case .go: return appendActionArguments("go test ./...", configuration.testArguments)
        case .zig: return appendActionArguments("zig build test", configuration.testArguments)
        case .python: return appendActionArguments("python3 -m unittest", configuration.testArguments)
        case .javascript: return appendActionArguments("npm test", configuration.testArguments)
        case .clang, .custom: return appendActionArguments("make test", configuration.testArguments)
        }
    }

    func packageCommand() -> String {
        if let custom = activeCompiler, !custom.packageCommand.isEmpty { return appendActionArguments(custom.packageCommand, configuration.packageArguments) }
        switch selectedToolchain {
        case .theos: return appendActionArguments("make package", configuration.packageArguments)
        case .swift: return appendActionArguments("swift build -c release", configuration.packageArguments)
        case .rust: return appendActionArguments("cargo build --release", configuration.packageArguments)
        case .go: return appendActionArguments("go build -trimpath ./...", configuration.packageArguments)
        case .zig: return appendActionArguments("zig build -Doptimize=ReleaseSafe", configuration.packageArguments)
        case .python: return appendActionArguments("python3 -m build", configuration.packageArguments)
        case .javascript: return appendActionArguments("npm pack", configuration.packageArguments)
        case .clang, .custom: return appendActionArguments("make package", configuration.packageArguments)
        }
    }

    private func appendActionArguments(_ command: String, _ arguments: String) -> String {
        let extra = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        return extra.isEmpty ? command : command + " " + extra
    }

    func runEmbedded(id: String, source: String? = nil) {
        guard !isExecuting else {
            console += "A command is already running.\n"
            return
        }
        let input = source ?? editorText
        isExecuting = true
        executionStatus = "Running embedded \(id)"
        Task {
            let result = await embeddedToolchains.run(id: id, source: input)
            if !result.output.isEmpty { console += result.output + "\n" }
            result.diagnostics.forEach { console += "embedded: \($0)\n" }
            lastExitCode = result.succeeded ? 0 : 1
            executionStatus = result.succeeded ? "Succeeded" : "Failed"
            isExecuting = false
        }
    }

    private func embeddedID(for toolchain: ToolchainKind) -> String {
        switch toolchain {
        case .javascript: return "javascriptcore"
        case .theos: return "logos-preprocessor"
        case .clang: return "clang"
        case .python: return "python3"
        default: return toolchain.rawValue.lowercased()
        }
    }

    @discardableResult
    /// Resolves "Automatic" to a concrete backend. Single source of truth so
    /// execution and Full Setup cannot disagree about which backend is active.
    func resolvedBackend(settings: AppSettings? = nil) -> (backend: any ExecutionBackend, mode: String) {
        let resolvedSettings = settings ?? appSettings
        var mode = resolvedSettings?.executionBackend ?? "Sideload / Embedded"
        if mode == "Automatic" {
            if embeddedToolchains.isAvailable(embeddedID(for: selectedToolchain)) {
                mode = "Sideload / Embedded"
            } else if !(resolvedSettings?.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                mode = "Remote / Helper"
            } else {
                mode = "Sideload / Embedded"
            }
        }
        return (ExecutionBackendFactory.make(mode: mode, settings: resolvedSettings), mode)
    }

    /// Runs a command through the resolved backend. `timeoutOverride` lets the
    /// build/test/package paths apply the dedicated "Build timeout" setting
    /// instead of the general command timeout; a value of 0 means unlimited.
    @discardableResult
    func executeCommand(_ command: String, settings: AppSettings? = nil, sessionID: String? = nil, timeoutOverride: Int? = nil) async -> CommandResult {
        guard !isExecuting else {
            let result = CommandResult(exitCode: 75, stdout: "", stderr: "Another command is already running.", duration: 0)
            console += "error: \(result.stderr)\n"
            return result
        }
        let resolvedSettings = settings ?? appSettings
        let resolved = resolvedBackend(settings: resolvedSettings)
        let mode = resolved.mode
        let backend = resolved.backend
        let localWorkingDirectory = configuration.workingDirectory.isEmpty ? (activeProjectRoot ?? files.workspaceRoot.path) : configuration.workingDirectory
        let remoteWorkspace = resolvedSettings?.remoteWorkspace.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let workingDirectory = (mode == "Remote / Helper" || mode == "Remote / SSH") && !remoteWorkspace.isEmpty ? remoteWorkspace : localWorkingDirectory
        let startedAt = Date()
        if resolvedSettings?.timestampBuildOutput == true {
            console += "[\(Self.timestampFormatter.string(from: startedAt))] $ \(command)\nBackend: \(backend.name)\n"
        } else {
            console += "$ \(command)\nBackend: \(backend.name)\n"
        }
        isExecuting = true
        executionStatus = "Running"
        var environment = resolvedSettings?.forwardEnvironment == false ? [:] : commandEnvironment()
        if environment["PATH"] == nil {
            environment["PATH"] = "/var/jb/usr/bin:/var/jb/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        if resolvedSettings?.captureEnvironment == true && !environment.isEmpty {
            let summary = environment.keys.sorted().joined(separator: ", ")
            console += "env: \(summary)\n"
        }
        let configuredShell = resolvedSettings?.shellPath.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Auto"
        let request = CommandRequest(
            command: command,
            workingDirectory: workingDirectory,
            environment: environment,
            shell: configuredShell == "Auto" || configuredShell.isEmpty ? nil : configuredShell,
            loginShell: resolvedSettings?.shellLogin ?? false,
            interactiveShell: resolvedSettings?.shellInteractive ?? false,
            initCommand: resolvedSettings?.shellInitCommand.trimmingCharacters(in: .whitespacesAndNewlines),
            timeout: timeoutOverride ?? resolvedSettings?.commandTimeout ?? 0,
            sessionID: sessionID
        )
        let result = await backend.execute(request)
        appendResultOutput(result, settings: resolvedSettings)
        recordDiagnostics(from: result, command: command, settings: resolvedSettings)
        lastExitCode = result.exitCode
        executionStatus = result.succeeded ? "Succeeded" : "Failed (\(result.exitCode))"
        isExecuting = false
        if resolvedSettings?.timestampBuildOutput == true {
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(startedAt))
            console += "[\(Self.timestampFormatter.string(from: Date()))] finished in \(elapsed)s\n"
        }
        return result
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// Appends a command's stdout/stderr to the console, honoring the diagnostics
    /// filtering settings (include warnings/notes, max problem lines). "Problem"
    /// lines are stderr text and any stdout line that reads as a compiler
    /// diagnostic (error:/warning:/note:); everything else in stdout always passes
    /// through unfiltered since those settings only describe diagnostics, not
    /// general build output.
    private func appendResultOutput(_ result: CommandResult, settings: AppSettings?) {
        let includeWarnings = settings?.includeWarnings ?? true
        let includeNotes = settings?.includeNotes ?? true
        let maxProblems = max(1, settings?.maxProblems ?? 200)

        func isProblemLine(_ line: String) -> Bool {
            line.localizedCaseInsensitiveContains("error:") ||
            line.localizedCaseInsensitiveContains("warning:") ||
            line.localizedCaseInsensitiveContains("note:")
        }
        func passesFilter(_ line: String) -> Bool {
            if !includeWarnings && line.localizedCaseInsensitiveContains("warning:") { return false }
            if !includeNotes && line.localizedCaseInsensitiveContains("note:") { return false }
            return true
        }

        if !result.stdout.isEmpty {
            let lines = result.stdout.components(separatedBy: "\n")
            var kept: [String] = []
            var problemCount = 0
            for line in lines {
                if isProblemLine(line) {
                    guard passesFilter(line) else { continue }
                    problemCount += 1
                    if problemCount > maxProblems {
                        if problemCount == maxProblems + 1 {
                            kept.append("… additional problems truncated at \(maxProblems) (Settings → Diagnostics → Maximum problems)")
                        }
                        continue
                    }
                }
                kept.append(line)
            }
            console += kept.joined(separator: "\n") + "\n"
        }
        if !result.stderr.isEmpty {
            let lines = result.stderr.components(separatedBy: "\n").filter(passesFilter)
            if !lines.isEmpty { console += "error: " + lines.joined(separator: "\n") + "\n" }
        }
    }

    /// Parses a command's output into structured diagnostics. `buildDiagnostics`
    /// and `BuildDiagnosticParser` were both fully written but never used, so the
    /// Problems panel could only ever show raw console text.
    private func recordDiagnostics(from result: CommandResult, command: String, settings: AppSettings?) {
        let tool = command.split(separator: " ").first.map(String.init) ?? "build"
        var parsed = BuildDiagnosticParser.parse(result.stdout + "\n" + result.stderr, tool: tool)
        if settings?.includeWarnings == false { parsed = parsed.filter { $0.severity != .warning } }
        if settings?.includeNotes == false { parsed = parsed.filter { $0.severity != .note } }
        let limit = max(1, settings?.maxProblems ?? 200)
        if parsed.count > limit { parsed = Array(parsed.prefix(limit)) }
        buildDiagnostics = parsed
    }

    /// The timeout for build/test/package actions: the dedicated "Build timeout"
    /// when one is set, otherwise the general "Command timeout". `buildTimeout`
    /// previously had a stepper in Settings that nothing read.
    private func resolvedBuildTimeout(_ settings: AppSettings?) -> Int {
        guard let settings else { return 0 }
        return settings.buildTimeout > 0 ? settings.buildTimeout : settings.commandTimeout
    }

    private func commandEnvironment() -> [String: String] {
        var environment: [String: String] = [:]
        for source in [configuration.environmentVariables, compilerConfiguration.environment] {
            for line in source.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let separator = trimmed.firstIndex(of: "=") else { continue }
                let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { environment[key] = value }
            }
        }
        let workspaceSDK = configuration.sdkPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let compilerSDK = compilerConfiguration.sysroot.trimmingCharacters(in: .whitespacesAndNewlines)
        let sdkPath = workspaceSDK.isEmpty ? compilerSDK : workspaceSDK
        if !sdkPath.isEmpty { environment["SDKROOT"] = sdkPath }

        environment["ARCHS"] = compilerConfiguration.architectures
        environment["IPHONEOS_DEPLOYMENT_TARGET"] = compilerConfiguration.deploymentTarget
        environment["CROSSBUILD_CONFIGURATION"] = configuration.buildTarget
        environment["CROSSBUILD_PACKAGE_FORMAT"] = compilerConfiguration.packageFormat
        environment["CROSSBUILD_SIGNING_MODE"] = compilerConfiguration.signingMode

        if selectedToolchain == .theos {
            if compilerConfiguration.theosScheme == "rootless" {
                environment["THEOS_PACKAGE_SCHEME"] = "rootless"
            }
            let theosPath = compilerConfiguration.theosPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !theosPath.isEmpty { environment["THEOS"] = theosPath }
            let theosTarget = compilerConfiguration.theosTarget.trimmingCharacters(in: .whitespacesAndNewlines)
            if !theosTarget.isEmpty { environment["TARGET"] = theosTarget }
        }

        var cFlags: [String] = []
        let compilerFlags = compilerConfiguration.compilerFlags.trimmingCharacters(in: .whitespacesAndNewlines)
        if !compilerFlags.isEmpty { cFlags.append(compilerFlags) }
        if compilerConfiguration.languageStandard != "Default" { cFlags.append("-std=\(compilerConfiguration.languageStandard)") }
        if compilerConfiguration.cppStandard != "Default" { environment["CXXFLAGS"] = "-std=\(compilerConfiguration.cppStandard)" }
        if compilerConfiguration.positionIndependentCode { cFlags.append("-fPIC") }
        if compilerConfiguration.clangModules { cFlags.append("-fmodules") }
        if !compilerConfiguration.objcARC { cFlags.append("-fno-objc-arc") }
        if compilerConfiguration.linkTimeOptimization { cFlags.append("-flto") }
        if compilerConfiguration.bitcode { cFlags.append("-fembed-bitcode") }
        if compilerConfiguration.reproducibleBuild {
            cFlags.append(contentsOf: ["-Xclang", "-fdebug-compilation-dir=.", "-ffile-prefix-map=\(configuration.workingDirectory)=."])
        }
        let minimumOS = compilerConfiguration.minimumOS.trimmingCharacters(in: .whitespacesAndNewlines)
        if !minimumOS.isEmpty { cFlags.append("-mios-version-min=\(minimumOS)") }
        let defines = compilerConfiguration.defines
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "," })
            .map(String.init)
        cFlags.append(contentsOf: defines.map { "-D\($0)" })
        let includes = compilerConfiguration.includePaths
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        cFlags.append(contentsOf: includes.map { "-I\($0)" })
        let systemIncludes = compilerConfiguration.systemIncludePaths
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        cFlags.append(contentsOf: systemIncludes.map { "-isystem \($0)" })
        let undefines = compilerConfiguration.undefines
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "," })
            .map(String.init)
        cFlags.append(contentsOf: undefines.map { "-U\($0)" })
        switch compilerConfiguration.optimization {
        case "Release": cFlags.append("-O2")
        case "Size": cFlags.append("-Oz")
        default: cFlags.append("-O0")
        }
        if compilerConfiguration.debugSymbols { cFlags.append("-g") }
        if !cFlags.isEmpty { environment["CFLAGS"] = cFlags.joined(separator: " ") }

        var ldFlags: [String] = []
        let explicitLinker = compilerConfiguration.linkerFlags.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicitLinker.isEmpty { ldFlags.append(explicitLinker) }
        let libraryPaths = compilerConfiguration.libraryPaths
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        ldFlags.append(contentsOf: libraryPaths.map { "-L\($0)" })
        let frameworkPaths = compilerConfiguration.frameworkSearchPaths
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        ldFlags.append(contentsOf: frameworkPaths.map { "-F\($0)" })
        let libraries = compilerConfiguration.libraries
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
            .map(String.init)
        ldFlags.append(contentsOf: libraries.map { "-l\($0)" })
        let frameworks = compilerConfiguration.frameworks
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        ldFlags.append(contentsOf: frameworks.map { "-framework \($0)" })
        if compilerConfiguration.stripSymbols { ldFlags.append("-Wl,-S") }
        if compilerConfiguration.deadStrip { ldFlags.append("-Wl,-dead_strip") }
        if !ldFlags.isEmpty { environment["LDFLAGS"] = ldFlags.joined(separator: " ") }
        environment["CROSSBUILD_INCREMENTAL_BUILD"] = compilerConfiguration.incrementalBuild ? "1" : "0"

        let entitlements = compilerConfiguration.entitlementsPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entitlements.isEmpty { environment["CROSSBUILD_ENTITLEMENTS"] = entitlements }
        if !compilerConfiguration.targetTriple.isEmpty { environment["CROSSBUILD_TARGET_TRIPLE"] = compilerConfiguration.targetTriple }
        if !compilerConfiguration.swiftFlags.isEmpty { environment["SWIFTFLAGS"] = compilerConfiguration.swiftFlags }
        if !compilerConfiguration.rustFlags.isEmpty { environment["RUSTFLAGS"] = compilerConfiguration.rustFlags }
        if !compilerConfiguration.goFlags.isEmpty { environment["GOFLAGS"] = compilerConfiguration.goFlags }
        if !compilerConfiguration.zigFlags.isEmpty { environment["ZIGFLAGS"] = compilerConfiguration.zigFlags }
        if !compilerConfiguration.theosMakeFlags.isEmpty { environment["CROSSBUILD_THEOS_MAKE_FLAGS"] = compilerConfiguration.theosMakeFlags }
        if !compilerConfiguration.packageName.isEmpty { environment["CROSSBUILD_PACKAGE_NAME"] = compilerConfiguration.packageName }
        if !compilerConfiguration.packageIdentifier.isEmpty { environment["CROSSBUILD_PACKAGE_ID"] = compilerConfiguration.packageIdentifier }
        if !compilerConfiguration.packageVersion.isEmpty { environment["CROSSBUILD_PACKAGE_VERSION"] = compilerConfiguration.packageVersion }
        if !compilerConfiguration.packageArchitecture.isEmpty { environment["CROSSBUILD_PACKAGE_ARCH"] = compilerConfiguration.packageArchitecture }
        if !compilerConfiguration.packageDepends.isEmpty { environment["CROSSBUILD_PACKAGE_DEPENDS"] = compilerConfiguration.packageDepends }
        if !compilerConfiguration.packageSection.isEmpty { environment["CROSSBUILD_PACKAGE_SECTION"] = compilerConfiguration.packageSection }
        if !compilerConfiguration.packageMaintainer.isEmpty { environment["CROSSBUILD_PACKAGE_MAINTAINER"] = compilerConfiguration.packageMaintainer }
        if !compilerConfiguration.packageDescription.isEmpty { environment["CROSSBUILD_PACKAGE_DESCRIPTION"] = compilerConfiguration.packageDescription }
        if !compilerConfiguration.bundleIdentifier.isEmpty { environment["PRODUCT_BUNDLE_IDENTIFIER"] = compilerConfiguration.bundleIdentifier }
        if !compilerConfiguration.signingIdentity.isEmpty { environment["CROSSBUILD_SIGNING_IDENTITY"] = compilerConfiguration.signingIdentity }
        if !compilerConfiguration.provisioningProfile.isEmpty { environment["CROSSBUILD_PROVISIONING_PROFILE"] = compilerConfiguration.provisioningProfile }
        return environment
    }

    func runTerminalCommand(_ command: String, settings: AppSettings? = nil) {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let resolved = settings ?? appSettings
        Task {
            let result = await executeCommand(command, settings: resolved, sessionID: resolved?.terminalPersistentSession == false ? nil : "terminal")
            if result.succeeded, command.trimmingCharacters(in: .whitespacesAndNewlines) == "clear" {
                console = ""
            }
        }
    }

    func runCommand(_ command: String, settings: AppSettings? = nil) {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            console += "error: No command is configured for this action.\n"
            return
        }
        Task { _ = await executeCommand(command, settings: settings) }
    }

    /// Runs the package command and, if it succeeds and an artifact directory is
    /// configured, copies anything new the command produced under the project
    /// root into that directory (optionally clearing it first). Cross Build has
    /// no structured knowledge of what a given toolchain's package step
    /// produces, so this works by diffing the project root's file list before
    /// and after the command runs -- simple, but accurate for the common case of
    /// a build dropping a .deb/.ipa/.zip/binary next to the sources.
    ///
    /// Both the diff and the copy run off the main actor: each walks the entire
    /// project tree, which is far too much synchronous file I/O to do while the
    /// UI is otherwise blocked.
    @discardableResult
    func runPackage(settings: AppSettings? = nil) async -> CommandResult {
        let resolved = settings ?? appSettings
        let command = packageCommand()
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            console += "error: No package command is configured.\n"
            return .init(exitCode: 1, stdout: "", stderr: "No package command configured.", duration: 0)
        }
        let artifactDir = configuration.artifactDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = activeProjectRoot ?? files.workspaceRoot.path

        let beforePaths: Set<String> = artifactDir.isEmpty
            ? []
            : await Self.snapshotFilesOffMain(under: root)

        let result = await executeCommand(command, settings: resolved, timeoutOverride: resolvedBuildTimeout(resolved))

        guard result.succeeded, !artifactDir.isEmpty else { return result }

        let outcome = await Self.collectArtifacts(
            under: root,
            destination: artifactDir,
            before: beforePaths,
            cleanDestination: configuration.cleanArtifactDirectory,
            keepArtifacts: configuration.keepBuildArtifacts
        )
        if !outcome.message.isEmpty { console += outcome.message }
        return result
    }

    private nonisolated static func snapshotFilesOffMain(under root: String) async -> Set<String> {
        await Task.detached(priority: .utility) {
            Set(snapshotFiles(under: root))
        }.value
    }

    /// Diffs the project tree against `before`, copies new files into
    /// `destination`, and optionally clears them from the project root. Pure
    /// file I/O, so it is `nonisolated` and driven from a detached task.
    private nonisolated static func collectArtifacts(under root: String,
                                                     destination artifactDir: String,
                                                     before: Set<String>,
                                                     cleanDestination: Bool,
                                                     keepArtifacts: Bool) async -> (message: String, copied: Int) {
        await Task.detached(priority: .utility) { () -> (message: String, copied: Int) in
            let fm = FileManager.default
            let destination = URL(fileURLWithPath: artifactDir, isDirectory: true)
            var log: [String] = []

            do {
                if cleanDestination, fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            } catch {
                return ("error: Could not prepare artifact directory: \(error.localizedDescription)\n", 0)
            }

            let afterPaths = Set(snapshotFiles(under: root))
            let newPaths = afterPaths.subtracting(before).sorted()
            guard !newPaths.isEmpty else {
                return ("Package succeeded but no new files were found under the project root to copy to the artifact directory.\n", 0)
            }

            var copied = 0
            for path in newPaths {
                let source = URL(fileURLWithPath: path)
                let dest = destination.appendingPathComponent(source.lastPathComponent)
                do {
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    try fm.copyItem(at: source, to: dest)
                    copied += 1
                } catch {
                    log.append("error: Could not copy \(source.lastPathComponent) to artifact directory: \(error.localizedDescription)\n")
                }
            }
            if copied > 0 {
                log.append("Copied \(copied) artifact\(copied == 1 ? "" : "s") to \(destination.path)\n")
            }
            if !keepArtifacts {
                for path in newPaths { try? fm.removeItem(atPath: path) }
                log.append("Removed build artifacts from the project root (Settings → Artifacts → Keep build artifacts is off).\n")
            }
            return (log.joined(), copied)
        }.value
    }

    /// A flat list of regular-file paths under `root`, skipping the same
    /// directory names FileManagerService already excludes from the browser
    /// (.git, DerivedData, .build, node_modules) so a diff doesn't pick up
    /// unrelated VCS/dependency churn as "new artifacts".
    private nonisolated static func snapshotFiles(under root: String) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: root, isDirectory: true),
                                              includingPropertiesForKeys: [.isDirectoryKey],
                                              options: [.skipsHiddenFiles]) else { return [] }
        let skip: Set<String> = [".git", "DerivedData", ".build", "node_modules"]
        var results: [String] = []
        for case let url as URL in enumerator {
            if skip.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
                results.append(url.path)
            }
        }
        return results
    }

    func openSelectedFile() {
        guard let file = files.selected, let text = files.contents(of: file, encoding: editorEncoding) else { return }
        editor.open(file: file, text: text)
        editorText = editor.selected?.text ?? text
        persistOpenDocuments()
    }

    func selectDocument(_ id: UUID) {
        editor.selectedID = id
        if let doc = editor.selected { editorText = doc.text }
        persistOpenDocuments()
    }

    func updateEditorText(_ text: String) {
        editorText = text
        editor.updateText(text)
        guard (appSettings?.autosave ?? true) && configuration.autosave,
              let documentID = editor.selectedID else { return }

        autosaveTask?.cancel()
        let snapshot = text
        autosaveTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            saveDocument(id: documentID, text: snapshot, report: false)
        }
    }

    func closeDocument(_ id: UUID) {
        autosaveTask?.cancel()
        editor.close(id)
        editorText = editor.selected?.text ?? ""
        persistOpenDocuments()
    }

    func deleteFile(_ file: WorkspaceFile) {
        autosaveTask?.cancel()
        let affected = editor.documents
            .filter { $0.path == file.path || $0.path.hasPrefix(file.path + "/") }
            .map(\.id)
        for id in affected { editor.close(id) }
        files.delete(file)
        editorText = editor.selected?.text ?? ""
        persistOpenDocuments()
    }

    /// Renames on disk and repoints any open editor tab at the new path.
    ///
    /// The repointing has to happen here rather than in `FileManagerService`:
    /// open documents live in `EditorSession`, and they carry their own `path`.
    /// Without this, saving a renamed-but-open file would write the *old* name
    /// back to disk, recreating the file that was just renamed away.
    func renameFile(_ file: WorkspaceFile, to newName: String) {
        let oldPath = file.path
        files.rename(file, to: newName)
        guard files.errorMessage == nil else { return }

        let newPath = URL(fileURLWithPath: oldPath)
            .deletingLastPathComponent()
            .appendingPathComponent(newName)
            .path

        for index in editor.documents.indices {
            let path = editor.documents[index].path
            guard path == oldPath || path.hasPrefix(oldPath + "/") else { continue }
            let suffix = String(path.dropFirst(oldPath.count))
            editor.documents[index].path = newPath + suffix
            if suffix.isEmpty { editor.documents[index].name = newName }
        }
        persistOpenDocuments()
        console += "Renamed \(file.name) to \(newName)\n"
    }

    func saveEditor() {
        autosaveTask?.cancel()
        guard let id = editor.selectedID else { return }
        saveDocument(id: id, text: editorText, report: true)
    }

    private func saveDocument(id: UUID, text: String, report: Bool) {
        guard let doc = editor.document(id) else { return }
        let textToSave = normalizedEditorText(text)
        let file = WorkspaceFile(name: doc.name, path: doc.path)

        do {
            try files.save(textToSave, to: file, encoding: editorEncoding)
            editor.markSaved(id, text: textToSave)
            if editor.selectedID == id { editorText = textToSave }
            if report { console += "Saved \(doc.name)\n" }
        } catch {
            console += "Save failed: \(error.localizedDescription)\n"
        }
    }

    private var editorEncoding: String.Encoding {
        configuration.defaultEncoding == "UTF-16" ? .utf16 : .utf8
    }

    private func normalizedEditorText(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n")
        if appSettings?.trimWhitespace == true {
            result = result
                .components(separatedBy: "\n")
                .map { $0.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression) }
                .joined(separator: "\n")
        }
        if configuration.lineEndings == "CRLF" {
            result = result.replacingOccurrences(of: "\n", with: "\r\n")
        }
        return result
    }

    func addCompiler(_ compiler: CustomCompiler) {
        customCompilers.removeAll { $0.name == compiler.name && $0.executable == compiler.executable }
        customCompilers.append(compiler)
        selectedCustomCompilerID = compiler.id
        persistCompilers()
        console += "Added custom compiler: \(compiler.name) [\(compiler.executable)]\n"
    }

    func autoSelectCustomCompiler(paths: [String]) -> Bool {
        guard let match = customCompilers.first(where: { compiler in
            compiler.markers.contains(where: { marker in paths.contains(where: { $0.hasSuffix(marker) || ($0 as NSString).lastPathComponent == marker }) })
        }) else { return false }
        selectedCustomCompilerID = match.id
        console += "Custom compiler detected: \(match.name)\n"
        return true
    }

    /// Outcome of one agent action. The distinction matters: an action that ran
    /// no command at all (an edit, a toolchain switch, or one blocked by
    /// permissions) must not be judged by a stale exit code left over from an
    /// earlier command -- which is what the planner used to do by reading the
    /// shared `lastExitCode`.
    private enum AgentActionOutcome {
        case noCommand
        case command(succeeded: Bool)
    }

    @discardableResult
    private func executeAgentAction(_ execution: AgentExecution) async -> AgentActionOutcome {
        let settings = appSettings
        agentActivity.append(execution.summary)
        console += "Agent → \(execution.summary)\n"

        switch execution.action {
        case .replaceEditor(let text):
            guard settings?.allowAgentEdits != false else {
                console += "Agent edit blocked by permissions.\n"
                return .noCommand
            }
            updateEditorText(text)
            return .noCommand
        case .appendEditor(let text):
            guard settings?.allowAgentEdits != false else {
                console += "Agent edit blocked by permissions.\n"
                return .noCommand
            }
            updateEditorText(editorText + text)
            return .noCommand
        case .selectToolchain(let kind):
            selectedToolchain = kind
            selectedCustomCompilerID = nil
            return .noCommand
        case .runCompiler(let command):
            guard settings?.allowAgentBuilds != false else {
                console += "Agent build blocked by permissions.\n"
                return .noCommand
            }
            let result = await executeCommand(command, settings: settings, timeoutOverride: resolvedBuildTimeout(settings))
            return .command(succeeded: result.succeeded)
        case .clean:
            guard settings?.allowAgentBuilds != false else {
                console += "Agent clean blocked by permissions.\n"
                return .noCommand
            }
            let result = await executeCommand(cleanCommand(), settings: settings, timeoutOverride: resolvedBuildTimeout(settings))
            return .command(succeeded: result.succeeded)
        case .test:
            guard settings?.allowAgentBuilds != false else {
                console += "Agent test blocked by permissions.\n"
                return .noCommand
            }
            let result = await executeCommand(testCommand(), settings: settings, timeoutOverride: resolvedBuildTimeout(settings))
            return .command(succeeded: result.succeeded)
        case .package:
            guard settings?.allowAgentBuilds != false else {
                console += "Agent package blocked by permissions.\n"
                return .noCommand
            }
            let result = await runPackage(settings: settings)
            return .command(succeeded: result.succeeded)
        case .inspectDiagnostics:
            let lines = console.split(separator: "\n")
                .filter { $0.localizedCaseInsensitiveContains("error") || $0.localizedCaseInsensitiveContains("warning") }
                .suffix(max(10, settings?.agentDiagnosticsLimit ?? 40))
            if lines.isEmpty { console += "Diagnostics: no errors or warnings captured.\n" }
            else { console += "Diagnostics snapshot:\n" + lines.joined(separator: "\n") + "\n" }
            return .noCommand
        }
    }

    func runAgent() {
        let request = agentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        guard !isExecuting else {
            console += "Agent is waiting for the active command to finish.\n"
            return
        }

        let settings = appSettings
        if settings?.agentClearActivityBeforeRun == true { agentActivity.removeAll() }
        console += "Agent task: \(request)\n"
        let lower = request.lowercased()
        if settings?.agentAutoDetectProject != false &&
            (analysis == nil || lower.contains("detect") || lower.contains("configure")) {
            detectSampleProject()
        }
        var plan = AgentController.plan(request, workspace: self)
        let limit = max(1, settings?.agentMaxSteps ?? 12)
        if plan.count > limit {
            plan = Array(plan.prefix(limit))
            console += "Agent plan limited to \(limit) steps by configuration.\n"
        }
        agentPrompt = ""

        if settings?.confirmAgentCommands == true && plan.contains(where: agentActionRunsCommand) {
            pendingAgentPlan = plan
            pendingAgentConfirmation = plan.map(\.summary).joined(separator: "\n")
            return
        }

        executeAgentPlan(plan)
    }

    func confirmPendingAgentPlan() {
        let plan = pendingAgentPlan
        pendingAgentPlan = []
        pendingAgentConfirmation = nil
        executeAgentPlan(plan)
    }

    func cancelPendingAgentPlan() {
        pendingAgentPlan = []
        pendingAgentConfirmation = nil
        console += "Agent command plan cancelled.\n"
    }

    /// Dismisses the confirmation alert *without* discarding the plan.
    ///
    /// The alert is presented from a binding whose setter fires when SwiftUI
    /// writes `false` — which can happen either before or after the tapped
    /// button's action runs. When the setter called `cancelPendingAgentPlan()`,
    /// the "Run Commands" path was only correct if the action happened to win
    /// the race; otherwise the plan was cleared first and the agent did nothing,
    /// silently. Making the setter drop only the presentation state makes the two
    /// orderings behave identically, and both explicit buttons remain the only
    /// places that consume the plan.
    func pendingAgentPlanDismissed() {
        pendingAgentConfirmation = nil
    }

    private func executeAgentPlan(_ plan: [AgentExecution]) {
        guard !plan.isEmpty else { return }
        Task {
            for execution in plan {
                var attempt = 0
                let maxRetries = appSettings?.agentAutoRetry == true ? max(0, appSettings?.agentMaxRetries ?? 0) : 0
                var outcome: AgentActionOutcome = .noCommand
                repeat {
                    outcome = await executeAgentAction(execution)
                    // Only a command can "fail". Anything else (an edit, a
                    // toolchain switch, or a permission block) ends the retry
                    // loop for this step rather than being retried against a
                    // stale exit code.
                    guard case .command(let succeeded) = outcome else { break }
                    if succeeded { break }
                    attempt += 1
                    if attempt <= maxRetries {
                        agentActivity.append("Retry \(attempt): \(execution.summary)")
                        console += "Agent retry \(attempt)/\(maxRetries): \(execution.summary)\n"
                    }
                } while attempt <= maxRetries

                if case .command(let succeeded) = outcome, !succeeded,
                   appSettings?.agentStopOnBuildFailure == true {
                    agentActivity.append("Stopped after failure: \(execution.summary)")
                    console += "Agent stopped because the command failed.\n"
                    break
                }
            }
            let limit = max(25, appSettings?.activityHistoryLimit ?? 100)
            if agentActivity.count > limit { agentActivity = Array(agentActivity.suffix(limit)) }
        }
    }

    private func agentActionRunsCommand(_ execution: AgentExecution) -> Bool {
        switch execution.action {
        case .runCompiler, .clean, .test, .package:
            return true
        default:
            return false
        }
    }
}
