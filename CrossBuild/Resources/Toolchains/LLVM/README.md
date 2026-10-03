# Embedded LLVM payload

Cross Build's Swift bridge probes this toolchain directory at runtime.

Expected production payload:
- CrossBuildClang.xcframework or statically linked CrossBuildClang module
- LLVM/Clang libraries built for arm64 iOS
- clangDriver/clangFrontend bridge implementation
- resource/include/clang/<version>/include builtin headers

Do not mark LLVM as embedded-ready unless the native payload is linked. The bridge intentionally reports a missing payload otherwise.
