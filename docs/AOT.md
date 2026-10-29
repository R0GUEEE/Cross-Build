# Ahead-of-time execution: what is built, what is missing, and what it needs

This is the honest state of AOT in Cross Build, the reason the current build is
**gadget-only**, and the single piece of work that would change that.

## The target

ios-linuxkit's AOT mode links pre-translated guest code as Mach-O assembly into the
app. At runtime no executable memory is ever mapped, so it needs no JIT
entitlement — which is exactly what a sideloaded build can have.

Engine-side switches (see the engine's `docs/NATIVE_AOT_IOS.md`):

```
meson setup build-ios --cross-file cross-ios.txt \
  -Dguest_arch=arm64 -Djit=true -Djit_emit=false -Dcli_aot=<images> --buildtype=release
```

`jit=true` compiles `asbestos/guest-arm64/jit.c`; `jit_emit=false` turns on
`ISH_JIT_NO_EMIT`, which removes every code path that calls `mprotect`,
`MAP_JIT`, `PROT_EXEC` or `pthread_jit_write_protect_np`. `cli_aot=` takes the image
set to link.

## What blocks it here, in order

### 1. The images do not exist for this guest

With `jit=false` (what Cross Build builds today) the engine's meson **refuses**
`cli_aot`:

```
elif get_option('cli_aot').length() != 0
  error('cli_aot requires jit=true')
endif
```

`jit=true` is possible; the problem is the images. The engine's AOT images are not
generic. They are recorded against:

* the exact emulator ABI (`jit_layout`: `abi`, `prologue_words`, `entry_off`, `n_pinned`),
* the exact app binary (a symbol table from the built app),
* **the exact guest binaries** — the engine's own bootstrap records musl, BusyBox,
  Bun, Go, gofmt and the Go toolchain from a specific Alpine 3.24.2 root.

Cross Build's guest is a different set: gcc 15.2, cmake, node, python3, dpkg,
autotools. None of those is in any published image set, and none can be.

### 2. Recording needs a Mac with Xcode

The recorder is a Darwin/arm64 build of the engine that runs the guest workloads
and emits translations. It cannot be produced or run in CI without a macOS runner —
and cannot be produced at all on the device.

Sequence from the engine's docs, adapted:

1. Build a *no-emission* app (`AOT_IMAGE_EXECUTION=0`), install it on the target
   device, launch it once. It writes `Documents/aot-layout.json`.
2. Build the Darwin recorder (`make build-arm64-native`) and the contract from that
   layout (`bun tools/jit_aot/apple.ts contract …`).
3. Record the guest workloads against the **same fakefs** the app will ship
   (`bun tools/jit_aot/record-apple.ts …`).
4. Build again with `AOT_IMAGE_EXECUTION=1 AOT_IMAGES_DIR=<images>`.

Step 1 requires a device round trip; steps 2–4 require a Mac. Neither is
something a build job can do on its own.

### 3. Adding AOT to this project is a linked step, not a switch

`libish.a` and `libish_emu.a` would be replaced by a `jit=true` build and the
images linked into the app target. That part is mechanical; it is gated on (1) and
(2), not on anything in this repository.

## What Cross Build does today

Gadget interpretation with no executable memory: no entitlement, no runtime code
generation, and the same boot path CI exercises (the guest runs a full
compile/link/test of C, C++, CMake, Meson, Python, Node and dpkg under it).

The build refuses to *claim* AOT. An earlier revision of the docs and of
`ToolchainRuntimeArchitecture` said the engine was "AOT-ready / no runtime
emission"; both were describing a target nobody had built.

## What would make this real, concretely

1. A Mac (or a macOS runner that returns) with the pinned engine checked out with
   submodules.
2. One device install of the no-emission build to capture `aot-layout.json`.
3. Recording against **this** fakefs — which means the small, stable guest this
   app ships (see the "reduce the guest" note) rather than a 14,000-file one:
   fewer binaries is less recording, and every recorded binary is a file whose
   replacement silently drops back to the interpreter.
4. Linking the result and verifying on device that `/proc/ish/version` reports the
   image set and that the guest still builds.

Until 1–4 exist, `jit=false` is the correct configuration: it is the one that
runs.
