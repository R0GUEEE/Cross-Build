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
        default: return toolchain.rawValue.lowercased()
        }
    }

    @discardableResult
    func executeCommand(_ command: String, settings: AppSettings? = nil, sessionID: String? = nil) async -> CommandResult {
        guard !isExecuting else {
            let result = CommandResult(exitCode: 75, stdout: "", stderr: "Another command is already running.", duration: 0)
            console += "error: \(result.stderr)\n"
            return result
        }
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
        let backend = ExecutionBackendFactory.make(mode: mode, settings: resolvedSettings)
        let localWorkingDirectory = configuration.workingDirectory.isEmpty ? (activeProjectRoot ?? files.workspaceRoot.path) : configuration.workingDirectory
        let remoteWorkspace = resolvedSettings?.remoteWorkspace.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let workingDirectory = (mode == "Remote / Helper" || mode == "Remote / SSH") && !remoteWorkspace.isEmpty ? remoteWorkspace : localWorkingDirectory
        console += "$ \(command)\nBackend: \(backend.name)\n"
        isExecuting = true
        executionStatus = "Running"
        var environment = resolvedSettings?.forwardEnvironment == false ? [:] : commandEnvironment()
        if environment["PATH"] == nil {
            environment["PATH"] = "/var/jb/usr/bin:/var/jb/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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
            timeout: resolvedSettings?.commandTimeout ?? 0
        )
        let result = await backend.execute(request)
        if !result.stdout.isEmpty { console += result.stdout + "\n" }
        if !result.stderr.isEmpty { console += "error: " + result.stderr + "\n" }
        lastExitCode = result.exitCode
        executionStatus = result.succeeded ? "Succeeded" : "Failed (\(result.exitCode))"
        isExecuting = false
        return result
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
        if !ldFlags.isEmpty { environment["LDFLAGS"] = ldFlags.joined(separator: " ") }

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
                .suffix(max(10, settings?.agentDiagnosticsLimit ?? 40))
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

    private func executeAgentPlan(_ plan: [AgentExecution]) {
        guard !plan.isEmpty else { return }
        Task {
            for execution in plan {
                var attempt = 0
                let maxRetries = appSettings?.agentAutoRetry == true ? max(0, appSettings?.agentMaxRetries ?? 0) : 0
                repeat {
                    await executeAgentAction(execution)
                    if lastExitCode == 0 || !agentActionRunsCommand(execution) { break }
                    attempt += 1
                    if attempt <= maxRetries {
                        agentActivity.append("Retry \(attempt): \(execution.summary)")
                        console += "Agent retry \(attempt)/\(maxRetries): \(execution.summary)\n"
                    }
                } while attempt <= maxRetries

                if agentActionRunsCommand(execution),
                   lastExitCode != nil, lastExitCode != 0,
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
