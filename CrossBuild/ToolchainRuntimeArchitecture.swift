import Foundation

/// Defines the hard boundary between Cross-Build's iOS-native toolchain layer
/// and the embedded Linux compatibility runtime.
///
/// Compiler executables must never be provisioned into fakefs-root. Toolchains
/// are linked into the app as static libraries/XCFrameworks (plus read-only
/// resource payloads such as SDK headers). The Linux guest remains a minimal
/// ios-linuxkit userland for shell/POSIX compatibility and project tooling.
enum ToolchainRuntimeArchitecture {
    /// Packages intentionally allowed in the shipped Alpine image.
    ///
    /// This used to be runtime-only, on the reasoning that compilers belong to
    /// the iOS app rather than the Linux image. The consequence was that no build
    /// action could run: the app's commands call `make` and `cc`, and neither was
    /// present, while the app-owned compiler that was supposed to replace them was
    /// never finished. A workbench whose Build button reports `not found` is not a
    /// workbench, so the toolchain is in the guest and CI asserts it is.
    static let guestRuntimePackages = [
        "bash", "coreutils", "findutils", "grep", "sed", "gawk",
        "git", "tar", "gzip", "xz", "ca-certificates",
        "make", "gcc", "g++", "musl-dev", "binutils",
        // `make package` is one of the app's four actions, and every Debian/Theos
        // packaging rule ends in dpkg-deb. Without these the button could only fail.
        "dpkg", "fakeroot",
        // Build systems and the runtimes their scripts need. Each is small enough
        // to belong in the image; the heavyweight language toolchains are not (see
        // `unbundledToolchains`).
        "cmake", "ninja-build", "meson", "python3", "py3-pip", "py3-setuptools",
        "py3-wheel", "py3-installer", "py3-packaging", "py3-pyproject-hooks",
        "pkgconf", "autoconf", "automake", "libtool", "nodejs", "npm",
        // Development headers and libraries a real build links against. Without
        // these the compilers are present and every `#include <zlib.h>` fails.
        "zlib-dev", "openssl-dev", "libffi-dev", "ncurses-dev", "readline-dev",
        "sqlite-dev", "bzip2-dev", "linux-headers"
    ]

    /// Executables that indicate a packaging regression if they appear in the
    /// bundled Linux root. CI enforces the same list.
    ///
    /// The C/C++ toolchain is deliberately no longer here. What remains is the
    /// stack the guest still does not carry: language runtimes and build systems
    /// whose app-owned equivalents are the better answer, and which would each add
    /// their own large tree.
    static let forbiddenGuestBuildTools = [
        "clang", "clang++", "ld.lld", "cargo", "rustc", "go", "zig", "swift", "javac", "kotlinc"
    ]

    /// Toolchains that are not in the image, with the reason, so the Build screen
    /// can say what a project needs instead of offering a button that fails.
    struct UnbundledToolchain: Identifiable {
        let id: String
        let reason: String
    }

    static let unbundledToolchains: [UnbundledToolchain] = [
        .init(id: "swift", reason: "No Swift toolchain for musl/aarch64; Apple's is macOS-only."),
        .init(id: "rust", reason: "Rust for aarch64 musl is ~180 MB installed, more than the whole app."),
        .init(id: "go", reason: "Go is ~173 MB installed."),
        .init(id: "zig", reason: "Zig is ~196 MB installed."),
        .init(id: "java", reason: "A headless JDK is ~170 MB installed."),
        .init(id: "kotlin", reason: "Kotlin needs a JDK plus the compiler, together over 250 MB.")
    ]

    /// The tools every build action invokes. CI asserts these are present.
    static let requiredGuestTools = ["make", "cc", "gcc", "c++", "g++"]

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
        // A directory is not a compiler. `hasPayload` only proves that
        // NativeToolchains/clang exists, and `isLinked` is a compile-time
        // `#if canImport` that is true in every build -- so both together said
        // "Clang is available" while `cb_clang_compile` returned 125 for every
        // request. The manifest is written by the workflow that actually builds
        // and links the LLVM payload, so its presence plus at least one library
        // is the smallest honest evidence available here.
        guard ClangEmbeddedBridge().isLinked, let manifest = manifest(for: "clang") else { return false }
        return (manifest.libraries ?? 0) > 0
    }

    // `unavailableReason` used to live here and said "the Linux guest
    // deliberately carries no compiler, so a compile cannot run yet" -- which
    // contradicted `guestRuntimePackages` directly above it and the CI step that
    // installs and asserts gcc/g++/musl-dev. It was also referenced nowhere.
    // The honest statement is `hasLinkedCompiler` alone.
}
