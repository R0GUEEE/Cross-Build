# Cross-Build runtime architecture

Cross-Build uses two deliberately separate execution layers.

## 1. iOS-native toolchain layer

Compilers, language runtimes and build-system dependencies belong to the application. They are packaged as static libraries, XCFrameworks, and read-only resource payloads under `NativeToolchains/`. SDK headers and support data are resources; executable compiler logic must be linked into the signed application.

The embedded Linux root is **not** a compiler distribution. Do not install LLVM/Clang, GCC, LLD, Swift, Rust/Cargo, Go, Zig, Python, CMake, Ninja or Meson into `fakefs-root`.

The existing `CrossBuildClang` bridge is only an ABI adapter until LLVM/clangDriver is linked behind it. New toolchains should follow the same adapter pattern and report unavailable until their native payload is actually linked.

## 2. ios-linuxkit runtime layer

The Linux compatibility layer is based on [rcarmo/ios-linuxkit](https://github.com/rcarmo/ios-linuxkit), pinned by CI. Its fakefs contains only the minimal Alpine userland needed for shell/POSIX compatibility, source transport and workspace operations.

The shipped guest package allow-list is maintained in `ToolchainRuntimeArchitecture.guestRuntimePackages` and mirrored by CI. CI fails if a compiler or build-system executable leaks into the image.

## AOT policy

The target configuration is ios-linuxkit native AOT with runtime native-code emission disabled:

- `jit=true`
- `jit_emit=false`
- generated Mach-O AOT assembly linked into the iOS application
- gadget interpreter retained as fallback for uncovered/rejected guest code

This is intentionally different from the current gadget-only `jit=false` build.

Upstream ios-linuxkit 2.4.1 documents the Apple AOT path as integration work rather than an existing production scheme. In particular, `cli_aot` only links images into the CLI; an iOS app must add generated assembly to app build membership, keep matching backend/frame definitions across translation units, link image constructors, and install the native precise-fault recovery adapter.

Cross-Build therefore uses this migration sequence:

1. Strip compiler/build packages from fakefs.
2. Move each compiler/runtime behind an iOS-native library adapter.
3. Add a separate AOT engine build so the gadget baseline remains buildable.
4. Produce/verify a pinned AOT seed for the exact Alpine guest modules.
5. Generate Mach-O AOT images against the exact bootstrap app ABI.
6. Link images and native fault recovery into the AOT app target.
7. Verify `jit_emit=false`, image acceptance, gadget fallback, signing and physical-device execution before making AOT the default.

Do not call a `jit=false` build AOT, and do not enable runtime executable-memory emission as a shortcut.
