#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Embedded Linux guest: a thin C ABI over the ios-linuxkit engine (an optimised
// iSH fork). The engine runs an AArch64 Linux userland in-process with a
// threaded-code interpreter, so no process is ever spawned and no JIT
// entitlement is needed -- which is why this works on a stock sideload.
//
// The guest boots from a fakefs root (a self-contained SQLite-backed filesystem
// image), so it needs no host filesystem access at all.

// Boot the guest and run one command to completion, capturing its output.
// Call once per process: the engine's interpreter state is process-global.
// Returns the guest exit code, or a negative value if the guest could not start.
int32_t cblk_boot_and_run(const char *fakefsRoot,
                          const char *workingDirectory,
                          const char *command,
                          char **outStdout,
                          char **outStderr);

// True once a boot has been attempted. The interpreter is not re-entrant.
int32_t cblk_has_booted(void);

void cblk_free(char *text);

// Engine build identification, for the diagnostics screen.
const char *cblk_engine_version(void);

#ifdef __cplusplus
}
#endif
