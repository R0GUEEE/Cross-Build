import Foundation
#if canImport(CrossBuildClang)
import CrossBuildClang
#endif

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
    // CrossBuildClang is a small static C ABI library (see Native/CrossBuildClang)
    // compiled directly into the app binary -- there is no embedded bundle, so
    // nothing to load at runtime and nothing for installd to validate.
    //
    // It is real and callable in every app build, but it currently ships without
    // a vendored LLVM/clangDriver implementation, so `compile` always reports a
    // native-but-unimplemented failure rather than actually compiling anything.
    // `isLinked` means "the module was compiled in", not "a real LLVM payload is
    // behind it" -- see `version`/`compile` for that distinction.
    var isLinked:Bool {
        #if canImport(CrossBuildClang)
        return true
        #else
        return false
        #endif
    }

    var version:String {
        #if canImport(CrossBuildClang)
        return String(cString: cb_clang_version())
        #else
        return "Bridge not linked in this build"
        #endif
    }

    func compile(_ request:NativeCompileRequest) async -> NativeCompileResult {
        #if canImport(CrossBuildClang)
        let box = DiagnosticsBox()
        let exitCode = cb_clang_compile(0, nil, { severityPtr, messagePtr, filePtr, line, column, ctx in
            guard let ctx else { return }
            let box = Unmanaged<DiagnosticsBox>.fromOpaque(ctx).takeUnretainedValue()
            let severity = severityPtr.map { String(cString: $0) } ?? "error"
            let message = messagePtr.map { String(cString: $0) } ?? "unknown error"
            let file = filePtr.map { String(cString: $0) }
            box.diagnostics.append(.init(severity: severity, message: message, file: file,
                                          line: line > 0 ? Int(line) : nil,
                                          column: column > 0 ? Int(column) : nil))
        }, Unmanaged.passUnretained(box).toOpaque())
        return .init(succeeded: exitCode == 0, diagnostics: box.diagnostics, outputPath: exitCode == 0 ? request.outputPath : nil)
        #else
        return .init(succeeded:false,diagnostics:[
            .init(severity:"error",message:"CrossBuildClang was not linked into this app build.",file:request.sourcePath)
        ],outputPath:nil)
        #endif
    }
}

#if canImport(CrossBuildClang)
/// Reference box so the C callback (which only receives an opaque pointer) can
/// append into the same diagnostics array the async caller reads back afterward.
private final class DiagnosticsBox {
    var diagnostics: [NativeDiagnostic] = []
}
#endif

enum IOSSDKDiscovery {
    static func bundledSDKs()->[URL] {
        guard let root=Bundle.main.resourceURL?.appendingPathComponent("SDKs") else{return[]}
        return ((try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? [])
            .filter{$0.pathExtension=="sdk"}
    }
    static func preferred()->URL? { bundledSDKs().sorted{$0.lastPathComponent>$1.lastPathComponent}.first }
}
