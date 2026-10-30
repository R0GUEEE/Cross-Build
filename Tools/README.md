# Build tooling

The backend is three independent build products, each from a pin file, each proven
before it is handed to the app.

```
Tools/pins.env            every input: engine commit, Alpine base + hash, guest
                          package list, Python support package + hash
Tools/guest-packages.lock  the guest's packages pinned to version-rN (generated)
Tools/gen-pins.py          mirrors pins.env into ToolchainRuntimeArchitecture.swift
                           so the app cannot describe a guest the build does not make

Tools/build-engine.sh      ios-linuxkit → Vendor/linuxkit/build-ios/*.a
Tools/build-rootfs.sh      Alpine → Vendor/linuxkit/fakefs-root (the guest image)
Tools/build-python.sh      beeware Python-Apple-support → Vendor/Python
```

`build-ipa.yml` runs those three scripts and nothing else of its own; anything a
script does not do is not done.

## What each one proves before returning

**build-engine.sh** — Vendor/linuxkit is at the pinned commit; each archive is
non-empty and `arm64`; `libish.a` exports one of the shim's API symbols and
`libish_emu.a` exports one of the emulator's. `--verify-only` re-checks an existing
build without rebuilding.

**build-rootfs.sh** — the Alpine base matches its hash; every package in
`guest-packages.lock` installs at that exact version; every tool in
`GUEST_REQUIRED_TOOLS` exists and every tool in `GUEST_FORBIDDEN_TOOLS` does not;
after trimming, C, C++, zlib, CMake+Ninja, Meson, Python (with sqlite3/ssl/zlib),
Node and dpkg-deb all still compile or run. It prints the image size, package count
and a content hash.

`--reseed` re-resolves `guest-packages.lock` from the live mirror. Do that
deliberately: until you do, the same commit produces the same guest.

**build-python.sh** — the support package matches its hash; `os.py` staged; every
extension in `PYTHON_REQUIRED_EXTENSIONS` is present; the standard library is
trimmed of the test suite, ensurepip, idlelib, tkinter and the docs.

## Known traps, recorded so they are not rediscovered

- `[ -e x ] && rm x` under `set -e` aborts the script when `x` is absent. The trim
  loop used it, so the whole trim silently never ran. `report()` now returns 0.
- Never put an apostrophe inside a single-quoted `sh -c '…'` block: it ends the
  quote and the rest executes as shell.
- `libgcc.a` must stay in the guest. gcc passes `-lgcc` on dynamic links too.
- Meson rejects double-quoted strings in `meson.build`; fixtures use single quotes.
- Engine submodules are required (`Vendor/linuxkit` has `deps/libapps`,
  `deps/libarchive`); a checkout without them links to a library that cannot boot.
- `CROSSBUILD_BUILD_NUMBER` must be exported for `xcodegen generate`; `project.yml`
  references it.

## Build locally

```
Tools/build-local.sh          # the whole thing, no GitHub Actions
```

It runs the same three scripts and then xcodegen + xcodebuild, so a local build and
the CI build differ only in the runner.
