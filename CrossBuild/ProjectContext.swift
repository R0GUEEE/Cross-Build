import Foundation

struct ProjectContext: Sendable {
    var root: String
    var toolchain: ToolchainKind
    var buildSystem: String
    var target: String
    var sdk: String?
    var architecture: String
    var deploymentTarget: String
    var buildCommand: String
    var packageFormat: String
    var environment: [String:String]
    var artifacts: [String]
    var diagnostics: [BuildDiagnostic]

    @MainActor\n    static func detected(root:String, analysis:ProjectAnalysis, compiler:CompilerConfiguration) -> ProjectContext {
        .init(root:root, toolchain:analysis.primaryToolchain,
              buildSystem:analysis.candidates.first?.system.rawValue ?? "Unknown",
              target:"iOS", sdk:compiler.sdk, architecture:compiler.architectures,
              deploymentTarget:compiler.deploymentTarget,
              buildCommand:analysis.candidates.first?.command ?? "make",
              packageFormat:compiler.packageFormat, environment:[:], artifacts:[], diagnostics:[])
    }
}
