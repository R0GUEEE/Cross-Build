import Foundation

struct GeneratedProjectConfiguration {
    let toolchain:ToolchainKind
    let buildCommand:String
    let deploymentTarget:String
    let architectures:String
    let packageFormat:String
    let theosScheme:String
    let summary:[String]
}

enum ConfigurationGenerator {
    static func generate(from analysis:ProjectAnalysis, files:[WorkspaceFile])->GeneratedProjectConfiguration {
        var deployment="16.0"
        var arch="arm64"
        var format="binary"
        var scheme=analysis.isRootlessHinted ? "rootless" : "rootless"
        var notes=["Detected \(analysis.primaryToolchain.rawValue)"]
        if analysis.buildSystems.contains(.theos) {
            format="deb"
            notes.append("Theos packaging enabled")
            if analysis.isRootlessHinted { notes.append("Rootless scheme detected") }
        } else if analysis.buildSystems.contains(.xcode) || analysis.primaryToolchain == .swift {
            format="app"
        }
        let names=files.map(\.name)
        if names.contains("Package.swift") { notes.append("SwiftPM manifest found") }
        if names.contains("Cargo.toml") { notes.append("Cargo manifest found") }
        if names.contains("package.json") { notes.append("JavaScript package manifest found") }
        let command=analysis.candidates.first?.command ?? "build"
        return .init(toolchain:analysis.primaryToolchain,buildCommand:command,deploymentTarget:deployment,architectures:arch,packageFormat:format,theosScheme:scheme,summary:notes)
    }

    @MainActor static func apply(_ generated:GeneratedProjectConfiguration, workspace:WorkspaceModel) {
        workspace.selectedToolchain=generated.toolchain
        workspace.compilerConfiguration.deploymentTarget=generated.deploymentTarget
        workspace.compilerConfiguration.architectures=generated.architectures
        workspace.compilerConfiguration.packageFormat=generated.packageFormat
        workspace.compilerConfiguration.theosScheme=generated.theosScheme
        workspace.configuration.buildArguments=""
        workspace.configuration.compilerOverride=""
        workspace.configuration.autoDetectToolchain=true
    }
}
