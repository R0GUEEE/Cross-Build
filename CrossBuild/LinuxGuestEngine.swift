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
        guard let destination = writableRootURL else { throw GuestError.rootNotBundled }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { return destination.path }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(atPath: bundled, toPath: destination.path)
        return destination.path
    }

    /// Where the writable copy lives, inside the app's Documents.
    ///
    /// Shared because something other than the boot has to be able to *recognise*
    /// the root without creating one: the state store decides whether what it
    /// remembers is still about the guest that is present, and asking
    /// `prepareWritableRoot()` would copy a whole filesystem image to find out.
    static var writableRootURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CrossBuild/linux-root", isDirectory: true)
    }
}
