import Foundation
#if canImport(CrossBuildPython)
import CrossBuildPython
#endif

/// Embedded CPython. This is the one engine that makes a language genuinely
/// available on a stock sideload with no helper, because the interpreter runs
/// in-process — it is linked into the app and never spawns anything.
///
/// The runtime library and standard library are vendored at build time (see the
/// "Vendor Python runtime" CI step) and copied into the bundle as
/// `python/lib/python3.X`, which is the PYTHONHOME layout CPython documents for
/// iOS.
struct PythonEmbeddedEngine: EmbeddedToolchainEngine {
    let id = "python3"
    let name = "Python 3"
    var version: String {
        #if canImport(CrossBuildPython)
        return String(cString: cbpy_version())
        #else
        return "Python runtime not linked"
        #endif
    }

    var isLinked: Bool {
        #if canImport(CrossBuildPython)
        return true
        #else
        return false
        #endif
    }

    /// Whether the vendored standard library is actually in this bundle.
    ///
    /// Cheap and side-effect free, unlike `ensureStarted()`, so availability
    /// screens can ask it without booting the interpreter.
    static var hasStandardLibrary: Bool {
        guard let resourcePath = Bundle.main.resourceURL?.path else { return false }
        return FileManager.default.fileExists(atPath: resourcePath + "/python/lib/python3.13")
    }

    func run(source: String, options: [String: String]) async -> EmbeddedToolchainResult {
        #if canImport(CrossBuildPython)
        let startError = PythonEmbeddedEngine.ensureStarted()
        if let startError {
            return .init(output: "", diagnostics: [startError], succeeded: false)
        }
        var stdoutPointer: UnsafeMutablePointer<CChar>?
        var stderrPointer: UnsafeMutablePointer<CChar>?
        let code = cbpy_run(source, &stdoutPointer, &stderrPointer)
        let output = stdoutPointer.map { String(cString: $0) } ?? ""
        let errorText = stderrPointer.map { String(cString: $0) } ?? ""
        if let stdoutPointer { cbpy_free(stdoutPointer) }
        if let stderrPointer { cbpy_free(stderrPointer) }

        // `code` already says whether the snippet raised. Re-testing the stderr
        // text here marked a successful run failed whenever the script wrote to
        // stderr -- a warning, or print(..., file=sys.stderr).
        var diagnostics: [String] = []
        if !errorText.isEmpty { diagnostics.append(errorText) }
        return .init(output: output, diagnostics: diagnostics, succeeded: code == 0)
        #else
        return .init(output: "", diagnostics: ["Python was not linked into this app build."], succeeded: false)
        #endif
    }

    #if canImport(CrossBuildPython)
    /// Starts the interpreter once per process. Py_Initialize must not be called
    /// twice, so the attempt is memoised and a failure is reported on every run
    /// rather than retried silently.
    ///
    /// This is a `static let`, not two `static var`s guarded by an `if`: the
    /// function is nonisolated and reachable from the cooperative pool, so the old
    /// check-then-set was a data race that could enter Py_Initialize twice. A lazy
    /// global's initialiser runs exactly once, thread-safely.
    static func ensureStarted() -> String? { startResult }

    private static let startResult: String? = {
        guard let resourcePath = Bundle.main.resourceURL?.path else {
            return "No bundle resource path available."
        }
        let pythonHome = resourcePath + "/python"
        let libPath = pythonHome + "/lib/python3.13"
        let dynloadPath = libPath + "/lib-dynload"
        let appPath = resourcePath + "/app"

        guard FileManager.default.fileExists(atPath: libPath) else {
            return "Standard library missing at python/lib/python3.13 in the app bundle."
        }

        let searchPath = [libPath, dynloadPath, appPath].joined(separator: ":")
        let code = cbpy_start(pythonHome, searchPath)
        if code != 0 {
            return "Python failed to start (code \(code))."
        }
        return nil
    }()
    #endif
}
