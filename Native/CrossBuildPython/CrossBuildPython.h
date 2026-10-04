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

// Initialise the interpreter. Safe to call more than once. Returns 0 on success,
// 2/3 for a configuration or initialisation failure, and 4 if the interpreter has
// already been finalized (CPython cannot be re-initialised after Py_FinalizeEx).
int32_t cbpy_start(const char *pythonHome, const char *pythonPath);
int32_t cbpy_is_started(void);

// Run a Python source string. On success returns 0 and sets *outStdout/*outStderr
// to malloc'd NUL-terminated UTF-8 (NULL only if allocation itself failed). A
// non-zero result means the snippet raised or could not be run at all; the
// traceback is in *outStderr. Text in *outStderr is NOT by itself a failure:
// a successful snippet may write to stderr.
int32_t cbpy_run(const char *source, char **outStdout, char **outStderr);

// Release a string returned by cbpy_run.
void cbpy_free(char *text);

void cbpy_stop(void);
const char *cbpy_version(void);

#ifdef __cplusplus
}
#endif
