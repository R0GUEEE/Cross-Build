# Cross Build Tooling

The files in this directory support repository and CI preparation for the self-contained iOS application.

Runtime execution is no longer delegated to a host, jailbreak, HTTP, SSH, or Python helper. The installed app uses:

- linked/in-process compiler and runtime components when they are present in the IPA;
- the embedded `ios-linuxkit` environment for shell/POSIX compatibility;
- Setup & System Scan to verify the installed compiler-library, SDK, and Linux-runtime payloads.

`crossbuild-helper.py` has been deleted. It was legacy host-side helper source that
nothing referenced, and keeping it only invited someone to wire it back in. The
Build IPA workflow still fails if a file of that name ever appears in the app
bundle, so the deletion is enforced rather than merely done.

The Linux engine build/cross files and patching utilities in this directory remain active CI inputs.
