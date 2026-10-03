import Foundation

/// One thing that ships inside the app bundle.
///
/// The inventory is produced by *inspecting the built app at runtime* rather than
/// from a hardcoded wish list, so "preincluded" is something the app can prove
/// about itself instead of assert.
struct BundledResource: Identifiable {
    var id: String
    var name: String
    var detail: String
    var location: String
    var present: Bool
    var sizeBytes: Int64
    var execution: BundledExecution
    var icon: String
}

enum BundledExecution: String {
    case inProcess = "Runs in-process"
    case supportData = "Support data"
    case needsHost = "Needs a host"
}

enum BundledResources {
    /// Everything the app can honestly claim to contain. Entries whose files are
    /// absent are reported as missing rather than quietly omitted.
    static func inventory() -> [BundledResource] {
        var items: [BundledResource] = []

        // In-process engines: these genuinely run on the device with no helper.
        items.append(BundledResource(
            id: "javascriptcore",
            name: "JavaScriptCore",
            detail: "Evaluates JavaScript in-process and captures console output.",
            location: "System framework",
            present: true,
            sizeBytes: 0,
            execution: .inProcess,
            icon: "curlybraces"
        ))

        let clangBridge = ClangEmbeddedBridge()
        items.append(BundledResource(
            id: "crossbuildclang",
            name: "CrossBuildClang bridge",
            detail: clangBridge.isLinked
                ? "C ABI compiled into this binary. It reports an honest failure because no LLVM/clangDriver payload is vendored behind it yet."
                : "Not linked into this build.",
            location: "Statically linked",
            present: clangBridge.isLinked,
            sizeBytes: 0,
            execution: .inProcess,
            icon: "hammer"
        ))

        let pythonEngine = PythonEmbeddedEngine()
        let pythonStdlib = Bundle.main.resourceURL?
            .appendingPathComponent("python/lib/python3.13", isDirectory: true)
        let pythonStdlibPresent = pythonStdlib.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        items.append(BundledResource(
            id: "python3",
            name: "Python 3",
            detail: pythonStdlibPresent
                ? "Embedded CPython interpreter and standard library. Runs fully in-process — no helper, no host. Compiled extension modules (math, ssl, …) load with dlopen from lib-dynload, which works on a signed install; run the self-test below to confirm on your build."
                : "Interpreter is linked but the standard library was not found in the bundle.",
            location: "Python.framework + python/ stdlib",
            present: pythonEngine.isLinked && pythonStdlibPresent,
            sizeBytes: pythonStdlib.map(directorySize) ?? 0,
            execution: .inProcess,
            icon: "chevron.left.forwardslash.chevron.right"
        ))

        items.append(BundledResource(
            id: "linux",
            name: "Linux guest (ios-linuxkit)",
            detail: LinuxGuestEngine.isLinked
                ? "AArch64 Linux userland running in-process with the asbestos threaded-code interpreter. No process is spawned and no JIT entitlement is needed, so it works on a stock sideload. The Alpine rootfs still has to be built into a fakefs image before it has anything to boot."
                : "Engine not linked into this build.",
            location: "Statically linked (libish + libish_emu + libfakefs)",
            present: LinuxGuestEngine.isLinked,
            sizeBytes: 0,
            execution: .inProcess,
            icon: "terminal.fill"
        ))

        // Bundled support data.
        items.append(resourceItem(
            id: "helper",
            name: "CrossBuild Helper",
            detail: "The process-execution helper. Bundled so a host needs no download to run it — the app can export it straight to Documents.",
            resource: "crossbuild-helper",
            extension: "py",
            execution: .supportData,
            icon: "terminal"
        ))

        items.append(directoryItem(
            id: "toolchains",
            name: "Toolchain manifests",
            detail: "Per-toolchain descriptors used by the catalogue and Full Setup.",
            directoryName: "Toolchains",
            icon: "shippingbox"
        ))

        return items
    }

    /// Capabilities that deliberately cannot be bundled, with the reason. These
    /// are listed explicitly so the app never implies it ships something it
    /// cannot.
    static let unavailable: [(name: String, reason: String)] = [
        ("LLVM / Clang binaries",
         "A toolchain binary cannot be bundled and executed on iOS: a sideloaded app cannot spawn processes, and iOS will not run unsigned code copied into the bundle. This is why compilation goes through the CrossBuild Helper on a host or jailbroken device."),
        ("Swift / Rust / Go / Zig toolchains",
         "Same constraint as above, plus size — these are hundreds of megabytes to well over a gigabyte each, which is not practical to embed in an app bundle."),
        ("Apple iOS SDK",
         "Not redistributable. It has to come from Xcode on a macOS build host."),
        ("Theos",
         "Distributed as a source checkout with its own toolchain expectations; installed on the host that does the building.")
    ]

    // MARK: Export

    /// Writes the bundled helper next to the user's documents so it can be run
    /// immediately with the system python3 — no download, no copy-paste.
    static func exportHelper() throws -> URL {
        guard let source = Bundle.main.url(forResource: "crossbuild-helper", withExtension: "py") else {
            throw ExportError.notBundled
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = documents.appendingPathComponent("CrossBuild", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("crossbuild-helper.py")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    enum ExportError: LocalizedError {
        case notBundled
        var errorDescription: String? {
            switch self {
            case .notBundled:
                return "crossbuild-helper.py is not present in this build's resources."
            }
        }
    }

    /// Suggested command for running the exported helper.
    static func runCommand(for url: URL) -> String {
        "python3 \(url.path) --host 127.0.0.1 --port 8765"
    }

    // MARK: Bundle inspection

    private static func resourceItem(id: String,
                                     name: String,
                                     detail: String,
                                     resource: String,
                                     extension ext: String,
                                     execution: BundledExecution,
                                     icon: String) -> BundledResource {
        let url = Bundle.main.url(forResource: resource, withExtension: ext)
        return BundledResource(
            id: id,
            name: name,
            detail: detail,
            location: url?.lastPathComponent ?? "not found",
            present: url != nil,
            sizeBytes: url.map(fileSize) ?? 0,
            execution: execution,
            icon: icon
        )
    }

    private static func directoryItem(id: String,
                                      name: String,
                                      detail: String,
                                      directoryName: String,
                                      icon: String) -> BundledResource {
        let url = Bundle.main.resourceURL?.appendingPathComponent(directoryName, isDirectory: true)
        let exists = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return BundledResource(
            id: id,
            name: name,
            detail: detail,
            location: exists ? "\(directoryName)/" : "not found",
            present: exists,
            sizeBytes: exists ? (url.map(directorySize) ?? 0) : 0,
            execution: .supportData,
            icon: icon
        )
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}
