import SwiftUI

struct CompilerConfigurationView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var config: CompilerConfiguration

    var body: some View {
        Form {
            Section("Automatic Configuration") {
                Button("Detect & Generate Settings", systemImage: "wand.and.stars") {
                    workspace.detectSampleProject()
                }
                .buttonStyle(.borderedProminent)
                if workspace.generatedConfigurationSummary.isEmpty {
                    Text("Infer toolchain, architecture, deployment target, package format and Theos scheme from the active project.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(workspace.generatedConfigurationSummary, id: \.self) {
                        Label($0, systemImage: "checkmark.circle.fill")
                    }
                }
            }

            Section("Toolchain & SDK") {
                TextField("SDK name", text: $config.sdk)
                TextField("Sysroot / SDK path", text: $config.sysroot)
                TextField("Target triple", text: $config.targetTriple)
                TextField("Architectures", text: $config.architectures)
                TextField("Deployment target", text: $config.deploymentTarget)
                Picker("Optimization", selection: $config.optimization) {
                    Text("Debug").tag("Debug")
                    Text("Release").tag("Release")
                    Text("Size").tag("Size")
                }
                LabeledContent("Embedded Clang", value: workspace.embeddedToolchains.clang.isLinked ? workspace.embeddedToolchains.clang.version : "Bridge payload missing")
                LabeledContent("Bundled iOS SDKs", value: "\(IOSSDKDiscovery.bundledSDKs().count)")
            }

            Section("Language & Code Generation") {
                Picker("C standard", selection: $config.languageStandard) {
                    ForEach(["Default","c11","c17","gnu11","gnu17","c2x"], id: \.self) { Text($0).tag($0) }
                }
                Picker("C++ standard", selection: $config.cppStandard) {
                    ForEach(["Default","c++17","c++20","c++23","gnu++17","gnu++20"], id: \.self) { Text($0).tag($0) }
                }
                Toggle("Objective-C ARC", isOn: $config.objcARC)
                Toggle("Clang modules", isOn: $config.clangModules)
                Toggle("Position-independent code", isOn: $config.positionIndependentCode)
                Toggle("Generate debug symbols", isOn: $config.debugSymbols)
                Toggle("Link-time optimization", isOn: $config.linkTimeOptimization)
                Toggle("Incremental build", isOn: $config.incrementalBuild)
                Toggle("Reproducible build hints", isOn: $config.reproducibleBuild)
                Toggle("Bitcode flag", isOn: $config.bitcode)
            }

            Section("Preprocessor & Includes") {
                TextField("Defines", text: $config.defines, axis: .vertical).lineLimit(2...6)
                TextField("Undefines", text: $config.undefines, axis: .vertical).lineLimit(2...6)
                TextField("Include search paths — one per line", text: $config.includePaths, axis: .vertical).lineLimit(2...8)
                TextField("System include paths — one per line", text: $config.systemIncludePaths, axis: .vertical).lineLimit(2...8)
                TextField("Framework search paths — one per line", text: $config.frameworkSearchPaths, axis: .vertical).lineLimit(2...8)
            }

            Section("Compiler Flags") {
                TextField("General compiler flags", text: $config.compilerFlags, axis: .vertical).lineLimit(2...8)
                TextField("Swift flags", text: $config.swiftFlags, axis: .vertical).lineLimit(2...6)
                TextField("Rust flags", text: $config.rustFlags, axis: .vertical).lineLimit(2...6)
                TextField("Go flags", text: $config.goFlags, axis: .vertical).lineLimit(2...6)
                TextField("Zig flags", text: $config.zigFlags, axis: .vertical).lineLimit(2...6)
            }

            Section("Linker") {
                TextField("Library search paths — one per line", text: $config.libraryPaths, axis: .vertical).lineLimit(2...8)
                TextField("Libraries", text: $config.libraries, axis: .vertical)
                TextField("Frameworks", text: $config.frameworks, axis: .vertical)
                TextField("Linker flags", text: $config.linkerFlags, axis: .vertical).lineLimit(2...8)
                Toggle("Dead-strip unused code", isOn: $config.deadStrip)
                Toggle("Strip symbols", isOn: $config.stripSymbols)
            }

            Section("Theos & Logos") {
                Picker("Package scheme", selection: $config.theosScheme) {
                    Text("Rootless").tag("rootless")
                    Text("Rootful").tag("rootful")
                }
                TextField("THEOS path", text: $config.theosPath)
                TextField("THEOS target", text: $config.theosTarget)
                TextField("Additional make flags", text: $config.theosMakeFlags, axis: .vertical)
            }

            Section("Package Metadata") {
                Picker("Artifact format", selection: $config.packageFormat) {
                    Text("Debian (.deb)").tag("deb")
                    Text("IPA").tag("ipa")
                    Text("Application").tag("app")
                    Text("Binary").tag("binary")
                    Text("Library").tag("library")
                    Text("Framework").tag("framework")
                }
                TextField("Package name", text: $config.packageName)
                TextField("Identifier", text: $config.packageIdentifier)
                TextField("Version", text: $config.packageVersion)
                TextField("Architecture", text: $config.packageArchitecture)
                TextField("Depends", text: $config.packageDepends, axis: .vertical)
                TextField("Section", text: $config.packageSection)
                TextField("Maintainer", text: $config.packageMaintainer)
                TextField("Description", text: $config.packageDescription, axis: .vertical).lineLimit(2...6)
            }

            Section("Signing & Provisioning") {
                Picker("Signing mode", selection: $config.signingMode) {
                    Text("Automatic").tag("Automatic")
                    Text("ldid").tag("ldid")
                    Text("Unsigned").tag("Unsigned")
                }
                TextField("Signing identity", text: $config.signingIdentity)
                TextField("Bundle identifier", text: $config.bundleIdentifier)
                TextField("Entitlements path", text: $config.entitlementsPath)
                TextField("Provisioning profile path", text: $config.provisioningProfile)
            }

            Section("Environment") {
                TextField("KEY=VALUE, one per line", text: $config.environment, axis: .vertical)
                    .lineLimit(4...12)
            }
        }
        .navigationTitle("Build Configuration")
    }
}
