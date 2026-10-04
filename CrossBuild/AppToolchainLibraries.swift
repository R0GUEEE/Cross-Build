import Foundation

enum AppToolchainAvailability: String, Codable {
    case embedded = "Embedded Engine"
    case nativeLibrary = "In-App Library"
    case bundledSupport = "Bundled Support"
}

struct AppToolchainLibrary: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let module: String
    let availability: AppToolchainAvailability
    let version: String
    let languages: [String]
    let resourcePath: String?
}

struct AppToolchainScan: Identifiable {
    let id: String
    let name: String
    let present: Bool
    let detail: String
    let location: String
}

enum AppToolchainLibraries {
    static let all: [AppToolchainLibrary] = [
        .init(id:"clang",name:"LLVM / Clang",module:"CrossBuildClang",availability:.nativeLibrary,version:"native",languages:["C","C++","Objective-C","Objective-C++","Assembly"],resourcePath:"Toolchains/LLVM"),
        .init(id:"swift",name:"Swift / SwiftPM",module:"CrossBuildSwift",availability:.nativeLibrary,version:"native",languages:["Swift"],resourcePath:"Toolchains/Swift"),
        .init(id:"theos",name:"Theos / Logos",module:"CrossBuildTheos",availability:.bundledSupport,version:"bundled",languages:["Logos","Objective-C","Objective-C++"],resourcePath:"Toolchains/Theos"),
        .init(id:"rust",name:"Rust / Cargo",module:"CrossBuildRust",availability:.nativeLibrary,version:"native",languages:["Rust"],resourcePath:"Toolchains/Rust"),
        .init(id:"go",name:"Go",module:"CrossBuildGo",availability:.nativeLibrary,version:"native",languages:["Go"],resourcePath:"Toolchains/Go"),
        .init(id:"zig",name:"Zig",module:"CrossBuildZig",availability:.nativeLibrary,version:"native",languages:["Zig","C","C++"],resourcePath:"Toolchains/Zig"),
        .init(id:"python",name:"Python",module:"CrossBuildPython",availability:.embedded,version:"3.13",languages:["Python"],resourcePath:"Toolchains/Python"),
        .init(id:"node",name:"Node.js",module:"CrossBuildNode",availability:.nativeLibrary,version:"native",languages:["JavaScript"],resourcePath:"Toolchains/JavaScript"),
        .init(id:"javascriptcore",name:"JavaScriptCore",module:"JavaScriptCore",availability:.embedded,version:"system",languages:["JavaScript"],resourcePath:"Toolchains/JavaScript"),
        .init(id:"typescript",name:"TypeScript",module:"CrossBuildTypeScript",availability:.bundledSupport,version:"bundled",languages:["TypeScript"],resourcePath:"Toolchains/TypeScript"),
        .init(id:"java",name:"OpenJDK / Java",module:"CrossBuildJava",availability:.nativeLibrary,version:"native",languages:["Java"],resourcePath:"Toolchains/Java"),
        .init(id:"kotlin",name:"Kotlin",module:"CrossBuildKotlin",availability:.nativeLibrary,version:"native",languages:["Kotlin"],resourcePath:"Toolchains/Kotlin"),
        .init(id:"cmake",name:"CMake",module:"CrossBuildCMake",availability:.nativeLibrary,version:"native",languages:[],resourcePath:"Toolchains/CMake"),
        .init(id:"ninja",name:"Ninja",module:"CrossBuildNinja",availability:.nativeLibrary,version:"native",languages:[],resourcePath:"Toolchains/Ninja"),
        .init(id:"meson",name:"Meson",module:"CrossBuildMeson",availability:.bundledSupport,version:"bundled",languages:[],resourcePath:"Toolchains/Meson"),
        .init(id:"make",name:"GNU Make",module:"CrossBuildMake",availability:.nativeLibrary,version:"native",languages:[],resourcePath:"Toolchains/Make"),
        .init(id:"dpkg",name:"dpkg Tooling",module:"CrossBuildDPKG",availability:.nativeLibrary,version:"native",languages:[],resourcePath:"Toolchains/dpkg"),
        .init(id:"ldid",name:"ldid",module:"CrossBuildSigning",availability:.nativeLibrary,version:"native",languages:[],resourcePath:"Toolchains/Signing")
    ]

    static func item(_ id: String) -> AppToolchainLibrary? { all.first { $0.id == id } }

    /// Scans the installed app, not PATH or the Linux guest. A manifest alone is
    /// reported as support metadata; a compiler is ready only when its in-app
    /// engine/framework/library is actually present.
    static func scanBundle() -> [AppToolchainScan] {
        all.map { lib in
            if lib.id == "javascriptcore" {
                return .init(id: lib.id, name: lib.name, present: true,
                             detail: "System framework available in-process.", location: "JavaScriptCore.framework")
            }
            if lib.id == "python" {
                let engine = PythonEmbeddedEngine()
                let stdlib = Bundle.main.resourceURL?.appendingPathComponent("python/lib/python3.13")
                let ok = engine.isLinked && (stdlib.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
                return .init(id: lib.id, name: lib.name, present: ok,
                             detail: ok ? "CPython engine and standard library are bundled." : "Python engine or standard library is missing.",
                             location: "Python.framework")
            }
            if lib.id == "clang" {
                let bridge = ClangEmbeddedBridge()
                let payload = hasNativePayload(for: lib)
                let ok = bridge.isLinked && payload
                return .init(id: lib.id, name: lib.name, present: ok,
                             detail: ok ? "Clang bridge and native LLVM payload detected." : "Bridge is linked, but the native LLVM/clangDriver payload is not yet present.",
                             location: lib.resourcePath ?? "Statically linked")
            }

            let payload = hasNativePayload(for: lib)
            return .init(id: lib.id, name: lib.name, present: payload,
                         detail: payload ? "In-app payload detected." : "No in-app library payload detected; catalogue metadata alone is not treated as installed.",
                         location: lib.resourcePath ?? lib.module)
        }
    }

    static var missing: [AppToolchainScan] { scanBundle().filter { !$0.present } }

    private static func hasNativePayload(for lib: AppToolchainLibrary) -> Bool {
        let fm = FileManager.default
        let roots = [Bundle.main.bundleURL, Bundle.main.resourceURL].compactMap { $0 }
        let names = [lib.module, lib.id, lib.name.replacingOccurrences(of: " ", with: "")]
        let extensions = ["framework", "dylib", "a", "xcframework"]

        for root in roots {
            for name in names {
                for ext in extensions {
                    if fm.fileExists(atPath: root.appendingPathComponent("\(name).\(ext)").path) { return true }
                    if fm.fileExists(atPath: root.appendingPathComponent("Frameworks/\(name).framework").path) { return true }
                    if fm.fileExists(atPath: root.appendingPathComponent("Libraries/lib\(name).a").path) { return true }
                }
            }
        }

        guard let relative = lib.resourcePath,
              let resourceRoot = Bundle.main.resourceURL?.appendingPathComponent(relative),
              let enumerator = fm.enumerator(at: resourceRoot, includingPropertiesForKeys: [.isRegularFileKey])
        else { return false }

        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if ["a", "dylib", "framework", "xcframework"].contains(ext) { return true }
        }
        return false
    }
}
