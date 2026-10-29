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
    ///
    /// The copy is built beside the destination and renamed into place, and it
    /// carries a marker naming the build it came from. Copying straight into the
    /// destination meant an interrupted first run (backgrounded, disk full, killed)
    /// left a truncated root that was then accepted forever, and an app update that
    /// shipped a new rootfs never replaced the old one.
    static func prepareWritableRoot() throws -> String {
        guard let bundled = bundledRootPath else { throw GuestError.rootNotBundled }
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw GuestError.rootNotBundled
        }
        let destination = documents.appendingPathComponent("CrossBuild/linux-root", isDirectory: true)
        let marker = documents.appendingPathComponent("CrossBuild/linux-root.build")
        let build = bundledBuildID

        if fm.fileExists(atPath: destination.path),
           (try? String(contentsOf: marker, encoding: .utf8)) == build {
            return destination.path
        }

        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent("linux-root.staging-\(UUID().uuidString)", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.copyItem(atPath: bundled, toPath: staging.path)
        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }
        try fm.moveItem(at: staging.path, to: destination.path)
        try? build.write(to: marker, atomically: true, encoding: .utf8)
        return destination.path
    }

    /// Identifies the bundled rootfs: its recorded build number when there is one,
    /// otherwise the modification date of the image. Either changes when the app
    /// ships a different root.
    private static var bundledBuildID: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleVersion"] as? String ?? "0"
        let short = info["CFBundleShortVersionString"] as? String ?? "0"
        var stamp: TimeInterval = 0
        if let path = bundledRootPath,
           let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           let date = attributes[.modificationDate] as? Date {
            stamp = date.timeIntervalSince1970
        }
        return "\(short)-\(version)-\(Int(stamp))"
    }
}
