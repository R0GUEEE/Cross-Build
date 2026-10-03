# Cross Build

Cross Build is a sideload-first iOS development environment and compiler workbench.

## Initial toolchain targets
- LLVM/Clang: C, C++, Objective-C, Objective-C++
- Swift / SwiftPM
- Theos / Logos
- Rust / Cargo
- Go
- Zig
- Python
- JavaScript / TypeScript
- Make / CMake / Ninja / Meson

The app includes project/build-system detection, a code editor workspace, build diagnostics, and an agent-oriented automation/task layer.

## Build
GitHub Actions generates the Xcode project with XcodeGen, builds an unsigned iOS application, packages Payload/CrossBuild.app as CrossBuild.ipa, and uploads it as a workflow artifact. Each CI build stamps `CURRENT_PROJECT_VERSION` with the GitHub Actions run number so artifacts from different commits are distinguishable.

To generate the project locally (on a Mac with XcodeGen installed), export the build-number variable first since `project.yml` references it:

```sh
CROSSBUILD_BUILD_NUMBER=1 xcodegen generate
```

## Installing the built IPA
CI uploads an **unsigned** IPA — iOS will refuse to install it as-is. Cross Build is a sideload/jailbreak-oriented app (see its own Compiler → Signing & Provisioning settings and the `ldid`/`dpkg` toolchain entries), so pick one of:

- **Jailbroken device**: fake-sign with `ldid -S CrossBuild.app/CrossBuild`, copy `CrossBuild.app` into `/Applications` (rootful) or `/var/jb/Applications` (rootless), then run `uicache -p <path>`.
- **TrollStore**: install the IPA directly if your iOS version is supported — no signing needed.
- **Free Apple ID / development certificate**: re-sign with `zsign` or install through SideStore/AltStore. Re-signed builds expire after about a week and need re-signing.
- **LiveContainer**: load the IPA inside it; some entitlements may not apply there.

For the "Jailbreak Local" and "Remote / Helper" execution backends (used to actually spawn compiler processes, since a sandboxed sideload install can't), run `Tools/crossbuild-helper.py` on the target host — see `Tools/README.md`.
