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
    @Published var tasks: [AgentTask] = [
        .init(title: "Repair failed builds", instruction: "Inspect diagnostics, patch safe compiler errors, and rebuild."),
        .init(title: "Build & Package", instruction: "Detect the toolchain, resolve dependencies, build, test, and package the artifact.")
    ]

    func detectSampleProject() {
        selectedToolchain = ToolchainRegistry.detect(fileNames: ["Makefile", "control", "Tweak.xm"])
        console += "Detected: \(selectedToolchain.rawValue)\n"
    }

    func runBuild() {
        let provider = ToolchainRegistry.providers.first { $0.kind == selectedToolchain }
        console += "$ \(provider?.buildCommands.first ?? "build")\nBuild queued through \(selectedToolchain.rawValue).\n"
    }

    func runAgent() {
        let request = agentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        console += "Agent task: \(request)\nPlan: inspect → detect → execute → diagnose → verify → artifact\n"
        agentPrompt = ""
    }
}
