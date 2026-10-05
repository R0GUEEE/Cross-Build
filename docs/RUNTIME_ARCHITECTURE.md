# Cross-Build runtime architecture

Cross-Build uses two deliberately separate execution layers.

## 1. iOS-native toolchain layer

Compilers, language runtimes and build-system dependencies belong to the application. They are packaged as static libraries, XCFrameworks, and read-only resource payloads under `NativeToolchains/`. SDK headers and support data are resources; executable compiler logic must be linked into the signed application.

The embedded Linux root **is** a C/C++ build environment. It carries `make`, `gcc`, `g++`, `musl-dev` and `binutils`, and CI asserts both that they are present and that they can compile and link a program -- a Build button that reports `not found` is worse than a larger download.

This reverses an earlier decision. The guest used to be runtime-only, on the reasoning that compilers belong to the iOS application; the consequence was that every build action called a tool that was not there, because the app-owned compiler was never finished. Until that work is done, the guest is where the toolchain lives.

Still excluded, and still asserted absent by CI: `clang`, `ld.lld`, `cmake`, `ninja`, `meson`, `python3`, `cargo`, `rustc`, `go`, `zig`, `swift`. Each would add its own large tree, and for those the app-owned adapter is the better answer.

The existing `CrossBuildClang` bridge is only an ABI adapter until LLVM/clangDriver is linked behind it. New toolchains should follow the same adapter pattern and report unavailable until their native payload is actually linked.

The bridge is **not** on the critical path any more: C and C++ compile through the guest's GNU toolchain today. The adapter remains the intended home for a future app-owned compiler, and `.github/workflows/native-toolchains.yml` is the workflow that would build it.

## 2. ios-linuxkit runtime layer

The Linux compatibility layer is based on [rcarmo/ios-linuxkit](https://github.com/rcarmo/ios-linuxkit), pinned by CI. Its fakefs carries the minimal Alpine userland needed for shell/POSIX compatibility, source transport, workspace operations, and the GNU C/C++ toolchain described above -- and nothing else.

The shipped guest package allow-list is maintained in `ToolchainRuntimeArchitecture.guestRuntimePackages`. CI hardcodes its own copy of that list as `RUNTIME_PACKAGES`, installs it, and then asserts the required executables are present; the two lists can drift and should be kept in step. CI fails if a **forbidden** tool leaks into the image -- clang, ld.lld, cmake, ninja, meson, python3, cargo, rustc, go, zig or swift -- not if `gcc` does, because `gcc` is required.

### How a command reaches the guest

The guest boots **once per launch** with `/bin/sh` and stays up; commands are streamed to it, each followed by a sentinel echo so the reader knows where one command's output ends. `LinuxGuestSession.script(for:invocation:)` is the only place a command is turned into a shell script, and it is where the Embedded Shell settings take effect:

- **Shell** — the session shell is always `/bin/sh` (the one shell the root is guaranteed to carry). Any other value is started as a child of it, which also means `cd`/`export` cannot carry over between commands.
- **Login shell** — sources `/etc/profile` (or the child shell's own `-l`).
- **Interactive shell** — `-i` on the child shell.
- **Persistent terminal session** — off gives every command its own subshell.
- **Initialization command** — run once after boot; its output is shown with the next command.
- **Working directory / environment** — exported into the command's shell. Note the guest has its **own** filesystem image (`Documents/CrossBuild/linux-root`), so an iOS container path is not a directory inside it; the session says so and runs in the guest's current directory instead of failing the command. Only an explicit working-directory override is sent for that reason.

The command timeout is measured with the monotonic clock, not by counting poll iterations: the loop used to advance its own budget by 100 ms per 4 KB read, which capped output at about 40 KB/s and reported a *timeout* for any command that printed more than that. A guest shell that exits (a command ran `exit`) is now reported as such and closes the session, instead of being indistinguishable from a deadline.

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
