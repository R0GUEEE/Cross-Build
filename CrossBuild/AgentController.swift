import Foundation

enum AgentCapability: String, CaseIterable {
    case readCode, writeCode, patchCode, selectCompiler, configureCompiler
    case build, clean, test, package, diagnostics, execute
}

enum AgentAction {
    case replaceEditor(String)
    case appendEditor(String)
    case selectToolchain(ToolchainKind)
    case runCompiler(command: String)
    case clean, test, package
    case inspectDiagnostics
}

struct AgentExecution {
    let action: AgentAction
    let summary: String
}

@MainActor
enum AgentController {
    static func plan(_ instruction: String, workspace: WorkspaceModel) -> [AgentExecution] {
        let q = instruction.lowercased()
        var plan: [AgentExecution] = []
        if q.contains("theos") { plan.append(.init(action: .selectToolchain(.theos), summary: "Select Theos / Logos")) }
        else if q.contains("swift") { plan.append(.init(action: .selectToolchain(.swift), summary: "Select Swift / SwiftPM")) }
        else if q.contains("rust") { plan.append(.init(action: .selectToolchain(.rust), summary: "Select Rust / Cargo")) }
        else if q.contains("clang") || q.contains("c++") { plan.append(.init(action: .selectToolchain(.clang), summary: "Select LLVM / Clang")) }

        if q.contains("clean") {
            if workspace.appSettings?.allowAgentDestructiveActions == true {
                plan.append(.init(action: .clean, summary: "Clean build products"))
            }
        }
        if q.contains("test") { plan.append(.init(action: .test, summary: "Run tests")) }
        if q.contains("package") || q.contains("ipa") || q.contains("deb") { plan.append(.init(action: .package, summary: "Package artifact")) }
        if q.contains("diagnostic") || q.contains("error") || q.contains("fix") { plan.append(.init(action: .inspectDiagnostics, summary: "Inspect compiler diagnostics")) }
        if plan.isEmpty, let preferred = workspace.appSettings?.agentPreferredAction.lowercased() {\n            if preferred == "test" { plan.append(.init(action: .test, summary: "Run preferred test action")) }\n            else if preferred == "package" { plan.append(.init(action: .package, summary: "Run preferred package action")) }\n            else if preferred == "diagnose" { plan.append(.init(action: .inspectDiagnostics, summary: "Run preferred diagnostics action")) }\n        }\n        if q.contains("build") || q.contains("compile") || plan.isEmpty {
            let command = workspace.activeCompiler?.buildCommand ??
                ToolchainRegistry.providers.first(where: { $0.kind == workspace.selectedToolchain })?.buildCommands.first ?? "make"
            plan.append(.init(action: .runCompiler(command: command), summary: "Compile using \(workspace.activeCompiler?.name ?? workspace.selectedToolchain.rawValue)"))
        }
        return plan
    }
}

struct CustomCompiler: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var executable: String
    var arguments: String
    var buildCommand: String
    var cleanCommand: String
    var testCommand: String
    var packageCommand: String
    var detectionMarkers: String

    var markers: [String] {
        detectionMarkers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
