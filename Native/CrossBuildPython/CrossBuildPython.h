#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Thin C ABI over the embedded CPython runtime. Swift talks to this instead of
// importing Python.h, which keeps the Python headers out of the Swift module and
// avoids the module-map conflicts that come with mixing C frameworks.
//
// Layout expectations (see CPython's "Using Python on iOS"):
//   <bundle>/python/lib/python3.X[/lib-dynload]   PYTHONHOME + PYTHONPATH
//   <bundle>/app                                  PYTHONPATH for user code

// Initialise the interpreter. Safe to call more than once. Returns 0 on success.
int32_t cbpy_start(const char *pythonHome, const char *pythonPath);
int32_t cbpy_is_started(void);

// Run a Python source string. On success returns 0 and sets *outStdout/*outStderr
// to malloc'd NUL-terminated UTF-8 (never NULL on return). A non-zero result means
// the interpreter raised or could not run the code; the traceback is in *outStderr.
int32_t cbpy_run(const char *source, char **outStdout, char **outStderr);

// Release a string returned by cbpy_run.
void cbpy_free(char *text);

void cbpy_stop(void);
const char *cbpy_version(void);

#ifdef __cplusplus
}
#endif
