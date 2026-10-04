# Cross Build Toolchain Libraries

This resource tree is the stable in-app home for compiler/runtime libraries, support data, SDK metadata, templates, and embedded resources.

A catalogue entry describes an intended Cross Build capability; it is **not** proof that the compiler is installed. At runtime, Setup & System Scan inspects the installed IPA and marks a toolchain ready only when its required framework/static-library/native payload is discoverable.

Current execution policy:

- native/embedded engines execute inside the app;
- Python uses the embedded CPython runtime;
- JavaScript uses JavaScriptCore;
- shell/POSIX compatibility uses the embedded ios-linuxkit environment;
- no Remote Helper, Jailbreak Local, HTTP, or SSH execution backend is part of the current architecture.

Native payloads should be placed in the matching toolchain directory or linked into the app target, with the runtime scanner updated when a component has a special linkage layout.
