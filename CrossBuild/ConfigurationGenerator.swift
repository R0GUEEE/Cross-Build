import Foundation

struct GeneratedProjectConfiguration {
    let toolchain: ToolchainKind
    let buildCommand: String
    /// Nil means "the project did not say". `apply` leaves the user's value alone
    /// in that case; the old non-optional fields were seeded with defaults and
    /// written on every detection, so a hand-set deployment target, architecture,
    /// package format or scheme was reset on the next launch.
    let deploymentTarget: String?
    let architectures: String?
    let packageFormat: String?
    let theosScheme: String?
    let summary: [String]
}

enum ConfigurationGenerator {
    static func generate(from analysis: ProjectAnalysis,
                         files: [WorkspaceFile],
                         fileContents: [String: String] = [:]) -> GeneratedProjectConfiguration {
        let makefile = fileContents["Makefile"] ?? ""
        var deployment: String?
        var architectures: String?
        var format: String?
        var scheme: String?
        var notes = ["Detected \(analysis.primaryToolchain.rawValue)"]

        if let value = firstCapture(in: makefile, pattern: #"IPHONEOS_DEPLOYMENT_TARGET\s*[:?+]?=\s*([0-9]+(?:\.[0-9]+)?)"#)
            ?? theosDeploymentTarget(in: makefile) {
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
        // Same rule as detection: only take over the toolchain when the user has
        // left auto-detection on.
        if workspace.configuration.autoDetectToolchain {
            workspace.selectedToolchain = generated.toolchain
        }
        workspace.recommendedBuildCommand = generated.buildCommand
        // Only values the project actually declared. Writing "16.0"/"arm64"/
        // "binary" here overwrote whatever the user had typed, on every launch and
        // every project switch.
        if let value = generated.deploymentTarget { workspace.compilerConfiguration.deploymentTarget = value }
        if let value = generated.architectures { workspace.compilerConfiguration.architectures = value }
        if let value = generated.packageFormat { workspace.compilerConfiguration.packageFormat = value }
        if let value = generated.theosScheme { workspace.compilerConfiguration.theosScheme = value }
        // Deliberately NOT setting `autoDetectToolchain = true` here. It was, and
        // because `apply` runs on every detection, the "Auto-detect toolchain"
        // switch could never stay off: turning it off lasted only until the next
        // detection turned it back on and overrode the toolchain the user picked.
    }

    /// Theos' `TARGET = platform:toolchain:sdk:deployment`.
    ///
    /// The old single regex used a lazy `.*?:` and therefore captured the *SDK*
    /// version, not the deployment target, for the canonical four-field form.
    private static func theosDeploymentTarget(in makefile: String) -> String? {
        guard let line = firstCapture(in: makefile, pattern: #"TARGET\s*[:?+]?=\s*([^\n#]+)"#) else { return nil }
        let fields = line.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 4 else { return nil }
        let last = fields[fields.count - 1]
        guard last.first?.isNumber == true else { return nil }
        return last
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
