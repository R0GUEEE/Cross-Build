import Foundation
import SwiftUI

@MainActor
final class CompilerConfiguration: ObservableObject {
    @AppStorage("compiler.sdk") var sdk = "iPhoneOS"
    @AppStorage("compiler.sysroot") var sysroot = ""
    @AppStorage("compiler.archs") var architectures = "arm64"
    @AppStorage("compiler.deployment") var deploymentTarget = "16.0"
    @AppStorage("compiler.targetTriple") var targetTriple = ""
    @AppStorage("compiler.minimumOS") var minimumOS = ""
    @AppStorage("compiler.optimization") var optimization = "Debug"
    @AppStorage("compiler.languageStandard") var languageStandard = "Default"
    @AppStorage("compiler.cppStandard") var cppStandard = "Default"
    @AppStorage("compiler.defines") var defines = ""
    @AppStorage("compiler.undefines") var undefines = ""
    @AppStorage("compiler.includes") var includePaths = ""
    @AppStorage("compiler.systemIncludes") var systemIncludePaths = ""
    @AppStorage("compiler.frameworkPaths") var frameworkSearchPaths = ""
    @AppStorage("compiler.libs") var libraryPaths = ""
    @AppStorage("compiler.libraries") var libraries = ""
    @AppStorage("compiler.frameworks") var frameworks = ""
    @AppStorage("compiler.linker") var linkerFlags = ""
    @AppStorage("compiler.compilerFlags") var compilerFlags = ""
    @AppStorage("compiler.swiftFlags") var swiftFlags = ""
    @AppStorage("compiler.rustFlags") var rustFlags = ""
    @AppStorage("compiler.goFlags") var goFlags = ""
    @AppStorage("compiler.zigFlags") var zigFlags = ""
    @AppStorage("compiler.env") var environment = ""
    @AppStorage("compiler.theosScheme") var theosScheme = "rootless"
    @AppStorage("compiler.theosPath") var theosPath = ""
    @AppStorage("compiler.theosTarget") var theosTarget = ""
    @AppStorage("compiler.theosMakeFlags") var theosMakeFlags = ""
    @AppStorage("compiler.packageFormat") var packageFormat = "deb"
    @AppStorage("compiler.packageName") var packageName = ""
    @AppStorage("compiler.packageIdentifier") var packageIdentifier = ""
    @AppStorage("compiler.packageVersion") var packageVersion = ""
    @AppStorage("compiler.packageArchitecture") var packageArchitecture = ""
    @AppStorage("compiler.packageDepends") var packageDepends = ""
    @AppStorage("compiler.packageSection") var packageSection = ""
    @AppStorage("compiler.packageMaintainer") var packageMaintainer = ""
    @AppStorage("compiler.packageDescription") var packageDescription = ""
    @AppStorage("compiler.signing") var signingMode = "Automatic"
    @AppStorage("compiler.signingIdentity") var signingIdentity = ""
    @AppStorage("compiler.entitlements") var entitlementsPath = ""
    @AppStorage("compiler.provisioningProfile") var provisioningProfile = ""
    @AppStorage("compiler.bundleIdentifier") var bundleIdentifier = ""
    @AppStorage("compiler.strip") var stripSymbols = false
    @AppStorage("compiler.deadStrip") var deadStrip = false
    @AppStorage("compiler.debugSymbols") var debugSymbols = true
    @AppStorage("compiler.bitcode") var bitcode = false
    @AppStorage("compiler.lto") var linkTimeOptimization = false
    @AppStorage("compiler.pic") var positionIndependentCode = true
    @AppStorage("compiler.arc") var objcARC = true
    @AppStorage("compiler.modules") var clangModules = true
    @AppStorage("compiler.incremental") var incrementalBuild = true
    @AppStorage("compiler.reproducible") var reproducibleBuild = false
}
