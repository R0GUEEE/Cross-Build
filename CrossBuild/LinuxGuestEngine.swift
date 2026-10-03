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

    enum GuestError: LocalizedError {
        case rootNotBundled
        var errorDescription: String? {
            switch self {
            case .rootNotBundled:
                return "The Linux rootfs image is not present in this build."
            }
        }
    }

    /// Path of the rootfs image shipped inside the app bundle.
    static var bundledRootPath: String? {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("fakefs-root", isDirectory: true) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    static var isRootBundled: Bool { bundledRootPath != nil }

    /// The guest needs a *writable* root — `apk add` and ordinary file writes are
    /// the point — but the copy inside the app bundle is read-only. So the
    /// bundled image is copied into the app's Documents the first time the guest
    /// is used, and the guest boots from that copy.
    static func prepareWritableRoot() throws -> String {
        guard let bundled = bundledRootPath else { throw GuestError.rootNotBundled }
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw GuestError.rootNotBundled
        }
        let destination = documents.appendingPathComponent("CrossBuild/linux-root", isDirectory: true)
        if fm.fileExists(atPath: destination.path) { return destination.path }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(atPath: bundled, toPath: destination.path)
        return destination.path
    }

    /// Where the guest should boot from: the writable copy, created on first use.
    static var defaultRootPath: String? {
        try? prepareWritableRoot()
    }
}
