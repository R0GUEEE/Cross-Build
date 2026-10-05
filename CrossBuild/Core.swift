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

    /// Progress for whatever is currently running.
    ///
    /// A command here runs to completion and hands back its whole output at once,
    /// so there is no byte stream to derive a percentage from -- and inventing one
    /// would be a lie. What the app does know is how many steps a workflow has, so
    /// a multi-step run reports a real fraction and a single command reports an
    /// indeterminate bar with elapsed time.
    struct RunProgress: Equatable {
        enum Phase: Equatable {
            case idle
            /// `fraction` is nil when the run has no known length.
            case running(fraction: Double?)
        }
        var phase: Phase = .idle
        var label: String = ""
        var detail: String = ""
        /// Steps finished so far.
        var step: Int = 0
        var stepCount: Int = 0
        var startedAt: Date?

        var isRunning: Bool { if case .running = phase { return true }; return false }
        var fraction: Double? {
            if case .running(let fraction) = phase { return fraction }
            return nil
        }
        var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
        /// 1-based step being worked on, for "step 2 of 3".
        var currentStep: Int { min(step + 1, max(1, stepCount)) }
    }

    /// What the last run was, kept after it finishes. `RunProgress` is cleared
    /// when a run ends, so without this the status bar could only ever say "not
    /// running" -- there was no way to see how long the build that just finished
    /// actually took.
    struct RunRecord: Equatable {
        var label: String = ""
        var seconds: TimeInterval = 0
        var succeeded = true
    }

    @Published private(set) var runProgress = RunProgress()
    @Published private(set) var lastRun = RunRecord()
    /// Per-file results for individual compiles, keyed by path relative to the
    /// project root, so a file can show whether it last compiled.
    @Published private(set) var individualResults: [String: RunRecord] = [:]
    /// Nesting depth, so a workflow that announced its own steps is not
    /// overwritten by the individual commands it runs.
    private var progressDepth = 0
    /// Keys already reported as unusable, so the note is printed once rather than
    /// on every command.
    private var reportedEnvironmentKeys = Set<String>()

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
        // "Open last workspace" is the user-facing switch for remembering tabs
        // between launches; without it the setting was a toggle that did nothing.
        guard configuration.restoreOpenTabs, appSettings?.openLastWorkspace ?? true else {
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
        // "Auto-detect toolchain" now does what it says. With it off, detection
        // still analyses the project and reports what it found, but stops
        // overriding the toolchain the user picked.
        if configuration.autoDetectToolchain {
            selectedToolchain = result.primaryToolchain
        }
        let generated = ConfigurationGenerator.generate(from: result, files: scopedFiles, fileContents: contents)
        // "Generate project configuration automatically" gates the write now.
        // The summary is kept either way, because that is what the detection
        // screens (Compiler Configuration, Workspace Configuration) display.
        if appSettings?.agentAutoConfigureProject != false {
            ConfigurationGenerator.apply(generated, workspace: self)
        } else {
            console += "Automatic configuration is off: toolchain, deployment target and architectures were left as they are.\n"
        }
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
            // Clean plus build is two steps. A build on its own has no known
            // length, so it reports an indeterminate bar rather than a made-up
            // percentage.
            let stepCount = resolved?.cleanBeforeBuild == true ? 2 : 1
            beginProgress(label: "Build", detail: buildCommand(), stepCount: stepCount)
            defer { endProgress() }
            await probeGuestToolchain()

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
                setProgress(step: 1, detail: "Cleaned; compiling")
            }

            let command = configuredBuildCommand(settings: resolved)
            setProgress(step: stepCount - 1, detail: "Compiling")
            _ = await executeCommand(command, settings: resolved, timeoutOverride: timeout)
            setProgress(step: stepCount)
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
        if let recommendedBuildCommand, !recommendedBuildCommand.isEmpty { return applyingMakeFlags(recommendedBuildCommand) }
        return applyingMakeFlags(ToolchainRegistry.providers.first { $0.kind == selectedToolchain }?.buildCommands.first ?? "make")
    }

    func cleanCommand() -> String {
        if let custom = activeCompiler, !custom.cleanCommand.isEmpty { return appendActionArguments(custom.cleanCommand, configuration.cleanArguments) }
        switch selectedToolchain {
        case .theos, .custom, .clang: return applyingMakeFlags(appendActionArguments("make clean", configuration.cleanArguments))
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
        case .theos: return applyingMakeFlags(appendActionArguments("make", configuration.testArguments))
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
        case .theos: return applyingMakeFlags(appendActionArguments("make package", configuration.packageArguments))
        case .swift: return appendActionArguments("swift build -c release", configuration.packageArguments)
        case .rust: return appendActionArguments("cargo build --release", configuration.packageArguments)
        case .go: return appendActionArguments("go build -trimpath ./...", configuration.packageArguments)
        case .zig: return appendActionArguments("zig build -Doptimize=ReleaseSafe", configuration.packageArguments)
        case .python: return appendActionArguments("python3 -m build", configuration.packageArguments)
        case .javascript: return appendActionArguments("npm pack", configuration.packageArguments)
        case .clang, .custom: return applyingMakeFlags(appendActionArguments("make package", configuration.packageArguments))
        }
    }

    private func appendActionArguments(_ command: String, _ arguments: String) -> String {
        let extra = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        return extra.isEmpty ? command : command + " " + extra
    }

    /// "Additional make flags" belong on the make command line.
    ///
    /// They used to be exported as CROSSBUILD_THEOS_MAKE_FLAGS, a name nothing in
    /// the app or in the guest reads, so typing `messages=yes` there did nothing
    /// at all.
    private func applyingMakeFlags(_ command: String) -> String {
        let flags = compilerConfiguration.theosMakeFlags.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flags.isEmpty, command.hasPrefix("make") else { return command }
        return command + " " + flags
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
            beginProgress(label: "Running \(id)", detail: "Embedded engine", stepCount: 1)
            defer { endProgress() }
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
        // Native engines execute through linked libraries. Shell/POSIX work
        // executes inside the embedded ios-linuxkit runtime.
        let mode = "Embedded Runtime"
        return (ExecutionBackendFactory.make(mode: mode, settings: resolvedSettings), mode)
    }

    /// Tools found in the guest, and whether the probe has run.
    @Published private(set) var guestToolchain: [String] = []
    private var didProbeGuestToolchain = false

    /// Asks the guest which build tools it actually has.
    ///
    /// The shipped rootfs is deliberately runtime-only -- CI fails the build if a
    /// compiler or build system appears in it -- so "does the guest have make"
    /// has a real answer, and it is not the one the build buttons assume. Without
    /// this the first sign is `make: not found` scrolling past in a console the
    /// user may not be looking at.
    func probeGuestToolchain() async {
        guard !didProbeGuestToolchain else { return }
        didProbeGuestToolchain = true
        let probe = "for t in make cc gcc c++ g++ cmake ninja python3 git; do "
            + "command -v \"$t\" >/dev/null 2>&1 && printf '%s:yes ' \"$t\" || printf '%s:no ' \"$t\"; done"
        let result = await LinuxGuestSession.shared.run(probe, timeout: 60)
        guard result.code >= 0 else { return }
        let entries = result.output
            .components(separatedBy: .whitespacesAndNewlines)
            .compactMap { token -> (String, Bool)? in
                let parts = token.split(separator: ":")
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), parts[1] == "yes")
            }
        guestToolchain = entries.filter { $0.1 }.map { $0.0 }.sorted()
        let missing = ToolchainRuntimeArchitecture.requiredGuestTools.filter { tool in !guestToolchain.contains(tool) }
        if !missing.isEmpty {
            console += "warning: the Linux guest has no \(missing.joined(separator: " or ")). "
                + "Build actions that need it will fail with 'not found'. The guest rootfs ships no "
                + "compiler stack by design, so the toolchain has to come from the guest itself.\n"
        }
    }

    /// Announces a run. Nested calls are counted: the outermost caller owns the
    /// label and the step count, and the commands it drives cannot clobber them.
    func beginProgress(label: String, detail: String = "", stepCount: Int = 1) {
        progressDepth += 1
        guard progressDepth == 1 else { return }
        runProgress = RunProgress(phase: .running(fraction: stepCount > 1 ? 0 : nil),
                                  label: label,
                                  detail: detail,
                                  step: 0,
                                  stepCount: max(1, stepCount),
                                  startedAt: Date())
    }

    /// Records `step` finished steps. Only the owning workflow (the outermost
    /// caller) may do this, so a nested command cannot move its parent's bar.
    func setProgress(step: Int, detail: String = "") {
        guard progressDepth == 1, runProgress.isRunning else { return }
        var updated = runProgress
        updated.step = max(0, min(step, runProgress.stepCount))
        if !detail.isEmpty { updated.detail = detail }
        updated.phase = .running(fraction: runProgress.stepCount > 1
                                 ? Double(updated.step) / Double(runProgress.stepCount)
                                 : nil)
        runProgress = updated
    }

    func endProgress() {
        progressDepth = max(0, progressDepth - 1)
        guard progressDepth == 0 else { return }
        if runProgress.isRunning {
            lastRun = RunRecord(label: runProgress.label,
                                seconds: runProgress.elapsed,
                                succeeded: (lastExitCode ?? 0) == 0)
        }
        runProgress = RunProgress()
    }

    /// Runs a command through the resolved backend. `timeoutOverride` lets the
    /// build/test/package paths apply the dedicated "Build timeout" setting
    /// instead of the general command timeout; a value of 0 means unlimited.
    @discardableResult
    func executeCommand(_ command: String, settings: AppSettings? = nil, timeoutOverride: Int? = nil) async -> CommandResult {
        guard !isExecuting else {
            let result = CommandResult(exitCode: 75, stdout: "", stderr: "Another command is already running.", duration: 0)
            console += "error: \(result.stderr)\n"
            return result
        }
        let resolvedSettings = settings ?? appSettings
        let resolved = resolvedBackend(settings: resolvedSettings)
        let backend = resolved.backend
        // The guest runs from its own filesystem image, so the iOS container path
        // the workspace lives at is not a directory inside it. Only an explicit
        // working-directory override is handed to the guest (which reports it when
        // the path is not there); the default stays the guest's HOME. Sending the
        // old default was misleading in both directions: the override looked like
        // it worked, and the guest looked like it had been given a directory.
        let workingDirectoryOverride = configuration.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDirectory: String? = workingDirectoryOverride.isEmpty ? nil : workingDirectoryOverride
        let startedAt = Date()
        if resolvedSettings?.timestampBuildOutput == true {
            console += "[\(Self.timestampFormatter.string(from: startedAt))] $ \(command)\nBackend: \(backend.name)\n"
        } else {
            console += "$ \(command)\nBackend: \(backend.name)\n"
        }
        isExecuting = true
        executionStatus = "Running"
        // Indeterminate, unless a workflow above us announced its own steps.
        beginProgress(label: "Running command", detail: command)
        defer { endProgress() }
        var environment = resolvedSettings?.forwardEnvironment == false ? [:] : commandEnvironment()
        // Commands run inside ios-linuxkit, so never inject host/jailbreak paths
        // that cannot exist in the guest namespace.
        environment["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if resolvedSettings?.captureEnvironment == true && !environment.isEmpty {
            let summary = environment.keys.sorted().joined(separator: ", ")
            console += "env: \(summary)\n"
        }
        let configuredShell = resolvedSettings?.shellPath.trimmingCharacters(in: .whitespacesAndNewlines) ?? "/bin/sh"
        let request = CommandRequest(
            command: command,
            workingDirectory: workingDirectory,
            environment: environment,
            shell: configuredShell.isEmpty ? "/bin/sh" : configuredShell,
            loginShell: resolvedSettings?.shellLogin ?? false,
            interactiveShell: resolvedSettings?.shellInteractive ?? false,
            initCommand: resolvedSettings?.shellInitCommand.trimmingCharacters(in: .whitespacesAndNewlines),
            timeout: timeoutOverride ?? resolvedSettings?.commandTimeout ?? 0,
            persistentSession: resolvedSettings?.terminalPersistentSession ?? true
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

    // MARK: - Option field parsing

    /// Splits a free-text option field the way its help text promises: one entry
    /// per line, or comma separated. `#` starts a comment and blank entries are
    /// dropped. Space separates only the fields whose entries cannot contain one
    /// (define, undefine and library names) -- never paths, which often do.
    private func optionTokens(_ text: String, spaceSeparated: Bool) -> [String] {
        text.components(separatedBy: .newlines)
            .flatMap { $0.components(separatedBy: ",") }
            .map { line -> String in
                guard let hash = line.firstIndex(of: "#") else { return line }
                return String(line[..<hash])
            }
            .flatMap { piece -> [String] in
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return [] }
                guard spaceSeparated else { return [trimmed] }
                return trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            }
    }

    /// Accepts the flag as well as the bare value. These fields are labelled with
    /// the flag they add, so people type it; prepending it blindly produced
    /// `-I-I/usr/include` and `-l-lm`.
    private func strippingOptionPrefix(_ token: String, prefixes: [String]) -> String {
        for prefix in prefixes where token.hasPrefix(prefix) {
            let rest = token.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return token
    }

    /// A path ends up in CFLAGS/LDFLAGS, which the build tool word-splits again,
    /// so one containing a space has to be quoted or it arrives as two flags.
    private func quotedOptionValue(_ value: String) -> String {
        value.contains(" ") ? "\"\(value)\"" : value
    }

    /// A shell variable name: letters, digits and underscores, not leading digit.
    private static func isValidEnvironmentKey(_ key: String) -> Bool {
        guard let first = key.first, first.isLetter || first == "_" else { return false }
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private func commandEnvironment() -> [String: String] {
        var environment: [String: String] = [:]
        for source in [configuration.environmentVariables, compilerConfiguration.environment] {
            for rawLine in source.components(separatedBy: .newlines) {
                var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                // People paste shell assignments, so accept the shell's spelling
                // rather than turning it into a variable named "export FOO".
                if line.hasPrefix("export ") {
                    line = String(line.dropFirst("export ".count))
                }
                guard let separator = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { continue }
                guard Self.isValidEnvironmentKey(key) else {
                    // Dropping this silently is what made "export FOO=bar" look
                    // like it had been set. Say it once per key, not per command.
                    if reportedEnvironmentKeys.insert(key).inserted {
                        console += "Environment: \(key) is not a shell variable name, so it was not set.\n"
                    }
                    continue
                }
                environment[key] = value
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
        // CXXFLAGS is assembled below from the same flags; make's implicit C++
        // rule reads $(CXXFLAGS), not $(CFLAGS).
        if compilerConfiguration.positionIndependentCode { cFlags.append("-fPIC") }
        if compilerConfiguration.clangModules { cFlags.append("-fmodules") }
        if !compilerConfiguration.objcARC { cFlags.append("-fno-objc-arc") }
        if compilerConfiguration.linkTimeOptimization { cFlags.append("-flto") }
        if compilerConfiguration.bitcode { cFlags.append("-fembed-bitcode") }
        if compilerConfiguration.reproducibleBuild {
            // The override is usually empty, and an empty prefix produced the
            // malformed `-ffile-prefix-map=.= .`. Fall back to the project root.
            let override = configuration.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            let mapRoot = override.isEmpty ? (activeProjectRoot ?? files.workspaceRoot.path) : override
            cFlags.append(contentsOf: ["-Xclang", "-fdebug-compilation-dir=.", "-ffile-prefix-map=\(mapRoot)=."])
        }
        let minimumOS = compilerConfiguration.minimumOS.trimmingCharacters(in: .whitespacesAndNewlines)
        if !minimumOS.isEmpty { cFlags.append("-mios-version-min=\(minimumOS)") }
        // Define names cannot contain a space, so this field keeps the
        // space-separated spelling. The flag prefix is now accepted instead of
        // doubled, comments are honoured, and entries are trimmed -- a stray \r
        // from the keyboard used to end up inside the flag.
        let defines = optionTokens(compilerConfiguration.defines, spaceSeparated: true)
            .map { strippingOptionPrefix($0, prefixes: ["-D"]) }
        cFlags.append(contentsOf: defines.map { "-D\($0)" })
        // Paths may contain spaces, so these are one per line (or comma separated)
        // and are quoted on the way into CFLAGS, which gets word-split again.
        let includes = optionTokens(compilerConfiguration.includePaths, spaceSeparated: false)
            .map { strippingOptionPrefix($0, prefixes: ["-I"]) }
        cFlags.append(contentsOf: includes.map { "-I\(quotedOptionValue($0))" })
        let systemIncludes = optionTokens(compilerConfiguration.systemIncludePaths, spaceSeparated: false)
            .map { strippingOptionPrefix($0, prefixes: ["-isystem", "-I"]) }
        cFlags.append(contentsOf: systemIncludes.map { "-isystem \(quotedOptionValue($0))" })
        let undefines = optionTokens(compilerConfiguration.undefines, spaceSeparated: true)
            .map { strippingOptionPrefix($0, prefixes: ["-U"]) }
        cFlags.append(contentsOf: undefines.map { "-U\($0)" })
        switch compilerConfiguration.optimization {
        case "Release": cFlags.append("-O2")
        case "Size": cFlags.append("-Oz")
        default: cFlags.append("-O0")
        }
        if compilerConfiguration.debugSymbols { cFlags.append("-g") }
        if !cFlags.isEmpty { environment["CFLAGS"] = cFlags.joined(separator: " ") }
        // make's implicit C++ rule uses $(CXXFLAGS), not $(CFLAGS), so every
        // option accumulated above was invisible to .cpp/.mm sources.
        var cxxFlags = cFlags
        if compilerConfiguration.cppStandard != "Default" {
            cxxFlags.append("-std=\(compilerConfiguration.cppStandard)")
        }
        if !cxxFlags.isEmpty { environment["CXXFLAGS"] = cxxFlags.joined(separator: " ") }

        var ldFlags: [String] = []
        let explicitLinker = compilerConfiguration.linkerFlags.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicitLinker.isEmpty { ldFlags.append(explicitLinker) }
        let libraryPaths = optionTokens(compilerConfiguration.libraryPaths, spaceSeparated: false)
            .map { strippingOptionPrefix($0, prefixes: ["-L"]) }
        ldFlags.append(contentsOf: libraryPaths.map { "-L\(quotedOptionValue($0))" })
        let frameworkPaths = optionTokens(compilerConfiguration.frameworkSearchPaths, spaceSeparated: false)
            .map { strippingOptionPrefix($0, prefixes: ["-F"]) }
        ldFlags.append(contentsOf: frameworkPaths.map { "-F\(quotedOptionValue($0))" })
        // "lib" as well as "-l": the field is labelled "-lname" and people write
        // both, and a leading "lib" produced "-llibfoo".
        let libraries = optionTokens(compilerConfiguration.libraries, spaceSeparated: true)
            .map { strippingOptionPrefix($0, prefixes: ["-l", "lib"]) }
        ldFlags.append(contentsOf: libraries.map { "-l\($0)" })
        let frameworks = optionTokens(compilerConfiguration.frameworks, spaceSeparated: false)
            .map { strippingOptionPrefix($0, prefixes: ["-framework"]) }
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
            let result = await executeCommand(command, settings: resolved)
            if result.succeeded, command.trimmingCharacters(in: .whitespacesAndNewlines) == "clear" {
                console = ""
            }
        }
    }

    /// Runs a clean/test command as part of the build workflow.
    ///
    /// These used `runCommand`, which applies the *command* timeout while Build
    /// applies the *build* timeout -- so "Build timeout" silently governed only
    /// one of the four buttons on the same row. They deliberately do not get the
    /// build argument transforms (parallel jobs, verbose flags): those describe a
    /// compilation, not a clean or a test run.
    func runWorkflowCommand(_ command: String, settings: AppSettings? = nil) {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            console += "error: No command is configured for this action.\n"
            return
        }
        let resolved = settings ?? appSettings
        Task { _ = await executeCommand(command, settings: resolved, timeoutOverride: resolvedBuildTimeout(resolved)) }
    }

    func runCommand(_ command: String, settings: AppSettings? = nil) {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            console += "error: No command is configured for this action.\n"
            return
        }
        Task { _ = await executeCommand(command, settings: settings) }
    }

    // MARK: - Building individual items

    let guestSync = GuestWorkspaceSync()

    /// Something that can be built on its own rather than as part of the project.
    struct IndividualBuildItem: Identifiable {
        enum Kind { case file(String), makeTarget(String) }
        let id = UUID()
        let kind: Kind
        let title: String
        let detail: String
    }

    /// The path of `path` relative to the active project root.
    func relativePath(_ path: String) -> String {
        let root = activeProjectRoot ?? files.workspaceRoot.path
        guard path.hasPrefix(root + "/") else { return (path as NSString).lastPathComponent }
        return String(path.dropFirst(root.count + 1))
    }

    /// Source files under the active project that a compiler can take on their own.
    func individualSourceFiles() -> [WorkspaceFile] {
        let root = activeProjectRoot ?? files.workspaceRoot.path
        let buildable: Set<String> = ["c", "cc", "cpp", "cxx", "m", "mm", "swift", "rs", "go", "zig", "py", "js", "ts"]
        return files.flattened.filter { file in
            guard !file.isDirectory,
                  file.path.hasPrefix(root + "/"),
                  buildable.contains((file.name as NSString).pathExtension.lowercased())
            else { return false }
            return true
        }
    }

    /// Everything that could be built individually: the open file first, then the
    /// project's own sources, then the make targets the project declares.
    func individualBuildItems(limit: Int = 12) -> [IndividualBuildItem] {
        var items: [IndividualBuildItem] = []
        var seen = Set<String>()

        func addFile(_ relative: String, _ title: String) {
            guard seen.insert(relative).inserted else { return }
            items.append(.init(kind: .file(relative), title: title, detail: "Compile this file on its own"))
        }

        if let document = editor.selected {
            addFile(relativePath(document.path), document.name)
        }
        for file in individualSourceFiles().prefix(limit) {
            addFile(relativePath(file.path), file.name)
        }
        for target in makefileTargets().prefix(limit) {
            guard seen.insert("make:\(target)").inserted else { continue }
            items.append(.init(kind: .makeTarget(target),
                               title: "make \(target)",
                               detail: "Target declared in the project's Makefile"))
        }
        return items
    }

    /// Targets declared in the project's Makefile.
    ///
    /// Deliberately shallow: a `name:` at the start of a line, skipping recipe
    /// lines, comments, `.PHONY`-style specials, pattern rules and variable
    /// assignments (`:=`, `::=`). Guessing deeper than that produces targets that
    /// do not exist.
    func makefileTargets() -> [String] {
        let root = activeProjectRoot ?? files.workspaceRoot.path
        let names = ["Makefile", "makefile", "GNUmakefile"]
        guard let makefile = files.flattened.first(where: { file in
            names.contains(file.name) && file.path.hasPrefix(root + "/")
        }), let text = files.contents(of: makefile, encoding: editorEncoding) else { return [] }

        var seen = Set<String>()
        var targets: [String] = []
        for line in text.components(separatedBy: .newlines) {
            guard !line.hasPrefix("\t"), !line.hasPrefix("#") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.hasPrefix(".") else { continue }
            let rest = line[line.index(after: colon)...]
            guard !rest.hasPrefix("="), !rest.hasPrefix(":=") else { continue }
            guard name.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_./-]*$"#, options: .regularExpression) != nil else { continue }
            guard seen.insert(name).inserted else { continue }
            targets.append(name)
        }
        return targets
    }

    /// The command that builds one file on its own.
    ///
    /// The project build gets its flags from CFLAGS/LDFLAGS in the environment,
    /// which only make ever reads -- a direct compiler invocation would get none
    /// of them. So the same flags are placed on this command line, which is what
    /// makes an individual build equivalent to the one make would have run.
    func singleFileBuildCommand(for relativePath: String) -> String? {
        guard !relativePath.isEmpty else { return nil }
        let flags = (commandEnvironment()["CFLAGS"] ?? "").trimmingCharacters(in: .whitespaces)
        let path = GuestWorkspaceSync.guestRoot + "/" + relativePath
        let stem = (relativePath as NSString).lastPathComponent
        let object = "/tmp/crossbuild-\(stem).o"
        let quote = GuestWorkspaceSync.quoted
        let extra = flags.isEmpty ? "" : " " + flags

        // `cc`/`c++` rather than `clang`: the guest carries the GNU toolchain, and
        // these are the names that resolve to a real compiler there. Asking for
        // clang was one more way for a build to fail with `not found`.
        switch (relativePath as NSString).pathExtension.lowercased() {
        case "c": return "cc\(extra) -c \(quote(path)) -o \(quote(object))"
        case "m": return "cc\(extra) -c \(quote(path)) -o \(quote(object))"
        case "cc", "cpp", "cxx", "mm": return "c++\(extra) -c \(quote(path)) -o \(quote(object))"
        case "h", "hpp", "hh": return "cc\(extra) -fsyntax-only \(quote(path))"
        case "swift": return "swiftc -typecheck \(quote(path))"
        case "rs": return "rustc --emit=obj \(quote(path)) -o \(quote(object))"
        case "go": return "go vet \(quote(path))"
        case "zig": return "zig build-obj \(quote(path)) -femit-bin=\(quote(object))"
        case "py": return "python3 -m py_compile \(quote(path))"
        case "js", "ts": return "node --check \(quote(path))"
        default: return nil
        }
    }

    /// Every non-hidden file under `root`, ready to be copied into the guest.
    func projectSyncItems(under root: String) -> [GuestWorkspaceSync.Item] {
        files.flattened.compactMap { file in
            guard !file.isDirectory,
                  file.path.hasPrefix(root + "/"),
                  !file.name.hasPrefix("."),
                  !file.path.contains("/.git/"),
                  let text = files.contents(of: file, encoding: editorEncoding)
            else { return nil }
            return .init(relativePath: relativePath(file.path), data: Data(text.utf8))
        }
    }

    /// Builds one item instead of the whole project.
    ///
    /// Two steps, and the first is the part that was missing entirely: the guest
    /// boots from its own filesystem image, so the item has to be copied into it
    /// before anything in there can compile it.
    func buildIndividual(_ item: IndividualBuildItem, settings: AppSettings? = nil) {
        let resolved = settings ?? appSettings
        guard !isExecuting else {
            console += "error: Another command is already running.\n"
            return
        }
        let root = activeProjectRoot ?? files.workspaceRoot.path

        Task {
            beginProgress(label: "Build \(item.title)", detail: "Copying into the guest", stepCount: 2)
            defer { endProgress() }
            await probeGuestToolchain()

            // Push what the item needs: the one file for a file build, the whole
            // project for a target, whose recipe may touch anything in the tree.
            let items: [GuestWorkspaceSync.Item]
            switch item.kind {
            case .file(let relative):
                guard let file = files.flattened.first(where: { relativePath($0.path) == relative }),
                      let text = files.contents(of: file, encoding: editorEncoding) else {
                    console += "error: \(relative) could not be read.\n"
                    return
                }
                items = [.init(relativePath: relative, data: Data(text.utf8))]
            case .makeTarget:
                items = projectSyncItems(under: root)
            }

            let synced = await guestSync.push(items, session: .shared)
            if !synced.output.isEmpty { console += synced.output }
            console += "Guest sync: \(guestSync.lastSummary)\n"
            guard synced.pushed > 0 else {
                console += "error: nothing reached the guest, so there is nothing to build.\n"
                return
            }

            let command: String
            switch item.kind {
            case .file(let relative):
                guard let built = singleFileBuildCommand(for: relative) else {
                    console += "error: Cross Build has no single-file build for \(relative). Use the project build.\n"
                    return
                }
                command = "cd \(GuestWorkspaceSync.quoted(GuestWorkspaceSync.guestRoot)) && \(built)"
            case .makeTarget(let target):
                let flags = compilerConfiguration.theosMakeFlags.trimmingCharacters(in: .whitespacesAndNewlines)
                command = "cd \(GuestWorkspaceSync.quoted(GuestWorkspaceSync.guestRoot)) && make \(target)"
                    + (flags.isEmpty ? "" : " " + flags)
            }

            guard guestToolchain.contains("cc") || guestToolchain.contains("gcc") else {
                console += "error: the guest has no C compiler, so \(relativePath) cannot be compiled.\n"
                return
            }

            setProgress(step: 1, detail: command)
            let started = Date()
            let result = await executeCommand(command, settings: resolved, timeoutOverride: resolvedBuildTimeout(resolved))
            if case .file(let relative) = item.kind {
                individualResults[relative] = RunRecord(label: item.title,
                                                        seconds: Date().timeIntervalSince(started),
                                                        succeeded: result.succeeded)
            }
            setProgress(step: 2)
        }
    }

    /// Compiles every source file in the project, one after another.
    ///
    /// The guest is synchronised once for the whole run rather than per file: the
    /// copy is the slow part, and doing it repeatedly is what would make a
    /// per-file sweep pointless.
    func compileAllIndividualSources(settings: AppSettings? = nil) {
        let resolved = settings ?? appSettings
        guard !isExecuting else {
            console += "error: Another command is already running.\n"
            return
        }
        let sources = individualSourceFiles().map { relativePath($0.path) }
        guard !sources.isEmpty else {
            console += "No source files found in the active project.\n"
            return
        }
        let root = activeProjectRoot ?? files.workspaceRoot.path

        Task {
            beginProgress(label: "Compile \(sources.count) source(s)", detail: "Copying into the guest", stepCount: sources.count + 1)
            defer { endProgress() }

            let synced = await guestSync.push(projectSyncItems(under: root), session: .shared)
            if !synced.output.isEmpty { console += synced.output }
            console += "Guest sync: \(guestSync.lastSummary)\n"
            guard synced.pushed > 0 else {
                console += "error: nothing reached the guest, so there is nothing to compile.\n"
                return
            }
            setProgress(step: 1, detail: "Guest synchronised")

            guard guestToolchain.contains("cc") || guestToolchain.contains("gcc") else {
                console += "error: the guest has no C compiler, so there is nothing to compile with.\n"
                return
            }

            for (index, relative) in sources.enumerated() {
                guard let built = singleFileBuildCommand(for: relative) else {
                    console += "skipped \(relative): no single-file compile for that language.\n"
                    setProgress(step: index + 2, detail: "Skipped \(relative)")
                    continue
                }
                setProgress(step: index + 2, detail: relative)
                let started = Date()
                let result = await executeCommand("cd \(GuestWorkspaceSync.quoted(GuestWorkspaceSync.guestRoot)) && \(built)",
                                                   settings: resolved,
                                                   timeoutOverride: resolvedBuildTimeout(resolved))
                individualResults[relative] = RunRecord(label: relative,
                                                        seconds: Date().timeIntervalSince(started),
                                                        succeeded: result.succeeded)
            }
            setProgress(step: sources.count + 1)
            let failed = individualResults.filter { !$0.value.succeeded }.count
            console += "Individual compile finished: \(sources.count - failed) ok, \(failed) failed.\n"
        }
    }

    /// Copies the project into the guest, explicitly.
    func syncWorkspaceToGuest(settings: AppSettings? = nil) {
        let root = activeProjectRoot ?? files.workspaceRoot.path
        Task {
            beginProgress(label: "Sync to guest", detail: "Copying project files", stepCount: 1)
            defer { endProgress() }
            let result = await guestSync.push(projectSyncItems(under: root), session: .shared)
            if !result.output.isEmpty { console += result.output }
            console += "Guest sync: \(guestSync.lastSummary)\n"
            setProgress(step: 1)
        }
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

        // Packaging is the package command plus, when an artifact directory is
        // configured, the copy that follows it.
        let stepCount = artifactDir.isEmpty ? 1 : 2
        beginProgress(label: "Package", detail: command, stepCount: stepCount)
        defer { endProgress() }

        let beforePaths: Set<String> = artifactDir.isEmpty
            ? []
            : await Self.snapshotFilesOffMain(under: root)

        let result = await executeCommand(command, settings: resolved, timeoutOverride: resolvedBuildTimeout(resolved))
        setProgress(step: 1, detail: "Collecting artifacts")

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

    /// Opens one file in the editor.
    ///
    /// The previous version returned silently when the file could not be decoded,
    /// so an unreadable file and a tap the app never received were the same
    /// thing to the user: nothing happened.
    func openFile(_ file: WorkspaceFile) {
        guard !file.isDirectory else { return }
        guard let text = files.contents(of: file, encoding: editorEncoding) else {
            console += "error: \(file.name) could not be read as \(configuration.defaultEncoding), so it was not opened.\n"
            files.errorMessage = "\(file.name) could not be read as \(configuration.defaultEncoding)."
            return
        }
        editor.open(file: file, text: text)
        editorText = editor.selected?.text ?? text
        persistOpenDocuments()
    }

    func openSelectedFile() {
        guard let file = files.selected else { return }
        openFile(file)
    }

    /// Makes a folder the project root.
    ///
    /// Detection already took a root override; nothing in the UI could supply
    /// one, so a repository checked out inside a larger workspace could only be
    /// built by moving it.
    func useFolderAsActiveProject(_ folder: WorkspaceFile) {
        guard folder.isDirectory else { return }
        detectProject(at: folder.path)
        console += "Active project: \(relativePath(folder.path))/\n"
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
        case .resolveDependencies:
            guard settings?.allowAgentDependencies == true else {
                console += "Agent dependency changes blocked by permissions.\n"
                return .noCommand
            }
            guard let ecosystem = DependencyManager.detected(in: projectFiles).first else {
                let manifests = DependencyManager.ecosystems.map(\.manifest).joined(separator: ", ")
                console += "No dependency manifest found. Looked for: \(manifests).\n"
                return .noCommand
            }
            console += "Dependencies: \(ecosystem.name) (\(ecosystem.manifest))\n"
            let result = await executeCommand(ecosystem.resolveCommand, settings: settings, timeoutOverride: resolvedBuildTimeout(settings))
            return .command(succeeded: result.succeeded)
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
            beginProgress(label: "Agent plan", detail: plan.first?.summary ?? "", stepCount: plan.count)
            defer { endProgress() }
            for (index, execution) in plan.enumerated() {
                setProgress(step: index, detail: execution.summary)
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
        case .runCompiler, .clean, .test, .package, .resolveDependencies:
            return true
        default:
            return false
        }
    }
}
