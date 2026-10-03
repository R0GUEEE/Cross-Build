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
GitHub Actions generates the Xcode project with XcodeGen, builds an unsigned iOS application, packages Payload/CrossBuild.app as CrossBuild.ipa, and uploads it as a workflow artifact.
