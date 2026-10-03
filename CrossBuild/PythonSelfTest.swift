import Foundation

/// Runs a real probe inside the embedded interpreter and reports what actually
/// works on the device.
///
/// Why this exists: compiled extension modules in `lib-dynload` are loaded with
/// `dlopen`. CPython's iOS documentation describes a framework-per-module
/// packaging requirement, but that is an **App Store submission** rule, not an
/// operating-system restriction — the text says explicitly that it "conflicts
/// with the usual Python approach... which allows a binary extension module to
/// be loaded from any location on sys.path". A sideloaded build is not bound by
/// it, so the only thing that matters is that the bundled binaries are covered by
/// whatever signature the install used.
///
/// That means this should simply work, and the way to stop guessing is to ask the
/// interpreter directly and show the result.
enum PythonSelfTest {
    /// Deliberately free of backslashes so it survives being written as a Swift
    /// string literal without escape doubling.
    static let script: String = """
    import sys, importlib
    print("version    " + sys.version.split()[0])
    print("platform   " + sys.platform)
    print("executable " + (sys.executable or "<none>"))
    print("sys.path entries: " + str(len(sys.path)))
    probe = ["os", "json", "re", "math", "hashlib", "zlib", "binascii", "array",
             "select", "socket", "unicodedata", "datetime", "sqlite3", "ssl", "ctypes"]
    ok = 0
    failed = 0
    for name in probe:
        try:
            importlib.import_module(name)
            ok = ok + 1
            print("ok    " + name)
        except Exception as exc:
            failed = failed + 1
            print("fail  " + name + " : " + type(exc).__name__ + " : " + str(exc))
    print("summary " + str(ok) + " ok, " + str(failed) + " failed")
    """
}
