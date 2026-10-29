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
    /// Resolves whatever dependency manifest the project actually has. The
    /// command is chosen when the action runs, from the live file tree, because
    /// which ecosystem applies is a property of the project and not of a string
    /// the planner matched.
    case resolveDependencies
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

        if mentions(["theos", "logos"], in: q) { plan.append(.init(action: .selectToolchain(.theos), summary: "Select Theos / Logos")) }
        else if mentions(["swift"], in: q) { plan.append(.init(action: .selectToolchain(.swift), summary: "Select Swift / SwiftPM")) }
        else if mentions(["rust", "cargo"], in: q) { plan.append(.init(action: .selectToolchain(.rust), summary: "Select Rust / Cargo")) }
        else if mentions(["clang", "c++", "cpp"], in: q) { plan.append(.init(action: .selectToolchain(.clang), summary: "Select LLVM / Clang")) }

        // Emitted in the order the steps have to run, not the order they are
        // written in. "Build and test" used to produce [test, build] -- testing the
        // binary from the previous build -- and "package and build" shipped the old
        // one.
        if mentions(["clean"], in: q) {
            if workspace.appSettings?.allowAgentDestructiveActions == true {
                plan.append(.init(action: .clean, summary: "Clean build products"))
            } else {
                plan.append(.init(action: .inspectDiagnostics, summary: "Clean requested but destructive actions are disabled"))
            }
        }
        if mentions(["dependency", "dependencies", "deps", "install", "resolve", "fetch"], in: q) {
            plan.append(.init(action: .resolveDependencies, summary: "Resolve project dependencies"))
        }

        let wantsBuild = mentions(["build", "compile", "make"], in: q)
        let wantsTest = mentions(["test", "tests"], in: q)
        let wantsPackage = mentions(["package", "ipa", "deb", "artifact"], in: q)

        if wantsBuild || (!wantsTest && !wantsPackage && plan.isEmpty) {
            let command = workspace.activeCompiler?.buildCommand
                ?? ToolchainRegistry.providers.first(where: { $0.kind == workspace.selectedToolchain })?.buildCommands.first
                ?? "make"
            plan.append(.init(action: .runCompiler(command: command),
                              summary: "Compile using \(workspace.activeCompiler?.name ?? workspace.selectedToolchain.rawValue)"))
        }
        if wantsTest { plan.append(.init(action: .test, summary: "Run tests")) }
        if wantsPackage { plan.append(.init(action: .package, summary: "Package artifact")) }
        if mentions(["diagnostic", "diagnostics", "error", "errors", "fix"], in: q) {
            plan.append(.init(action: .inspectDiagnostics, summary: "Inspect compiler diagnostics"))
        }

        if plan.isEmpty, let preferred = workspace.appSettings?.agentPreferredAction.lowercased() {
            if preferred == "test" { plan.append(.init(action: .test, summary: "Run preferred test action")) }
            else if preferred == "package" { plan.append(.init(action: .package, summary: "Run preferred package action")) }
            else if preferred == "diagnose" { plan.append(.init(action: .inspectDiagnostics, summary: "Run preferred diagnostics action")) }
        }
        return plan
    }

    /// Whole-word match: `q.contains("test")` also fired on "latest" and
    /// "fastest", and `contains("build")` on "rebuild" of an unrelated word.
    private static func mentions(_ words: [String], in text: String) -> Bool {
        words.contains { word in
            text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b",
                       options: .regularExpression) != nil
        }
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
