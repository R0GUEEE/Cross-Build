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
}
