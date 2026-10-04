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
// One-shot: use only when a single command is all that is needed. For continuous
// use prefer the session API below.
// Returns the guest exit code, or a negative value if the guest could not start.
int32_t cblk_boot_and_run(const char *fakefsRoot,
                          const char *workingDirectory,
                          const char *command,
                          char **outStdout,
                          char **outStderr);

// ---- persistent session ---------------------------------------------------
// The interpreter keeps process-global state and cannot be restarted, so a
// one-shot boot would leave the app unable to run anything after the first
// command. The session API instead boots the guest ONCE with an interactive
// /bin/sh whose stdin/stdout are host pipes, and streams commands to it for the
// lifetime of the process.

// Boot the guest shell. Safe to call repeatedly; only the first call boots.
int32_t cblk_session_start(const char *fakefsRoot, const char *workingDirectory);
int32_t cblk_session_is_running(void);

// Send one command to the running shell and collect its output. Uses a sentinel
// written after the command to know when the output is complete, and gives up
// after timeoutMs (measured with the monotonic clock) so a hung command cannot
// block the app forever.
//
// Returns 0 on success, 124 if the deadline passed before the sentinel appeared,
// and -3 if the guest shell itself exited (a command ran `exit`, or the guest
// died). -3 is terminal: the session is closed and the app must report it rather
// than retry. On any negative return the caller owns *outCombined and must free
// it; on 0 or 124 it is the shim's internal scratch buffer and must not be freed.
int32_t cblk_session_run(const char *command, int32_t timeoutMs, char **outCombined);

void cblk_session_stop(void);

// True once a boot has been attempted. The interpreter is not re-entrant.
int32_t cblk_has_booted(void);

void cblk_free(char *text);

// Engine build identification, for the diagnostics screen.
const char *cblk_engine_version(void);

#ifdef __cplusplus
}
#endif
