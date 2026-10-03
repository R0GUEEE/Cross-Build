import Foundation
#if canImport(CrossBuildLinux)
import CrossBuildLinux
#endif

/// The embedded Linux guest.
///
/// ios-linuxkit is an optimised iSH fork: it runs an AArch64 Linux userland
/// in-process with a threaded-code interpreter. No process is ever spawned and no
/// JIT entitlement is needed, which is why a real Linux userland — and therefore
/// real toolchains — can run on a stock sideload.
///
/// This type is also what keeps the engine in the binary: the engine and this shim
/// are static libraries, and a C symbol nothing references is dead-stripped, so
/// without a Swift caller both would silently vanish from the app.
enum LinuxGuestEngine {
    static let id = "linux"
    static let name = "Linux guest"

    static var isLinked: Bool {
        #if canImport(CrossBuildLinux)
        return true
        #else
        return false
        #endif
    }

    static var version: String {
        #if canImport(CrossBuildLinux)
        return String(cString: cblk_engine_version())
        #else
        return "Linux engine not linked"
        #endif
    }

    /// True once the guest has been booted. The interpreter keeps process-global
    /// state, so a second boot in the same process is refused rather than
    /// producing a corrupt guest.
    static var hasBooted: Bool {
        #if canImport(CrossBuildLinux)
        return cblk_has_booted() != 0
        #else
        return false
        #endif
    }

    struct Result: Sendable {
        var exitCode: Int32
        var output: String
        var error: String
        var succeeded: Bool { exitCode == 0 }
    }

    /// Boots the guest from a fakefs root and runs one command to completion.
    /// Must be called off the main thread: it blocks for as long as the command
    /// takes, and the guest's own thread does the work.
    static func run(command: String, fakefsRoot: String, workingDirectory: String? = nil) -> Result {
        #if canImport(CrossBuildLinux)
        var outPointer: UnsafeMutablePointer<CChar>?
        var errPointer: UnsafeMutablePointer<CChar>?
        let code = cblk_boot_and_run(fakefsRoot, workingDirectory, command, &outPointer, &errPointer)
        let output = outPointer.map { String(cString: $0) } ?? ""
        let errorText = errPointer.map { String(cString: $0) } ?? ""
        return Result(exitCode: code, output: output, error: errorText)
        #else
        return Result(exitCode: -1, output: "", error: "Linux engine was not linked into this build.")
        #endif
    }

    /// Where the fakefs root would live. The image itself still has to be built
    /// from the Alpine minirootfs before the guest has anything to boot from.
    static var defaultRootPath: String? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documents.appendingPathComponent("CrossBuild/linux-fakefs", isDirectory: true).path
    }
}
