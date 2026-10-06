import Foundation

struct BundledResource: Identifiable {
    var id: String
    var name: String
    var detail: String
    var location: String
    var present: Bool
    var sizeBytes: Int64
    var execution: BundledExecution
    var icon: String
    /// The guest executables that satisfy this entry, when the app ships no
    /// payload for it. Nil means genuinely unavailable.
    var guestBacked: String? = nil
}

enum BundledExecution: String {
    case inProcess = "Runs in-process"
    case supportData = "Bundled support"
}

enum BundledResources {
    /// Runtime inventory derived from the installed IPA. No host/helper state is
    /// consulted, so the result describes what this copy of Cross Build can use.
    static func inventory() -> [BundledResource] {
        var items = AppToolchainLibraries.scanBundle().map { scan in
            BundledResource(
                id: "toolchain-\(scan.id)",
                name: scan.name,
                detail: scan.detail,
                location: scan.location,
                present: scan.present,
                sizeBytes: 0,
                execution: .inProcess,
                icon: scan.present ? "shippingbox.fill" : "shippingbox",
                // Carried through rather than dropped: the scan knows the guest
                // can satisfy this entry, and without this the row called it
                // "Not bundled" while make or gcc was installed and working.
                guestBacked: scan.guestBacked
            )
        }

        items.append(BundledResource(
            id: "linux",
            name: "ios-linuxkit runtime",
            detail: LinuxGuestEngine.isRootBundled
                ? "Embedded AArch64 Linux compatibility environment and rootfs are available for shell/POSIX workflows."
                : "The engine is linked but the bundled rootfs is missing.",
            location: LinuxGuestEngine.isRootBundled ? "Statically linked + fakefs-root" : "Statically linked",
            present: LinuxGuestEngine.isLinked && LinuxGuestEngine.isRootBundled,
            sizeBytes: 0,
            execution: .inProcess,
            icon: "terminal.fill"
        ))

        // "Bundled" means shipped inside the app. The old count also included
        // SDKs the user put in Documents/SDKs, so a build that ships none could
        // still display a non-zero "Bundled SDKs" value.
        let bundledSDKs = IOSSDKDiscovery.bundledSDKs().count
        let availableSDKs = IOSSDKDiscovery.availableSDKs().count
        items.append(BundledResource(
            id: "sdks",
            name: "Bundled SDKs",
            detail: bundledSDKs > 0
                ? "\(bundledSDKs) SDK payload(s) ship inside the app."
                : (availableSDKs > 0
                   ? "No SDK ships in the app; \(availableSDKs) user-supplied SDK(s) found under Documents/SDKs."
                   : "No SDK payload was discovered in the app bundle or in Documents/SDKs."),
            location: "SDKs/",
            present: availableSDKs > 0,
            sizeBytes: 0,
            execution: .supportData,
            icon: "square.stack.3d.up"
        ))
        return items
    }

    static var missingToolchains: [AppToolchainScan] {
        AppToolchainLibraries.missing
    }
}
