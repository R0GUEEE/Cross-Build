import Foundation

/// An Apple SDK, made available inside the Linux guest.
///
/// An `.sdk` folder dropped into `Documents/SDKs` was previously counted, listed
/// and exported as `SDKROOT` -- and then ignored, because the compiler runs in the
/// guest, where that path does not exist and where gcc never reads `SDKROOT`
/// anyway. This copies the SDK into the guest once per build and produces the two
/// things a cross compiler actually consumes on that side:
///
///   * `--sysroot=` for the driver (headers, libraries, crt objects), and
///   * `-F/usr/lib/swift` for the Swift standard library that ships inside the SDK.
///
/// It is deliberately conservative: an SDK is ~1 GB and the guest is an emulated
/// filesystem, so a small one is copied whole, a large one is reduced to the parts
/// a compiler reads, and either way the result is stamp-checked so a second build
/// pays nothing.
enum SDKInjection {
    /// Where an imported SDK lives inside the guest.
    static let guestRoot = "/opt/apple-sdk"

    /// Above this size the copy is limited to the directories a compiler reads.
    /// A full iPhoneOS SDK is far larger than this; the parts a cross compile needs
    /// are the headers, the device slice archives and the Swift modules.
    private static let fullCopyLimit: Int64 = 700 * 1024 * 1024

    struct Result {
        var sysroot: String?
        var frameworkPaths: [String]
        var notes: [String]
        var applied: Bool
    }

    /// The SDK that should be used for this project, if any.
    ///
    /// Explicit settings win: a `sysroot` typed in Compiler Configuration, then a
    /// workspace `sdkPath`, and only then whatever was auto-discovered in an SDK
    /// folder. A user who has pointed at an SDK should not be overruled by a newer
    /// one happening to sit in Documents.
    static func selectedSDK(workspace: WorkspaceModel) -> URL? {
        let workspaceSDK = workspace.configuration.sdkPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !workspaceSDK.isEmpty,
           FileManager.default.fileExists(atPath: workspaceSDK) {
            return URL(fileURLWithPath: workspaceSDK, isDirectory: true)
        }
        let compilerSDK = workspace.compilerConfiguration.sysroot.trimmingCharacters(in: .whitespacesAndNewlines)
        if !compilerSDK.isEmpty,
           FileManager.default.fileExists(atPath: compilerSDK) {
            return URL(fileURLWithPath: compilerSDK, isDirectory: true)
        }
        return IOSSDKDiscovery.preferred()
    }

    /// Copies `sdk` into the guest if it is not already there, and returns what to
    /// add to the build's environment and command lines.
    ///
    /// Runs before the project push, because that push replaces the guest's
    /// `/workspace` and nothing else -- the SDK lives outside it, so it survives
    /// builds and only has to be re-imported when the SDK itself changes.
    @MainActor
    static func inject(_ sdk: URL, session: LinuxGuestSession = .shared) async -> Result {
        var notes: [String] = []
        let stamp = stamp(for: sdk)

        let existing = await session.run("cat \(guestRoot)/.stamp 2>/dev/null || true", timeout: 30)
        if existing.output.trimmingCharacters(in: .whitespacesAndNewlines) == stamp {
            notes.append("Apple SDK already in the guest (\(sdk.lastPathComponent)).")
            return .init(sysroot: sysroot(in: sdk, at: guestRoot),
                         frameworkPaths: frameworks(in: sdk).map { guestRoot + $0 },
                         notes: notes, applied: true)
        }

        let size = directorySize(sdk)
        let whole = size <= fullCopyLimit
        notes.append("Importing \(sdk.lastPathComponent) into the guest"
                     + (whole ? " (\(bytes(size)))." : " (headers and device slices only; \(bytes(size)) is more than the guest can hold whole)."))

        // What gets copied. A reduced copy keeps exactly the trees gcc/clang read:
        // the SDK's own sysroot layout, plus Swift's module and library trees.
        let subset = ["/usr"]
        let paths: [String]
        if whole { paths = [sdk.path] } else { paths = subset.map { $0 } }

        let listing = await Task.detached(priority: .utility) { () -> (files: [(String, Data)], skipped: Int) in
            var files: [(String, Data)] = []
            var skipped = 0
            let fm = FileManager.default
            guard let walker = fm.enumerator(at: sdk, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
                return (files, skipped)
            }
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true else { continue }
                let relative = "/" + url.path.dropFirst(sdk.path.count + 1)
                if !whole && !paths.contains(where: { relative.hasPrefix($0 + "/") }) { continue }
                // 512 KB per file: the same cap the project sync uses, so a single
                // encoding never has to hold more than one member.
                guard let size = values.fileSize, size <= GuestWorkspaceSync.maximumItemBytes,
                      let data = fm.contents(atPath: url.path) else { skipped += 1; continue }
                files.append((relative, data))
            }
            return (files, skipped)
        }.value

