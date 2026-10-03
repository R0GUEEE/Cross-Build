import Foundation

enum AppToolchainAvailability: String, Codable {
    case embedded = "Embedded Engine"
    case bundledSupport = "Bundled Support Library"
    case backendAdapter = "Backend Adapter"
}

struct AppToolchainLibrary: Identifiable, Codable, Hashable {
    let id:String
    let name:String
    let module:String
    let availability:AppToolchainAvailability
    let version:String
    let languages:[String]
    let requiresProcessBackend:Bool
    let resourcePath:String?
}

enum AppToolchainLibraries {
    static let all:[AppToolchainLibrary] = [
        .init(id:"clang",name:"LLVM / Clang",module:"CrossBuildClang",availability:.backendAdapter,version:"adapter-1",languages:["C","C++","Objective-C","Objective-C++","Assembly"],requiresProcessBackend:true,resourcePath:"Toolchains/LLVM"),
        .init(id:"swift",name:"Swift / SwiftPM",module:"CrossBuildSwift",availability:.backendAdapter,version:"adapter-1",languages:["Swift"],requiresProcessBackend:true,resourcePath:"Toolchains/Swift"),
        .init(id:"theos",name:"Theos / Logos",module:"CrossBuildTheos",availability:.embedded,version:"support-1",languages:["Logos","Objective-C","Objective-C++"],requiresProcessBackend:true,resourcePath:"Toolchains/Theos"),
        .init(id:"rust",name:"Rust / Cargo",module:"CrossBuildRust",availability:.backendAdapter,version:"adapter-1",languages:["Rust"],requiresProcessBackend:true,resourcePath:"Toolchains/Rust"),
        .init(id:"go",name:"Go",module:"CrossBuildGo",availability:.backendAdapter,version:"adapter-1",languages:["Go"],requiresProcessBackend:true,resourcePath:"Toolchains/Go"),
        .init(id:"zig",name:"Zig",module:"CrossBuildZig",availability:.backendAdapter,version:"adapter-1",languages:["Zig","C","C++"],requiresProcessBackend:true,resourcePath:"Toolchains/Zig"),
        .init(id:"python",name:"Python",module:"CrossBuildPython",availability:.bundledSupport,version:"support-1",languages:["Python"],requiresProcessBackend:false,resourcePath:"Toolchains/Python"),
        .init(id:"node",name:"JavaScript Runtime",module:"JavaScriptCore",availability:.embedded,version:"system",languages:["JavaScript"],requiresProcessBackend:false,resourcePath:"Toolchains/JavaScript"),
        .init(id:"typescript",name:"TypeScript",module:"CrossBuildTypeScript",availability:.bundledSupport,version:"support-1",languages:["TypeScript"],requiresProcessBackend:false,resourcePath:"Toolchains/TypeScript"),
        .init(id:"java",name:"OpenJDK / Java",module:"CrossBuildJava",availability:.backendAdapter,version:"adapter-1",languages:["Java"],requiresProcessBackend:true,resourcePath:"Toolchains/Java"),
        .init(id:"kotlin",name:"Kotlin",module:"CrossBuildKotlin",availability:.backendAdapter,version:"adapter-1",languages:["Kotlin"],requiresProcessBackend:true,resourcePath:"Toolchains/Kotlin"),
        .init(id:"cmake",name:"CMake",module:"CrossBuildCMake",availability:.backendAdapter,version:"adapter-1",languages:[],requiresProcessBackend:true,resourcePath:"Toolchains/CMake"),
        .init(id:"ninja",name:"Ninja",module:"CrossBuildNinja",availability:.backendAdapter,version:"adapter-1",languages:[],requiresProcessBackend:true,resourcePath:"Toolchains/Ninja"),
        .init(id:"meson",name:"Meson",module:"CrossBuildMeson",availability:.bundledSupport,version:"support-1",languages:[],requiresProcessBackend:true,resourcePath:"Toolchains/Meson"),
        .init(id:"make",name:"GNU Make",module:"CrossBuildMake",availability:.backendAdapter,version:"adapter-1",languages:[],requiresProcessBackend:true,resourcePath:"Toolchains/Make"),
        .init(id:"dpkg",name:"dpkg Tooling",module:"CrossBuildDPKG",availability:.bundledSupport,version:"support-1",languages:[],requiresProcessBackend:true,resourcePath:"Toolchains/dpkg"),
        .init(id:"ldid",name:"ldid",module:"CrossBuildSigning",availability:.bundledSupport,version:"support-1",languages:[],requiresProcessBackend:true,resourcePath:"Toolchains/Signing")
    ]
    static func item(_ id:String)->AppToolchainLibrary? { all.first{$0.id==id} }
}
