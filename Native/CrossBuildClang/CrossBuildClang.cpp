#include "include/CrossBuildClang.h"

// Stable C ABI consumed by Swift. A production build links this target against
// LLVM clangDriver/clangFrontend and replaces the unavailable return below.
extern "C" int32_t cb_clang_compile(int32_t argc,const char * const *argv,cb_clang_diagnostic_callback callback,void *context) {
    (void)argc; (void)argv;
    if (callback) callback("error","CrossBuildClang was built without LLVM libraries.",nullptr,0,0,context);
    return 125;
}
extern "C" const char *cb_clang_version(void) { return "CrossBuildClang bridge-1"; }
