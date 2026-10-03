import Foundation

struct GeneratedProjectConfiguration {
    let toolchain: ToolchainKind
    let buildCommand: String
    let deploymentTarget: String
    let architectures: String
    let packageFormat: String
    let theosScheme: String
    let summary: [String]
}

enum ConfigurationGenerator {
    static func generate(from analysis: ProjectAnalysis,
                         files: [WorkspaceFile],
                         fileContents: [String: String] = [:]) -> GeneratedProjectConfiguration {
        let makefile = fileContents["Makefile"] ?? ""
        var deployment = "16.0"
        var architectures = "arm64"
        var format = "binary"
        var scheme = "rootless"
        var notes = ["Detected \(analysis.primaryToolchain.rawValue)"]

        if let value = firstCapture(in: makefile, pattern: #"IPHONEOS_DEPLOYMENT_TARGET\s*[:?+]?=\s*([0-9]+(?:\.[0-9]+)?)"#) ??
            firstCapture(in: makefile, pattern: #"TARGET\s*[:?+]?=.*?:([0-9]+(?:\.[0-9]+)?)"#) {
            deployment = value
            notes.append("Deployment target iOS \(value)")
        }

        if let value = firstCapture(in: makefile, pattern: #"ARCHS\s*[:?+]?=\s*([^\n#]+)"#) {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                architectures = cleaned
                notes.append("Architectures \(cleaned)")
            }
        }

        if analysis.buildSystems.contains(.theos) {
            format = "deb"
            notes.append("Theos packaging enabled")
            if analysis.isRootlessHinted {
                scheme = "rootless"
                notes.append("Rootless scheme detected")
            } else if analysis.isRootfulHinted {
                scheme = "rootful"
                notes.append("Rootful scheme detected")
            } else {
                scheme = "rootless"
                notes.append("Rootless scheme selected as the iOS 16+ default")
            }
        } else if analysis.buildSystems.contains(.xcode) {
            format = "app"
            notes.append("Xcode/XcodeGen application build detected")
        }

        let names = Set(files.map(\.name))
        if names.contains("project.yml") { notes.append("XcodeGen manifest found") }
        if names.contains("Package.swift") { notes.append("SwiftPM manifest found") }
        if names.contains("Cargo.toml") { notes.append("Cargo manifest found") }
        if names.contains("package.json") { notes.append("JavaScript package manifest found") }

        let command = analysis.candidates.first?.command ?? "build"
        return .init(
            toolchain: analysis.primaryToolchain,
            buildCommand: command,
            deploymentTarget: deployment,
            architectures: architectures,
            packageFormat: format,
            theosScheme: scheme,
            summary: notes
        )
    }

    @MainActor
    static func apply(_ generated: GeneratedProjectConfiguration, workspace: WorkspaceModel) {
        workspace.selectedToolchain = generated.toolchain
        workspace.recommendedBuildCommand = generated.buildCommand
        workspace.compilerConfiguration.deploymentTarget = generated.deploymentTarget
        workspace.compilerConfiguration.architectures = generated.architectures
        workspace.compilerConfiguration.packageFormat = generated.packageFormat
        workspace.compilerConfiguration.theosScheme = generated.theosScheme
        workspace.configuration.deploymentTarget = generated.deploymentTarget
        workspace.configuration.architecture = generated.architectures
        workspace.configuration.autoDetectToolchain = true
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }
}