        guard !listing.files.isEmpty else {
            notes.append("No files under \(sdk.lastPathComponent) could be read; nothing was imported.")
            return .init(sysroot: nil, frameworkPaths: [], notes: notes, applied: false)
        }
        if listing.skipped > 0 {
            notes.append("\(listing.skipped) file(s) were skipped (larger than "
                         + "\(GuestWorkspaceSync.maximumItemBytes / 1024) KB or unreadable).")
        }

        _ = await session.run("rm -rf \(guestRoot) && mkdir -p \(guestRoot)", timeout: 120)
        let sync = GuestWorkspaceSync()
        var items: [GuestWorkspaceSync.Item] = listing.files.map {
            .init(relativePath: String($0.0.dropFirst()), data: $0.1)
        }
        items.append(.init(relativePath: ".stamp", data: Data((stamp + "\n").utf8)))

        let pushed = await sync.push(items, root: guestRoot, session: session)
        guard pushed.complete else {
            notes.append("Importing the SDK failed: \(sync.lastSummary)")
            return .init(sysroot: nil, frameworkPaths: [], notes: notes, applied: false)
        }
        notes.append("\(pushed.pushed) file(s) imported: \(sync.lastSummary)")
        notes.append("Builds now use --sysroot=\(sysroot(in: sdk, at: guestRoot)).")

        return .init(sysroot: sysroot(in: sdk, at: guestRoot),
                     frameworkPaths: frameworks(in: sdk).map { guestRoot + $0 },
                     notes: notes, applied: true)
    }

    /// Which directory is the sysroot *inside* the imported copy.
    ///
    /// Two shapes arrive in practice: a `.sdk` bundle already rooted at the SDK
    /// (`Documentation/`, `usr/`, `SDKSettings.plist`), and a folder that merely
    /// *contains* an SDK (`iPhoneOS18.2.sdk/`). One level down is checked for the
    /// markers of the first shape; the extra level is added only when it holds one.
    private static func sysroot(in sdk: URL, at root: String) -> String {
        let markers = ["SDKSettings.plist", "usr"]
        let hasMarkers = { (dir: URL) in
            markers.contains { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        }
        if hasMarkers(sdk) { return root }
        let inner = root + "/" + sdk.lastPathComponent
        if hasMarkers(sdk.appendingPathComponent(sdk.lastPathComponent)) { return inner }
        // Neither shape: point at the copied root and let the linker say what it
        // could not find, rather than guessing a level that may not exist.
        return root
    }

    /// Swift framework directories that exist inside the SDK, as guest paths.
    private static func frameworks(in sdk: URL) -> [String] {
        let candidates = ["/usr/lib/swift", "/usr/lib/swift/iphoneos"]
        return candidates.filter {
            FileManager.default.fileExists(atPath: sdk.appendingPathComponent($0).path)
        }
    }

    /// Identifies an SDK by its files, not its path: replacing the folder with a
    /// different build of the same name must re-import.
    private static func stamp(for sdk: URL) -> String {
        var size: Int64 = 0
        var count = 0
        if let walker = FileManager.default.enumerator(at: sdk, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in walker {
                if let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let s = values.fileSize {
                    size += Int64(s)
                    count += 1
                }
            }
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: sdk.path)[.modificationDate]) as? Date
        return "\(sdk.lastPathComponent):\(count):\(size):\(Int(modified?.timeIntervalSince1970 ?? 0))"
    }

    private static func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let file as URL in walker {
                if let values = try? file.resourceValues(forKeys: [.fileSizeKey]), let s = values.fileSize {
                    total += Int64(s)
                }
            }
        }
        return total
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
