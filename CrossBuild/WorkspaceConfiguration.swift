import Foundation
import SwiftUI

@MainActor
final class WorkspaceConfiguration: ObservableObject {
    @AppStorage("workspace.projectName") var projectName = "Cross Build Project"
    @AppStorage("workspace.buildTarget") var buildTarget = "Debug"
    @AppStorage("workspace.deploymentTarget") var deploymentTarget = "16.0"
    @AppStorage("workspace.architecture") var architecture = "arm64"
    @AppStorage("workspace.workingDirectory") var workingDirectory = ""
    @AppStorage("workspace.buildArguments") var buildArguments = ""
    @AppStorage("workspace.environmentVariables") var environmentVariables = ""
    @AppStorage("workspace.compilerOverride") var compilerOverride = ""
    @AppStorage("workspace.sdkPath") var sdkPath = ""
    @AppStorage("workspace.autoDetect") var autoDetectToolchain = true
    @AppStorage("workspace.indexSources") var indexSources = true
    @AppStorage("workspace.autosave") var autosave = true
    @AppStorage("workspace.gitShallow") var gitShallowClone = true
    @AppStorage("workspace.gitBranch") var gitDefaultBranch = ""
    @AppStorage("workspace.gitSubmodules") var gitSubmodules = false
}
