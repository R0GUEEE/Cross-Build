import SwiftUI

struct CompilerConfigurationView: View {
    @ObservedObject var config: CompilerConfiguration
    var body: some View {
        Form {
            Section("Target & SDK") {
                TextField("SDK", text: $config.sdk)
                TextField("Sysroot / SDK path", text: $config.sysroot)
                TextField("Architectures", text: $config.architectures)
                TextField("Deployment target", text: $config.deploymentTarget)
                Picker("Optimization", selection: $config.optimization) { Text("Debug").tag("Debug"); Text("Release").tag("Release"); Text("Size").tag("Size") }
            }
            Section("Compiler") {
                TextField("Preprocessor defines", text: $config.defines, axis: .vertical)
                TextField("Include search paths", text: $config.includePaths, axis: .vertical)
                TextField("Compiler flags", text: $config.compilerFlags, axis: .vertical)
                Toggle("Generate debug symbols", isOn: $config.debugSymbols)
            }
            Section("Linker") {
                TextField("Library search paths", text: $config.libraryPaths, axis: .vertical)
                TextField("Frameworks", text: $config.frameworks, axis: .vertical)
                TextField("Linker flags", text: $config.linkerFlags, axis: .vertical)
                Toggle("Strip symbols", isOn: $config.stripSymbols)
            }
            Section("Theos / Packaging") {
                Picker("Theos scheme", selection: $config.theosScheme) { Text("Rootless").tag("rootless"); Text("Rootful").tag("rootful") }
                Picker("Package format", selection: $config.packageFormat) { Text("Debian (.deb)").tag("deb"); Text("IPA").tag("ipa"); Text("Application").tag("app"); Text("Binary").tag("binary") }
            }
            Section("Signing") {
                Picker("Signing mode", selection: $config.signingMode) { Text("Automatic").tag("Automatic"); Text("ldid").tag("ldid"); Text("Unsigned").tag("Unsigned") }
                TextField("Entitlements path", text: $config.entitlementsPath)
            }
            Section("Environment") { TextField("KEY=VALUE, one per line", text: $config.environment, axis: .vertical).lineLimit(4...10) }
        }.navigationTitle("Build Configuration")
    }
}
