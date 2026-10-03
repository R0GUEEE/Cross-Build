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
    @Published var selectedToolchain: ToolchainKind = .theos
    @Published var editorText = "// Cross Build\n// Open or create a project to begin.\n"
    @Published var console = "Ready. Toolchain auto-detection enabled.\n"
    @Published var agentPrompt = ""
    @Published var analysis: ProjectAnalysis?
    @Published var customCompilers: [CustomCompiler] = []
    @Published var selectedCustomCompilerID: UUID?
    @Published var agentActivity: [String] = []

    var activeCompiler: CustomCompiler? { customCompilers.first { $0.id == selectedCustomCompilerID } }
    @Published var tasks: [AgentTask] = [
        .init(title: "Repair failed builds", instruction: "Inspect diagnostics, patch safe compiler errors, and rebuild."),
        .init(title: "Build & Package", instruction: "Detect the toolchain, resolve dependencies, build, test, and package the artifact.")
    ]

    func detectSampleProject() {
        let makefile = """
        ARCHS = arm64 arm64e
        THEOS_PACKAGE_SCHEME = rootless
        include $(THEOS)/makefiles/common.mk
        TWEAK_NAME = CrossBuildDemo
        include $(THEOS_MAKE_PATH)/tweak.mk
        """
        let result = ProjectDetector.analyze(
            paths: ["Makefile", "control", "CrossBuildDemo.xm"],
            fileContents: ["Makefile": makefile, "control": "Architecture: iphoneos-arm64"]
        )
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

    func runBuild() {
        let provider = ToolchainRegistry.providers.first { $0.kind == selectedToolchain }
        console += "$ \(provider?.buildCommands.first ?? "build")\nBuild queued through \(selectedToolchain.rawValue).\n"
    }

    func addCompiler(_ compiler: CustomCompiler) {
        customCompilers.append(compiler)
        selectedCustomCompilerID = compiler.id
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
        case .runCompiler(let command): console += "$ \(command)\nCompiler execution queued.\n"
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
