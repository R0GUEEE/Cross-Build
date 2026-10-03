import Foundation

enum NativeLanguage:String, Codable, CaseIterable {
    case c="c", cpp="c++", objectiveC="objective-c", objectiveCpp="objective-c++"
}

struct NativeCompileRequest: Sendable {
    var sourcePath:String
    var outputPath:String
    var language:NativeLanguage
    var targetTriple:String
    var sysroot:String?
    var deploymentTarget:String
    var arguments:[String]
}

struct NativeDiagnostic: Identifiable, Sendable {
    let id=UUID()
    var severity:String
    var message:String
    var file:String?
    var line:Int?
    var column:Int?
}

struct NativeCompileResult: Sendable {
    var succeeded:Bool
    var diagnostics:[NativeDiagnostic]
    var outputPath:String?
}

protocol NativeCompilerBridge {
    var isLinked:Bool { get }
    var version:String { get }
    func compile(_ request:NativeCompileRequest) async -> NativeCompileResult
}

struct ClangEmbeddedBridge: NativeCompilerBridge {
    // The stable Swift boundary for a vendored libclang/clangDriver implementation.
    // Cross Build only reports the engine ready when the native module marker exists.
    var isLinked:Bool {
        Bundle.main.url(forResource:"CrossBuildClang",withExtension:"framework",subdirectory:"Frameworks") != nil
    }
    var version:String { isLinked ? "Embedded LLVM" : "Bridge ready • LLVM payload missing" }

    func compile(_ request:NativeCompileRequest) async -> NativeCompileResult {
        guard isLinked else {
            return .init(succeeded:false,diagnostics:[
                .init(severity:"error",message:"Embedded LLVM payload is not linked in this app build.",file:request.sourcePath),
                .init(severity:"note",message:"CrossBuildClang bridge is ready for a compatible static/framework LLVM payload.")
            ],outputPath:nil)
        }
        return .init(succeeded:false,diagnostics:[
            .init(severity:"error",message:"LLVM payload detected but the native clangDriver shim has not been linked yet.")
        ],outputPath:nil)
    }
}

enum IOSSDKDiscovery {
    static func bundledSDKs()->[URL] {
        guard let root=Bundle.main.resourceURL?.appendingPathComponent("SDKs") else{return[]}
        return ((try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? [])
            .filter{$0.pathExtension=="sdk"}
    }
    static func preferred()->URL? { bundledSDKs().sorted{$0.lastPathComponent>$1.lastPathComponent}.first }
}
