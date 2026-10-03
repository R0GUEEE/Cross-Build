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

    static func detect(fileNames: [String]) -> ToolchainKind {
        if fileNames.contains("control") && fileNames.contains("Makefile") { return .theos }
        for provider in providers {
            if provider.markers.contains(where: { marker in
                marker.hasPrefix(".") ? fileNames.contains(where: { $0.hasSuffix(marker) }) : fileNames.contains(marker)
            }) { return provider.kind }
        }
        return .custom
    }
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
    @Published var console = "Ready. Toolchain auto-detection enabled.\n"
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
        let markers: Set<String> = [
            "project.yml", "Package.swift", "Cargo.toml", "go.mod", "build.zig",
            "CMakeLists.txt", "meson.build", "package.json", "pyproject.toml",
            "setup.py", "build.gradle", "build.gradle.kts", "Makefile", "control"
        ]
        let candidates = Set(files.compactMap { file -> String? in
            guard markers.contains(file.name) else { return nil }
            return URL(fileURLWithPath: file.path).deletingLastPathComponent().path
        })

        if let selectedPath = filesServiceSelectedPath(),
           let contextual = candidates
            .filter({ selectedPath == $0 || selectedPath.hasPrefix($0 + "/") })
            .sorted(by: { $0.count > $1.count })
            .first {
            return contextual
        }

        if let candidate = candidates.sorted(by: {
            let leftDepth = $0.split(separator: "/").count
            let rightDepth = $1.split(separator: "/").count
            return leftDepth == rightDepth ? $0.localizedStandardCompare($1) == .orderedAscending : leftDepth < rightDepth
        }).first {
            return candidate
        }
        return self.files.workspaceRoot.path
    }

    private func filesServiceSelectedPath() -> String? {
        files.selected?.path
    }
    @Published var tasks: [AgentTask] = [
        .init(title: "Repair failed builds", instruction: "Inspect diagnostics, patch safe compiler errors, and rebuild."),
        .init(title: "Build & Package", instruction: "Detect the toolchain, resolve dependencies, build, test, and package the artifact.")
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
        configuration.workingDirectory = root
        let scopedFiles = allFiles.filter { $0.path == root || $0.path.hasPrefix(root + "/") }
        let projectPaths = scopedFiles.map(\.path)
        var contents: [String:String] = [:]
        for file in scopedFiles {
            if ["project.yml","Makefile","control","Package.swift","Cargo.toml","go.mod","build.zig","CMakeLists.txt","meson.build","package.json","pyproject.toml","setup.py","build.gradle","build.gradle.kts"].contains(file.name),
               let text = files.contents(of: file) { contents[file.name] = text }
        }
        let result = ProjectDetector.analyze(paths: projectPaths, fileContents: contents)
        analysis = result
        selectedToolchain = result.primaryToolchain
        let generated = ConfigurationGenerator.generate(from: result, files: scopedFiles, fileContents: contents)
        ConfigurationGenerator.apply(generated, workspace: self)
        generatedConfigurationSummary = generated.summary
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
            }

            if resolved?.cleanBeforeBuild == true {
                let cleaned = await executeCommand(cleanCommand(), settings: resolved)
                guard cleaned.succeeded else { return }
            }

            let command = configuredBuildCommand(settings: resolved)
            _ = await executeCommand(command, settings: resolved)
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
        return command
    }

    func buildCommand() -> String {
        if let custom = activeCompiler, !custom.buildCommand.isEmpty { return custom.buildCommand }
        if let recommendedBuildCommand, !recommendedBuildCommand.isEmpty { return recommendedBuildCommand }
        return ToolchainRegistry.providers.first { $0.kind == selectedToolchain }?.buildCommands.first ?? "make"
    }

    func cleanCommand() -> String {
        if let custom = activeCompiler, !custom.cleanCommand.isEmpty { return custom.cleanCommand }
        switch selectedToolchain {
        case .theos, .custom, .clang: return "make clean"
        case .swift: return "swift package clean"
        case .rust: return "cargo clean"
        case .go: return "go clean"
        case .zig: return "rm -rf .zig-cache zig-cache zig-out"
        case .python: return "find . -name __pycache__ -type d -prune -exec rm -rf {} +"
        case .javascript: return "npm run clean"
        }
    }

    func testCommand() -> String {
        if let custom = activeCompiler, !custom.testCommand.isEmpty { return custom.testCommand }
        switch selectedToolchain {
        case .theos: return "make"
        case .swift: return "swift test"
        case .rust: return "cargo test"
        case .go: return "go test ./..."
        case .zig: return "zig build test"
        case .python: return "python3 -m unittest"
        case .javascript: return "npm test"
        case .clang, .custom: return "make test"
        }
    }

    func packageCommand() -> String {
        if let custom = activeCompiler, !custom.packageCommand.isEmpty { return custom.packageCommand }
        switch selectedToolchain {
        case .theos: return "make package"
        case .swift: return "swift build -c release"
        case .rust: return "cargo build --release"
        case .go: return "go build -trimpath ./..."
        case .zig: return "zig build -Doptimize=ReleaseSafe"
        case .python: return "python3 -m build"
        case .javascript: return "npm pack"
        case .clang, .custom: return "make package"
        }
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

    @discardableResult
    func executeCommand(_ command: String, settings: AppSettings? = nil) async -> CommandResult {
        guard !isExecuting else {
            let result = CommandResult(exitCode: 75, stdout: "", stderr: "Another command is already running.", duration: 0)
            console += "error: \(result.stderr)\n"
            return result
        }
        let resolvedSettings = settings ?? appSettings
        let mode = resolvedSettings?.executionBackend ?? "Sideload / Embedded"
        let host = resolvedSettings?.remoteHost ?? ""
        let port = resolvedSettings?.remotePort ?? 22
        let backend = ExecutionBackendFactory.make(mode: mode, host: host, port: port)
        let workingDirectory = configuration.workingDirectory.isEmpty ? (activeProjectRoot ?? files.workspaceRoot.path) : configuration.workingDirectory
        console += "$ \(command)\nBackend: \(backend.name)\n"
        isExecuting = true
        executionStatus = "Running"
        let result = await backend.execute(.init(command: command, workingDirectory: workingDirectory))
        if !result.stdout.isEmpty { console += result.stdout + "\n" }
        if !result.stderr.isEmpty { console += "error: " + result.stderr + "\n" }
        lastExitCode = result.exitCode
        executionStatus = result.succeeded ? "Succeeded" : "Failed (\(result.exitCode))"
        isExecuting = false
        return result
    }

    func runCommand(_ command: String, settings: AppSettings? = nil) {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            console += "error: No command is configured for this action.\n"
            return
        }
        Task { _ = await executeCommand(command, settings: settings) }
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

    func executeAgentAction(_ execution: AgentExecution) async {
        let settings = appSettings
        agentActivity.append(execution.summary)
        console += "Agent → \(execution.summary)\n"

        switch execution.action {
        case .replaceEditor(let text):
            guard settings?.allowAgentEdits != false else {
                console += "Agent edit blocked by permissions.\n"
                return
            }
            updateEditorText(text)
        case .appendEditor(let text):
            guard settings?.allowAgentEdits != false else {
                console += "Agent edit blocked by permissions.\n"
                return
            }
            updateEditorText(editorText + text)
        case .selectToolchain(let kind):
            selectedToolchain = kind
            selectedCustomCompilerID = nil
        case .runCompiler(let command):
            guard settings?.allowAgentBuilds != false else {
                console += "Agent build blocked by permissions.\n"
                return
            }
            _ = await executeCommand(command, settings: settings)
        case .clean:
            guard settings?.allowAgentBuilds != false else {
                console += "Agent clean blocked by permissions.\n"
                return
            }
            _ = await executeCommand(cleanCommand(), settings: settings)
        case .test:
            guard settings?.allowAgentBuilds != false else {
                console += "Agent test blocked by permissions.\n"
                return
            }
            _ = await executeCommand(testCommand(), settings: settings)
        case .package:
            guard settings?.allowAgentBuilds != false else {
                console += "Agent package blocked by permissions.\n"
                return
            }
            _ = await executeCommand(packageCommand(), settings: settings)
        case .inspectDiagnostics:
            let lines = console.split(separator: "\n")
                .filter { $0.localizedCaseInsensitiveContains("error") || $0.localizedCaseInsensitiveContains("warning") }
                .suffix(20)
            if lines.isEmpty { console += "Diagnostics: no errors or warnings captured.\n" }
            else { console += "Diagnostics snapshot:\n" + lines.joined(separator: "\n") + "\n" }
        }
    }

    func runAgent() {
        let request = agentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        guard !isExecuting else {
            console += "Agent is waiting for the active command to finish.\n"
            return
        }

        console += "Agent task: \(request)\n"
        let lower = request.lowercased()
        if analysis == nil || lower.contains("detect") || lower.contains("configure") {
            detectSampleProject()
        }
        let plan = AgentController.plan(request, workspace: self)
        agentPrompt = ""

        if appSettings?.confirmAgentCommands == true && plan.contains(where: agentActionRunsCommand) {
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

    private func executeAgentPlan(_ plan: [AgentExecution]) {
        guard !plan.isEmpty else { return }
        Task {
            for execution in plan {
                await executeAgentAction(execution)
            }
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
