import Foundation

@MainActor
final class WorkspaceConfiguration: ObservableObject {
    @Published var projectName = "Cross Build Project"
    @Published var buildTarget = "Debug"
    @Published var deploymentTarget = "16.0"
    @Published var architecture = "arm64"
    @Published var workingDirectory = ""
    @Published var buildArguments = ""
    @Published var environmentVariables = ""
    @Published var compilerOverride = ""
    @Published var sdkPath = ""
    @Published var autoDetectToolchain = true
    @Published var indexSources = true
    @Published var autosave = true
    @Published var gitShallowClone = true
    @Published var gitDefaultBranch = ""
    @Published var gitSubmodules = false
}
