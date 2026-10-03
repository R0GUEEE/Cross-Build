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
    let files = FileManagerService()
    let github = GitHubWorkspaceService()
    let configuration = WorkspaceConfiguration()
    let compilerConfiguration = CompilerConfiguration()
    let editor = EditorSession()
    let embeddedToolchains = EmbeddedToolchainManager()

    var activeCompiler: CustomCompiler? { customCompilers.first { $0.id == selectedCustomCompilerID } }

    init() {
        if let data = UserDefaults.standard.data(forKey: compilersKey),
           let saved = try? JSONDecoder().decode([CustomCompiler].self, from: data) {
            customCompilers = saved
        }
    }

    private func persistCompilers() {
        if let data = try? JSONEncoder().encode(customCompilers) {
            UserDefaults.standard.set(data, forKey: compilersKey)
        }
    }
    @Published var tasks: [AgentTask] = [
        .init(title: "Repair failed builds", instruction: "Inspect diagnostics, patch safe compiler errors, and rebuild."),
        .init(title: "Build & Package", instruction: "Detect the toolchain, resolve dependencies, build, test, and package the artifact.")
    ]

    func detectSampleProject() {
        let projectPaths = files.flattened.map(\.path)
        var contents: [String:String] = [:]
        for file in files.flattened where !file.isDirectory {
            if ["Makefile","control","Package.swift","Cargo.toml","go.mod","build.zig","CMakeLists.txt","meson.build","package.json","pyproject.toml"].contains(file.name),
               let text = files.contents(of: file) { contents[file.name] = text }
        }
        let result = ProjectDetector.analyze(paths: projectPaths, fileContents: contents)
        analysis = result
        selectedToolchain = result.primaryToolchain
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
        let command = activeCompiler?.buildCommand ?? ToolchainRegistry.providers.first { $0.kind == selectedToolchain }?.buildCommands.first ?? "build"
        runCommand(command, settings: settings)
    }

    func runEmbedded(id: String, source: String? = nil) {
        let input = source ?? editorText
        isExecuting = true
        executionStatus = "Running embedded \(id)"
        Task {
            let result = await embeddedToolchains.run(id: id, source: input)
            await MainActor.run {
                if !result.output.isEmpty { console += result.output + "\n" }
                result.diagnostics.forEach { console += "embedded: \($0)\n" }
                lastExitCode = result.succeeded ? 0 : 1
                executionStatus = result.succeeded ? "Succeeded" : "Failed"
                isExecuting = false
            }
        }
    }

    func runCommand(_ command: String, settings: AppSettings? = nil) {
        let mode = settings?.executionBackend ?? "Sideload / Embedded"
        let host = settings?.remoteHost ?? ""
        let port = settings?.remotePort ?? 22
        let backend = ExecutionBackendFactory.make(mode: mode, host: host, port: port)
        console += "$ \(command)\nBackend: \(backend.name)\n"
        isExecuting = true
        executionStatus = "Running"
        Task {
            let result = await backend.execute(.init(command: command, workingDirectory: configuration.workingDirectory.isEmpty ? files.workspaceRoot.path : configuration.workingDirectory))
            await MainActor.run {
                if !result.stdout.isEmpty { console += result.stdout + "\n" }
                if !result.stderr.isEmpty { console += "error: " + result.stderr + "\n" }
                lastExitCode = result.exitCode
                executionStatus = result.succeeded ? "Succeeded" : "Failed (\(result.exitCode))"
                isExecuting = false
            }
        }
    }

    func openSelectedFile() {
        guard let file = files.selected, let text = files.contents(of: file) else { return }
        editor.open(file: file, text: text)
        editorText = text
    }

    func selectDocument(_ id: UUID) {
        editor.selectedID = id
        if let doc = editor.selected { editorText = doc.text }
    }

    func updateEditorText(_ text: String) {
        editorText = text
        editor.updateText(text)
    }

    func saveEditor() {
        guard let doc = editor.selected else { return }
        let file = WorkspaceFile(name: doc.name, path: doc.path)
        do { try files.save(editorText, to: file); editor.markSaved(); console += "Saved \(doc.name)\n" }
        catch { console += "Save failed: \(error.localizedDescription)\n" }
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

    func executeAgentAction(_ execution: AgentExecution) {
        agentActivity.append(execution.summary)
        console += "Agent → \(execution.summary)\n"
        switch execution.action {
        case .replaceEditor(let text): editorText = text
        case .appendEditor(let text): editorText += text
        case .selectToolchain(let kind): selectedToolchain = kind; selectedCustomCompilerID = nil
        case .runCompiler(let command): runCommand(command)
        case .clean: console += "$ \(activeCompiler?.cleanCommand ?? "clean")\n"
        case .test: console += "$ \(activeCompiler?.testCommand ?? "test")\n"
        case .package: console += "$ \(activeCompiler?.packageCommand ?? "package")\n"
        case .inspectDiagnostics: console += "Diagnostics requested by agent.\n"
        }
    }

    func runAgent() {
        let request = agentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        console += "Agent task: \(request)\n"
        let plan = AgentController.plan(request, workspace: self)
        plan.forEach(executeAgentAction)
        agentPrompt = ""
    }
}
