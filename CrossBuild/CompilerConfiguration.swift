import Foundation
import SwiftUI

@MainActor
final class CompilerConfiguration: ObservableObject {
    @AppStorage("compiler.sdk") var sdk = "iPhoneOS"
    @AppStorage("compiler.sysroot") var sysroot = ""
    @AppStorage("compiler.archs") var architectures = "arm64"
    @AppStorage("compiler.deployment") var deploymentTarget = "16.0"
    @AppStorage("compiler.optimization") var optimization = "Debug"
    @AppStorage("compiler.defines") var defines = ""
    @AppStorage("compiler.includes") var includePaths = ""
    @AppStorage("compiler.libs") var libraryPaths = ""
    @AppStorage("compiler.frameworks") var frameworks = ""
    @AppStorage("compiler.linker") var linkerFlags = ""
    @AppStorage("compiler.compilerFlags") var compilerFlags = ""
    @AppStorage("compiler.env") var environment = ""
    @AppStorage("compiler.theosScheme") var theosScheme = "rootless"
    @AppStorage("compiler.packageFormat") var packageFormat = "deb"
    @AppStorage("compiler.signing") var signingMode = "Automatic"
    @AppStorage("compiler.entitlements") var entitlementsPath = ""
    @AppStorage("compiler.strip") var stripSymbols = false
    @AppStorage("compiler.debugSymbols") var debugSymbols = true
}
