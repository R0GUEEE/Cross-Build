import Foundation
import JavaScriptCore

struct EmbeddedToolchainResult: Sendable {
    var output:String
    var diagnostics:[String]
    var succeeded:Bool
}

protocol EmbeddedToolchainEngine {
    var id:String { get }
    var name:String { get }
    var version:String { get }
    func run(source:String, options:[String:String]) async -> EmbeddedToolchainResult
}

final class JavaScriptCoreEngine: EmbeddedToolchainEngine {
    let id="node"
    let name="JavaScriptCore"
    let version="System JavaScriptCore"
    func run(source:String, options:[String:String]) async -> EmbeddedToolchainResult {
        guard let context=JSContext() else { return .init(output:"",diagnostics:["Could not create JavaScriptCore context."],succeeded:false) }
        var messages:[String]=[]
        context.exceptionHandler={ _, exception in if let value=exception?.toString(){ messages.append(value) } }
        let value=context.evaluateScript(source)
        return .init(output:value?.toString() ?? "",diagnostics:messages,succeeded:messages.isEmpty)
    }
}

struct LogosPreprocessorEngine: EmbeddedToolchainEngine {
    let id="theos"
    let name="Logos Preprocessor"
    let version="CrossBuild 1"
    func run(source:String, options:[String:String]) async -> EmbeddedToolchainResult {
        let markers=["%hook","%end","%orig","%new","%ctor","%group","%init"]
        let found=markers.filter{source.contains($0)}
        guard !found.isEmpty else { return .init(output:source,diagnostics:["No Logos directives detected."],succeeded:true) }
        return .init(output:source,diagnostics:["Logos source recognized: "+found.joined(separator:", "),"Full Logos lowering requires the bundled Logos parser payload."],succeeded:true)
    }
}

@MainActor
final class EmbeddedToolchainManager: ObservableObject {
    @Published private(set) var available:[String:String]=[:]
    private let javascript=JavaScriptCoreEngine()
    private let logos=LogosPreprocessorEngine()
    let clang=ClangEmbeddedBridge()

    init(){ probe() }

    func probe() {
        available[javascript.id]=javascript.version
        available[logos.id]=logos.version
        if clang.isLinked { available["clang"]=clang.version }
    }

    func isAvailable(_ id:String)->Bool { available[id] != nil }

    func run(id:String, source:String, options:[String:String]=[:]) async -> EmbeddedToolchainResult {
        switch id {
        case javascript.id: return await javascript.run(source:source,options:options)
        case logos.id: return await logos.run(source:source,options:options)
        case "clang":
            guard let path=options["sourcePath"], let output=options["outputPath"] else {
                return .init(output:"",diagnostics:["Clang requires sourcePath and outputPath options."],succeeded:false)
            }
            let language=NativeLanguage(rawValue:options["language"] ?? "c") ?? .c
            let request=NativeCompileRequest(sourcePath:path,outputPath:output,language:language,targetTriple:options["target"] ?? "arm64-apple-ios",sysroot:options["sysroot"],deploymentTarget:options["deployment"] ?? "16.0",arguments:[])
            let result=await clang.compile(request)
            return .init(output:result.outputPath ?? "",diagnostics:result.diagnostics.map{"\($0.severity): \($0.message)"},succeeded:result.succeeded)
        default: return .init(output:"",diagnostics:["No linked embedded engine for \(id)."],succeeded:false)
        }
    }
}
