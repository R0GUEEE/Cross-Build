// Force-included into the NATIVE (macOS) host build of the ios-linuxkit engine.
//
// Why this exists: kernel/native_offload.c compiles a posix_spawn path when
// TARGET_OS_OSX, and calls posix_spawn_file_actions_addchdir. On the CI runner's
// SDK that declaration is hidden behind an availability macro the compiler does
// not expose, so the call fails to compile with "undeclared function". The symbol
// itself is present in libSystem, so declaring the prototype is the entire fix.
//
// Scope: this header is only passed to the native build-host Meson setup (via
// -include in c_args). The iOS cross build is deliberately unaffected -- it does
// not use this file, and the availability question there is moot because the
// guest never takes this path.
//
// Note this must stay a plain header with no preprocessor tricks beyond the
// guard: it is force-included into every translation unit of that build.

#ifndef CROSSBUILD_NATIVE_OFFLOAD_SHIM_H
#define CROSSBUILD_NATIVE_OFFLOAD_SHIM_H

#include <spawn.h>
#include <sys/cdefs.h>

#if defined(__APPLE__) && !defined(__DARWIN_C_LEVEL)
#define __DARWIN_C_LEVEL __DARWIN_C_FULL
#endif

#if defined(__APPLE__)
/* Declared explicitly because the SDK may gate it behind availability macros. */
extern int posix_spawn_file_actions_addchdir(posix_spawn_file_actions_t *__restrict,
                                             const char *__restrict);
#endif

#endif /* CROSSBUILD_NATIVE_OFFLOAD_SHIM_H */
