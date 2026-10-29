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
        case insufficientSpace(required: Int64, available: Int64)
        var errorDescription: String? {
            switch self {
            case .rootNotBundled:
                return "The Linux rootfs image is not present in this build."
            case .insufficientSpace(let required, let available):
                let need = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
                let have = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                return "The Linux guest needs about \(need) of free space to unpack its root filesystem; "
                    + "\(have) is available. Free some space and relaunch."
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

    /// Where the shim appends boot progress. Readable from the diagnostics screen,
    /// which is the only way to tell a boot that stalled from one that never ran.
    static var bootLogURL: URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return documents.appendingPathComponent("CrossBuild/guest-boot.log")
    }

    /// Last few lines of the boot log, oldest first.
    static func bootLogTail(_ lines: Int = 24) -> [String] {
        guard let url = bootLogURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").suffix(lines).map { $0 }
    }

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
        // The guest root is a full copy of the bundled tree -- hundreds of megabytes
        // -- and the failure mode when the device is short of space is a boot error
        // with an unhelpful code. Say what is needed and what is free.
        let needed = directorySize(bundled)
        var free: Int64 = 0
        if let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            free = capacity
        }
        if needed > 0, free > 0, free < needed + needed / 4 {
            throw GuestError.insufficientSpace(required: needed, available: free)
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
        try fm.moveItem(at: staging, to: destination)
        try? build.write(to: marker, atomically: true, encoding: .utf8)
        return destination.path
    }

    /// Total size of every file below `path`.
    private static func directorySize(_ path: String) -> Int64 {
        guard let walker = FileManager.default.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        for case let name as String in walker {
            let full = (path as NSString).appendingPathComponent(name)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: full),
               let size = attributes[.size] as? Int64 {
                total += size
            }
        }
        return total
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
