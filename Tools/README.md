# Cross Build Tooling

The files in this directory support repository and CI preparation for the self-contained iOS application.

Runtime execution is no longer delegated to a host, jailbreak, HTTP, SSH, or Python helper. The installed app uses:

- linked/in-process compiler and runtime components when they are present in the IPA;
- the embedded `ios-linuxkit` environment for shell/POSIX compatibility;
- Setup & System Scan to verify the installed compiler-library, SDK, and Linux-runtime payloads.

`crossbuild-helper.py` is legacy source retained only for repository history/compatibility reference and is **not bundled into the IPA or used by current execution paths**. The Build IPA workflow fails if that helper appears in the app bundle.

The Linux engine build/cross files and patching utilities in this directory remain active CI inputs.
