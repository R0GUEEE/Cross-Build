import Foundation

/// Defines the hard boundary between Cross-Build's iOS-native toolchain layer
/// and the embedded Linux compatibility runtime.
///
/// Compiler executables must never be provisioned into fakefs-root. Toolchains
/// are linked into the app as static libraries/XCFrameworks (plus read-only
/// resource payloads such as SDK headers). The Linux guest remains a minimal
/// ios-linuxkit userland for shell/POSIX compatibility and project tooling.
enum ToolchainRuntimeArchitecture {
    static let linuxRuntimeProvider = "rcarmo/ios-linuxkit"
    static let linuxRuntimeMode = "AOT-ready / no runtime emission"

    /// Packages intentionally allowed in the shipped Alpine image.
    static let guestRuntimePackages = [
        "bash", "coreutils", "findutils", "grep", "sed", "gawk",
        "git", "tar", "gzip", "xz", "ca-certificates"
    ]

    /// Executables that indicate a packaging regression if they appear in the
    /// bundled Linux root. CI enforces the same list.
    static let forbiddenGuestBuildTools = [
        "clang", "clang++", "gcc", "g++", "ld.lld", "cmake", "ninja",
        "meson", "python3", "cargo", "rustc", "go", "zig", "swift"
    ]

    /// Native payload location used by app-owned toolchain adapters.
    /// Each payload can contain an XCFramework/static library, headers, SDK
    /// resources and a manifest, but never a Linux package tree.
    static func payloadURL(for id: String) -> URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("NativeToolchains", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    static func hasPayload(for id: String) -> Bool {
        guard let url = payloadURL(for: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// What the payload manifest says, when one is bundled.
    ///
    /// The manifest is written by the workflow that builds the payload, so it
    /// names the LLVM revision that was actually linked. Reading it is the
    /// difference between "a compiler should be linked in" and knowing which one.
    struct PayloadManifest: Decodable {
        var id: String
        var llvmRevision: String?
        var architectures: [String]?
        var libraries: Int?
        var builtAt: String?
    }

    static func manifest(for id: String) -> PayloadManifest? {
        guard let url = payloadURL(for: id)?.appendingPathComponent("manifest.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PayloadManifest.self, from: data)
    }

    /// True when an app-owned compiler is actually linked in and usable.
    ///
    /// This is the contract the whole design rests on: compilers belong to the
    /// signed application, and the Linux guest is not a compiler distribution.
    /// Until this is true there is no compile path at all, which is a state the
    /// UI has to be able to state plainly rather than discover through
    /// `command not found` in a console nobody is reading.
    static var hasLinkedCompiler: Bool {
        hasPayload(for: "clang") && ClangEmbeddedBridge().isLinked
    }

    /// The sentence to show when nothing can compile.
    static var unavailableReason: String {
        "No compiler is linked into this build. Cross Build's toolchain is meant to be "
        + "app-owned (docs/RUNTIME_ARCHITECTURE.md), and the Linux guest deliberately "
        + "carries no compiler, so a compile cannot run yet."
    }
}
