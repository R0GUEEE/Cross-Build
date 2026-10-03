import SwiftUI

struct CompilerConfigurationView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var config: CompilerConfiguration
    var body: some View {
        Form {
            Section("Automatic Configuration") {
                Button("Detect & Generate Settings", systemImage: "wand.and.stars") { workspace.detectSampleProject() }
                    .buttonStyle(.borderedProminent)
                if workspace.generatedConfigurationSummary.isEmpty {
                    Text("Cross Build can infer the toolchain, architecture, deployment target, package format and Theos scheme from the project.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(workspace.generatedConfigurationSummary, id: \.self) { item in
                        Label(item, systemImage: "checkmark.circle.fill")
                    }
                }
            }
            Section("Embedded Toolchain Status") {
                LabeledContent("LLVM / Clang", value: workspace.embeddedToolchains.clang.isLinked ? workspace.embeddedToolchains.clang.version : "Bridge ready • payload missing")
                LabeledContent("Bundled iOS SDKs", value: "\(IOSSDKDiscovery.bundledSDKs().count)")
                if let sdk=IOSSDKDiscovery.preferred() { LabeledContent("Preferred SDK", value:sdk.lastPathComponent) }
            }
            Section("Advanced · Target & SDK") {
                TextField("SDK", text: $config.sdk)
                TextField("Sysroot / SDK path", text: $config.sysroot)
                TextField("Architectures", text: $config.architectures)
                TextField("Deployment target", text: $config.deploymentTarget)
                Picker("Optimization", selection: $config.optimization) { Text("Debug").tag("Debug"); Text("Release").tag("Release"); Text("Size").tag("Size") }
            }
            Section("Advanced · Compiler") {
                TextField("Preprocessor defines", text: $config.defines, axis: .vertical)
                TextField("Include search paths", text: $config.includePaths, axis: .vertical)
                TextField("Compiler flags", text: $config.compilerFlags, axis: .vertical)
                Toggle("Generate debug symbols", isOn: $config.debugSymbols)
            }
            Section("Advanced · Linker") {
                TextField("Library search paths", text: $config.libraryPaths, axis: .vertical)
                TextField("Frameworks", text: $config.frameworks, axis: .vertical)
                TextField("Linker flags", text: $config.linkerFlags, axis: .vertical)
                Toggle("Strip symbols", isOn: $config.stripSymbols)
            }
            Section("Advanced · Packaging") {
                Picker("Theos scheme", selection: $config.theosScheme) { Text("Rootless").tag("rootless"); Text("Rootful").tag("rootful") }
                Picker("Package format", selection: $config.packageFormat) { Text("Debian (.deb)").tag("deb"); Text("IPA").tag("ipa"); Text("Application").tag("app"); Text("Binary").tag("binary") }
            }
            Section("Advanced · Signing") {
                Picker("Signing mode", selection: $config.signingMode) { Text("Automatic").tag("Automatic"); Text("ldid").tag("ldid"); Text("Unsigned").tag("Unsigned") }
                TextField("Entitlements path", text: $config.entitlementsPath)
            }
            Section("Advanced · Environment") { TextField("KEY=VALUE, one per line", text: $config.environment, axis: .vertical).lineLimit(4...10) }
        }.navigationTitle("Build Configuration")
    }
}
