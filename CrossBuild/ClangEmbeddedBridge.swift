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
    /// Where an SDK may live.
    ///
    /// The bundle is first, for a jailbroken build that could carry one. The rest
    /// are where a user can actually put one -- and that matters, because Apple's
    /// iOS SDK is not redistributable, so it can never be the reason a count is
    /// non-zero. Looking only in the bundle meant the answer was permanently zero
    /// and there was no supported way to change it, even though the app's
    /// Documents directory is now visible in Files.app.
    static func searchRoots() -> [URL] {
        var roots: [URL] = []
        // The bundle first: an SDK built into the app (the `Bundle iPhoneOS SDK`
        // workflow) is the one this app was made with.
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("SDKs", isDirectory: true) {
            roots.append(bundled)
        }
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            roots.append(documents.appendingPathComponent("SDKs", isDirectory: true))
            roots.append(documents.appendingPathComponent("Workspace/SDKs", isDirectory: true))
        }
        return roots
    }

    /// Every `.sdk` bundle under `root`, one and two levels deep.
    ///
    /// One level is how a single `iPhoneOS18.2.sdk` is dropped in. Two levels is how
    /// an SDK usually arrives: an unzipped `Xcode.app/Contents/Developer/Platforms/
    /// iPhoneOS.platform/Developer/SDKs/foo.sdk` copied from Files is too deep to
    /// find, but a `SDKs/` folder containing one or more `.sdk` bundles is common,
    /// and so is a `Platforms/…/SDKs` folder dragged in whole.
    private static func sdks(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var found: [URL] = []
        for child in children {
            if child.pathExtension == "sdk" {
                found.append(child)
                continue
            }
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let grandchildren = try? fm.contentsOfDirectory(at: child, includingPropertiesForKeys: nil) else { continue }
            found.append(contentsOf: grandchildren.filter { $0.pathExtension == "sdk" })
        }
        return found
    }

    /// Creates the folders a user can drop an SDK into, so they are visible in
    /// Files.app and the diagnostic screen has a real path to point at.
    ///
    /// Without this the answer to "why is no SDK found" was three paths that did not
    /// exist, none of which the app ever told anyone about.
    static func ensureDirectories() {
        let bundlePath = Bundle.main.resourceURL?.standardizedFileURL.path
        for root in searchRoots() where root.standardizedFileURL.path != bundlePath {
            if !FileManager.default.fileExists(atPath: root.path) {
                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            }
        }
    }

    /// SDKs shipped inside the app. Expected to be empty, and not a fault.
    static func bundledSDKs() -> [URL] {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("SDKs") else { return [] }
        return sdks(in: root)
    }

    /// Every SDK the app can see, wherever it was put.
    ///
    /// This is what the screens should count and what a build should use; the
    /// bundle-only list is what the app ships, which is a different question.
    static func availableSDKs() -> [URL] {
        searchRoots().flatMap(sdks(in:))
    }

    /// True when the SDK was supplied rather than shipped, so the UI can say which.
    static func isUserSupplied(_ url: URL) -> Bool {
        guard let bundlePath = Bundle.main.resourceURL?.standardizedFileURL.path else { return true }
        return !url.standardizedFileURL.path.hasPrefix(bundlePath)
    }

    /// The newest supplied SDK.
    ///
    /// Sorted as text, `iPhoneOS9.0.sdk` beat `iPhoneOS17.0.sdk` ("9" > "1"), and
    /// the loser was exported as SDKROOT -- so an old SDK on the device silently
    /// won over the current one.
    static func preferred() -> URL? {
        availableSDKs().max { version(of: $0) < version(of: $1) }
    }

    /// `iPhoneOS17.2.sdk` -> (17, 2). Unparseable names sort lowest.
    private static func version(of url: URL) -> (Int, Int) {
        let name = url.lastPathComponent
        guard let regex = try? NSRegularExpression(pattern: #"iOS(\d+)(?:\.(\d+))?"#),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              match.numberOfRanges > 1,
              let majorRange = Range(match.range(at: 1), in: name),
              let major = Int(name[majorRange]) else { return (0, 0) }
        var minor = 0
        if match.numberOfRanges > 2, let range = Range(match.range(at: 2), in: name) {
            minor = Int(name[range]) ?? 0
        }
        return (major, minor)
    }
}
