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
    @AppStorage("workspace.cleanArguments") var cleanArguments = ""
    @AppStorage("workspace.testArguments") var testArguments = ""
    @AppStorage("workspace.packageArguments") var packageArguments = ""
    @AppStorage("workspace.environmentVariables") var environmentVariables = ""
    @AppStorage("workspace.sdkPath") var sdkPath = ""
    @AppStorage("workspace.autoDetect") var autoDetectToolchain = true
    @AppStorage("workspace.indexSources") var indexSources = true
    @AppStorage("workspace.autosave") var autosave = true
    @AppStorage("workspace.restoreTabs") var restoreOpenTabs = true
    @AppStorage("workspace.confirmCloseDirty") var confirmCloseDirty = true
    @AppStorage("workspace.searchCase") var searchCaseSensitive = false
    @AppStorage("workspace.searchHidden") var searchHiddenFiles = false
    @AppStorage("workspace.excludePatterns") var excludePatterns = ".git,DerivedData,.build,node_modules"
    @AppStorage("workspace.defaultEncoding") var defaultEncoding = "UTF-8"
    @AppStorage("workspace.lineEndings") var lineEndings = "LF"
    @AppStorage("workspace.followSymlinks") var followSymlinks = false
    @AppStorage("workspace.showAppDirectories") var showAppDirectories = true
    @AppStorage("workspace.showBundle") var showAppBundle = true
    @AppStorage("workspace.showContainerLibrary") var showContainerLibrary = true
    @AppStorage("workspace.showTemporary") var showTemporaryFiles = true
    @AppStorage("workspace.maxRecentFiles") var maxRecentFiles = 20
    @AppStorage("workspace.defaultNewFileExtension") var defaultNewFileExtension = "swift"
    @AppStorage("workspace.searchFileContents") var searchFileContents = false
    @AppStorage("workspace.detectNestedProjects") var detectNestedProjects = true
    @AppStorage("workspace.preferNearestManifest") var preferNearestManifest = true
    @AppStorage("workspace.customManifestNames") var customManifestNames = ""
    @AppStorage("workspace.artifactDirectory") var artifactDirectory = ""
    @AppStorage("workspace.keepBuildArtifacts") var keepBuildArtifacts = true
    @AppStorage("workspace.cleanArtifactDirectory") var cleanArtifactDirectory = false
}
