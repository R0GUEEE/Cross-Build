# Cross-Build runtime architecture

Cross-Build uses two deliberately separate execution layers.

## 1. iOS-native toolchain layer

Compilers, language runtimes and build-system dependencies belong to the application. They are packaged as static libraries, XCFrameworks, and read-only resource payloads under `NativeToolchains/`. SDK headers and support data are resources; executable compiler logic must be linked into the signed application.

The embedded Linux root is **not** a compiler distribution. Do not install LLVM/Clang, GCC, LLD, Swift, Rust/Cargo, Go, Zig, Python, CMake, Ninja or Meson into `fakefs-root`.

The existing `CrossBuildClang` bridge is only an ABI adapter until LLVM/clangDriver is linked behind it. New toolchains should follow the same adapter pattern and report unavailable until their native payload is actually linked.

## 2. ios-linuxkit runtime layer

The Linux compatibility layer is based on [rcarmo/ios-linuxkit](https://github.com/rcarmo/ios-linuxkit), pinned by CI. Its fakefs contains only the minimal Alpine userland needed for shell/POSIX compatibility, source transport and workspace operations.

The shipped guest package allow-list is maintained in `ToolchainRuntimeArchitecture.guestRuntimePackages` and mirrored by CI. CI fails if a compiler or build-system executable leaks into the image.

### How a command reaches the guest

The guest boots **once per launch** with `/bin/sh` and stays up; commands are streamed to it, each followed by a sentinel echo so the reader knows where one command's output ends. `LinuxGuestSession.script(for:invocation:)` is the only place a command is turned into a shell script, and it is where the Embedded Shell settings take effect:

- **Shell** — the session shell is always `/bin/sh` (the one shell the root is guaranteed to carry). Any other value is started as a child of it, which also means `cd`/`export` cannot carry over between commands.
- **Login shell** — sources `/etc/profile` (or the child shell's own `-l`).
- **Interactive shell** — `-i` on the child shell.
- **Persistent terminal session** — off gives every command its own subshell.
- **Initialization command** — run once after boot; its output is shown with the next command.
- **Working directory / environment** — exported into the command's shell. Note the guest has its **own** filesystem image (`Documents/CrossBuild/linux-root`), so an iOS container path is not a directory inside it; the session says so and runs in the guest's current directory instead of failing the command. Only an explicit working-directory override is sent for that reason.

The command timeout is measured with the monotonic clock, not by counting poll iterations: the loop used to advance its own budget by 100 ms per 4 KB read, which capped output at about 40 KB/s and reported a *timeout* for any command that printed more than that. A guest shell that exits (a command ran `exit`) is now reported as such and closes the session, instead of being indistinguishable from a deadline.

### How a build reaches the guest

The guest boots from its own filesystem image, so nothing the iOS workspace holds
exists inside it until it is copied there. Every build is therefore
**copy, then run**, and the copy is the part that decides whether the app or the
compiler is the slow one:

- `GuestWorkspaceSync` copies the project to `/workspace`. Only files whose bytes
  changed are sent at all (SHA-256 per file, recorded in `GuestStateStore`), text
  travels as a quoted here-document rather than base64, and one `mkdir -p` covers
  the whole push. Files the project no longer has are removed, so a rename cannot
  leave an old translation unit behind for the compiler to pick up.
- Everything that reads the project tree -- `make`, `swift build`, `cargo build`,
  the package step -- runs through `WorkspaceModel.inGuestProject(_:)`, which is
  the only place that knows where the project lives inside the guest.
- A single source compiles to an object named after its whole relative path under
  `/tmp/crossbuild-obj`, so two files with the same base name cannot collide and
  an unchanged file's object can be reused.
- `compileAllIndividualSources` compiles in groups, all at once inside the guest,
  with each file's output captured separately and replayed in order. The group size
  is the "Build jobs" setting, the same one `make -j` uses.

`GuestStateStore` persists what the guest already holds, beside the guest root it
describes (`Documents/CrossBuild/guest-state.json`). Because the guest's image is
reused across launches, so are the copied files and the objects; without that
record every launch copied the whole project into a guest that already had it and
then recompiled it. The record stores its guest root's file id and creation date
and is discarded when they no longer match, because a root that has been deleted
and recreated holds none of it.

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
