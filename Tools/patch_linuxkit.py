#!/usr/bin/env python3
"""Patch the vendored ios-linuxkit tree before building it.

Two separate problems, both found from real build/run failures rather than guessed.

1. kernel/uname.c overflows fixed-size guest struct fields.
   `struct uname` (kernel/calls.h) declares every field as char[UNAME_LENGTH].
   do_uname() fills them with unbounded strcpy()/snprintf(), so
   `strcpy(uts->version, ...)` with "%s %s %s" (version + __DATE__ + __TIME__)
   writes past the field. On the macOS host build the fortified libc catches it and
   aborts with __chk_fail_overflow inside stpcpy -- which is exactly how the apk
   provisioning step died (SIGTRAP in sys_uname, called by the very first guest
   process). It is latent on iOS too; the same overflow just is not checked there.
   The field is truncated instead, matching what the kernel reports for a long
   version string.

2. kernel/native_offload.c calls posix_spawn_file_actions_addchdir, which does not
   exist in the runner's libSystem at all (the linker proved that, after an earlier
   attempt to merely declare it failed). The call only sets the child's working
   directory on the host-side native-offload fast path, which the build-time CLI
   never uses, so it becomes a no-op.

Usage: patch_linuxkit.py <path-to-linuxkit-checkout>
"""

import pathlib
import sys


def patch_uname(root: pathlib.Path) -> bool:
    path = root / "kernel" / "uname.c"
    if not path.exists():
        print(f"  skip: {path} not found")
        return False
    text = path.read_text()

    old_hostname = "    strcpy(uts->hostname, hostname);"
    new_hostname = (
        "    /* crossbuild: bounded copy; hostname and version can exceed\n"
        "       UNAME_LENGTH and the guest fields are fixed size. */\n"
        "    snprintf(uts->hostname, sizeof(uts->hostname), \"%s\", hostname);"
    )
    old_version = (
        '    snprintf(uts->version, sizeof(uts->version), "%s %s %s", uname_version, __DATE__, __TIME__);'
    )
    new_version = (
        '    snprintf(uts->version, sizeof(uts->version), "%s %s %s", uname_version, __DATE__, __TIME__);\n'
        "    /* crossbuild: the field above is char[UNAME_LENGTH], so a long\n"
        "       version string is truncated rather than overrunning it. */"
    )

    changed = False
    if old_hostname in text:
        text = text.replace(old_hostname, new_hostname, 1)
        changed = True
    if old_version in text and "crossbuild: the field above" not in text:
        text = text.replace(old_version, new_version, 1)
        changed = True

    if changed:
        path.write_text(text)
        print("  patched kernel/uname.c (bounded uname fields)")
    else:
        print("  kernel/uname.c already patched or pattern absent")
    return changed


def patch_native_offload(root: pathlib.Path) -> bool:
    path = root / "kernel" / "native_offload.c"
    if not path.exists():
        print(f"  skip: {path} not found")
        return False
    text = path.read_text()
    old = "    if (host_cwd) SPAWN_CHECK(posix_spawn_file_actions_addchdir(&actions, host_cwd));"
    new = (
        "    /* crossbuild: posix_spawn_file_actions_addchdir is absent from this\n"
        "       SDK's libSystem. It only sets the child's working directory on the\n"
        "       host-side native-offload fast path, which the build-time CLI does\n"
        "       not use, so this is a deliberate no-op. */"
    )
    if old in text:
        path.write_text(text.replace(old, new, 1))
        print("  patched kernel/native_offload.c (dropped addchdir call)")
        return True
    print("  kernel/native_offload.c already patched or pattern absent")
    return False


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    root = pathlib.Path(sys.argv[1])
    if not (root / "kernel").is_dir():
        print(f"error: {root} does not look like an ios-linuxkit checkout")
        return 1
    print(f"Patching {root}")
    patch_uname(root)
    patch_native_offload(root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
