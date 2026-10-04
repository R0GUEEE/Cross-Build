#include "CrossBuildPython.h"

#include <Python/Python.h>

#include <stdlib.h>
#include <string.h>

// g_started guards against re-initialising (Py_InitializeFromConfig must run once)
// and against running code before the interpreter exists.
static int g_started = 0;
// Set once the interpreter has been finalized. CPython does not support
// re-initialisation after Py_FinalizeEx, so a later cbpy_start is refused
// instead of pretending to succeed.
static int g_finalized = 0;

static char *cbpy_strdup(const char *text) {
    if (text == NULL) {
        text = "";
    }
    size_t n = strlen(text);
    char *copy = (char *)malloc(n + 1);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, text, n + 1);
    return copy;
}

// Reads a StringIO captured earlier and returns it as a malloc'd string.
static char *cbpy_take_stringio(PyObject *globals, const char *name) {
    PyObject *buffer = PyDict_GetItemString(globals, name);
    if (buffer == NULL) {
        return cbpy_strdup("");
    }
    PyObject *value = PyObject_CallMethod(buffer, "getvalue", NULL);
    if (value == NULL) {
        PyErr_Clear();
        return cbpy_strdup("");
    }
    const char *utf8 = PyUnicode_AsUTF8(value);
    char *result = cbpy_strdup(utf8 == NULL ? "" : utf8);
    Py_DECREF(value);
    return result;
}

int32_t cbpy_start(const char *pythonHome, const char *pythonPath) {
    if (g_started) {
        return 0;
    }
    if (g_finalized) {
        return 4;
    }
    if (pythonHome != NULL && pythonHome[0] != '\0') {
        setenv("PYTHONHOME", pythonHome, 1);
    }
    if (pythonPath != NULL && pythonPath[0] != '\0') {
        setenv("PYTHONPATH", pythonPath, 1);
    }

    PyConfig config;
    PyConfig_InitPythonConfig(&config);
    // No console exists on iOS, and a backgrounded app must not take signals.
    config.install_signal_handlers = 0;
    config.use_environment = 1;      // honour the PYTHONHOME/PYTHONPATH set above
    config.write_bytecode = 0;       // the app bundle is read-only
    config.buffered_stdio = 0;
    if (pythonHome != NULL && pythonHome[0] != '\0') {
        PyStatus status = PyConfig_SetBytesString(&config, &config.home, pythonHome);
        if (PyStatus_Exception(status)) {
            PyConfig_Clear(&config);
            return 2;
        }
    }

    PyStatus status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        return 3;
    }
    g_started = 1;
    return 0;
}

int32_t cbpy_is_started(void) {
    return g_started ? 1 : 0;
}

int32_t cbpy_run(const char *source, char **outStdout, char **outStderr) {
    if (outStdout != NULL) { *outStdout = NULL; }
    if (outStderr != NULL) { *outStderr = NULL; }
    if (!g_started) {
        if (outStderr != NULL) { *outStderr = cbpy_strdup("Python has not been started."); }
        if (outStdout != NULL) { *outStdout = cbpy_strdup(""); }
        return 100;
    }

    // Called from whichever thread Swift hands us, so take the GIL.
    PyGILState_STATE gil = PyGILState_Ensure();

    // PyImport_AddModule returns a borrowed reference and NULL on failure.
    // PyModule_GetDict(NULL) dereferences the NULL type pointer, so testing only
    // its result crashed before the "no __main__" branch below could ever run.
    PyObject *mainModule = PyImport_AddModule("__main__");
    if (mainModule == NULL) {
        PyErr_Clear();
        PyGILState_Release(gil);
        if (outStdout != NULL) { *outStdout = cbpy_strdup(""); }
        if (outStderr != NULL) { *outStderr = cbpy_strdup("No __main__ module available."); }
        return 101;
    }
    PyObject *globals = PyModule_GetDict(mainModule);
    int32_t result = 0;

    if (globals == NULL) {
        PyGILState_Release(gil);
        if (outStdout != NULL) { *outStdout = cbpy_strdup(""); }
        if (outStderr != NULL) { *outStderr = cbpy_strdup("No __main__ module available."); }
        return 101;
    }

    PyObject *pySource = PyUnicode_FromString(source == NULL ? "" : source);
    if (pySource == NULL) {
        PyGILState_Release(gil);
        if (outStdout != NULL) { *outStdout = cbpy_strdup(""); }
        if (outStderr != NULL) { *outStderr = cbpy_strdup("Could not encode source."); }
        return 102;
    }
    PyDict_SetItemString(globals, "_cb_src", pySource);
    Py_DECREF(pySource);

    // Redirect stdio into buffers, exec the snippet, and record any traceback.
    // The wrapper records whether the snippet actually raised, because stderr is
    // not a failure signal on its own: print(..., file=sys.stderr) and warnings
    // write there on a perfectly successful run.
    static const char *wrapper =
        "_cb_raised = False\n"
        "import io, sys, traceback\n"
        "_cb_out = io.StringIO()\n"
        "_cb_err = io.StringIO()\n"
        "_cb_stdout, _cb_stderr = sys.stdout, sys.stderr\n"
        "sys.stdout = _cb_out\n"
        "sys.stderr = _cb_err\n"
        "try:\n"
        "    exec(compile(_cb_src, '<crossbuild>', 'exec'), globals())\n"
        "except SystemExit:\n"
        "    pass\n"
        "except BaseException:\n"
        "    traceback.print_exc()\n"
        "    _cb_raised = True\n"
        "finally:\n"
        "    sys.stdout = _cb_stdout\n"
        "    sys.stderr = _cb_stderr\n";

    if (PyRun_SimpleString(wrapper) != 0) {
        PyErr_Clear();
        result = 1;
    }

    char *outText = cbpy_take_stringio(globals, "_cb_out");
    char *errText = cbpy_take_stringio(globals, "_cb_err");
    PyObject *raised = PyDict_GetItemString(globals, "_cb_raised");
    if (raised != NULL && PyObject_IsTrue(raised) == 1) {
        result = 1;
    }
    // Drop the marker so a later run cannot inherit this one's result.
    PyDict_DelItemString(globals, "_cb_raised");

    PyGILState_Release(gil);

    if (outStdout != NULL) { *outStdout = outText; } else { free(outText); }
    if (outStderr != NULL) { *outStderr = errText; } else { free(errText); }
    return result;
}

void cbpy_free(char *text) {
    if (text != NULL) {
        free(text);
    }
}

void cbpy_stop(void) {
    if (!g_started) {
        return;
    }
    // The GIL state must not be released after Py_FinalizeEx: finalization
    // destroys the thread state the release would touch. Take the GIL, finalize
    // while holding it, and stop there.
    PyGILState_Ensure();
    Py_FinalizeEx();
    g_started = 0;
    g_finalized = 1;
}

const char *cbpy_version(void) {
#if defined(PY_VERSION)
    return PY_VERSION;
#else
    return "unknown";
#endif
}
