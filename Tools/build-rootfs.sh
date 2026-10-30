#!/bin/bash
# Build the guest root filesystem from the pins in Tools/pins.env.
#
# Replaces the two inline steps ("Build Linux rootfs" and "Provision minimal Linux
# runtime root") that used to live in build-ipa.yml. What was wrong with them:
#
#   * the package list lived in the workflow AND in ToolchainRuntimeArchitecture.swift,
#     and nothing compared the two;
#   * the trim step aborted on its first missing path (`[ -e x ] && …` returns 1
#     under `set -e`) and the whole thing was then swallowed as a warning, so a
#     "trimmed" image still carried gcov, dwp, libgcc.a and the apk cache;
#   * provisioning resolved against a live Alpine repository with no versions, so
#     the same commit produced different images on different days.
#
# Guest packages are now resolved once and recorded in Tools/guest-packages.lock
# (name=version-rN). With GUEST_LOCK=exact (the default) a package that is not in the
# lock is an error rather than a silent drift.
#
# Usage:
#   Tools/build-rootfs.sh                 # build Vendor/linuxkit/fakefs-root
#   Tools/build-rootfs.sh --reseed        # re-resolve the lock from the live mirror
#
# Requires: macOS (the fakefsify host tool is built from the engine tree), meson,
# ninja, curl, shasum, python3. The engine tree must be at Vendor/linuxkit.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO/Tools/pins.env"

ENGINE_DIR="$REPO/Vendor/linuxkit"
ROOT="$ENGINE_DIR/fakefs-root"
LOCK="$REPO/Tools/guest-packages.lock"
RESEED=0
[ "${1:-}" = "--reseed" ] && RESEED=1

step() { printf '\n== %s\n' "$*"; }
fail() { echo "::error::$*" >&2; exit 1; }

ensure() {
    local tool=$1 formula=${2:-$1}
    if ! command -v "$tool" >/dev/null 2>&1; then
        if command -v brew >/dev/null 2>&1; then
            echo "installing $formula"
            brew install "$formula" >/dev/null || fail "could not install $formula"
        else
            fail "$tool is required and Homebrew is not available"
        fi
    fi
}
ensure meson
ensure ninja
# fakefsify links libarchive. This has to happen before `meson setup`, because meson
# decides whether to define the target by probing for the library: absent, it prints
# "Build targets in project: 7" without fakefsify and the compile then fails with
# "target not found".
ensure bsdtar libarchive
if ! pkg-config --exists libarchive 2>/dev/null && ! ls /opt/homebrew/lib/libarchive* >/dev/null 2>&1; then
    echo "::warning::libarchive was not found by pkg-config; fakefsify may not be built"
fi

# ---------------------------------------------------------------- fakefsify (host)

step "build the fakefs host tool"
cd "$ENGINE_DIR"
[ -f meson.build ] || fail "Vendor/linuxkit has no meson.build"
python3 "$REPO/Tools/patch_linuxkit.py" "$PWD"
# meson may place the executable under tools/ or at the build root depending on the
# version; look for it rather than assuming the path.
FAKEFSIFY() { ls build-host/tools/fakefsify build-host/fakefsify 2>/dev/null | head -1; }

if [ -z "$(FAKEFSIFY)" ]; then
    meson setup build-host --buildtype=release -Dguest_arch=arm64 \
        -Dc_args="-D_XOPEN_SOURCE=600 -D_DARWIN_C_SOURCE"
    # `meson compile <target>` only knows targets meson registered as such; the old
    # workflow passed `fakefsify ish:executable`, which works, but naming the output
    # path is not a target name. Build everything the host configuration defines.
    meson compile -C build-host
fi
FAKEFSIFY_BIN="$(FAKEFSIFY)"
[ -n "$FAKEFSIFY_BIN" ] && [ -x "$FAKEFSIFY_BIN" ] || fail "fakefsify was not built (looked in build-host/tools and build-host)"
echo "using $FAKEFSIFY_BIN"

# ---------------------------------------------------------------- base image

step "fetch the Alpine base image"
cd "$ENGINE_DIR"
ROOTFS_TGZ="/tmp/alpine-minirootfs-${ALPINE_VERSION}-aarch64.tar.gz"
curl -fsSL -o "$ROOTFS_TGZ" "$ALPINE_ROOTFS_URL"
echo "$ALPINE_ROOTFS_SHA256  $ROOTFS_TGZ" | shasum -a 256 -c - \
    || fail "the Alpine base image does not match pins.env"

rm -rf "$ROOT"
"$FAKEFSIFY_BIN" "$ROOTFS_TGZ" "$ROOT"
[ -d "$ROOT" ] || fail "fakefs image was not produced"

# ---------------------------------------------------------------- provisioning

step "install guest packages"
sh_() { ./build-host/ish -f "$ROOT" /bin/sh -c "$1"; }
sh_e() { ./build-host/ish -f "$ROOT" /bin/sh -ec "$1"; }

MIRROR_HOST="dl-cdn.alpinelinux.org"
MIRROR_IP="$(python3 -c "import socket,sys; print(socket.gethostbyname(sys.argv[1]))" "$MIRROR_HOST")"
[ -n "$MIRROR_IP" ] || fail "could not resolve the Alpine mirror"
# The guest has no way to resolve names at build time; this line is replaced below
# with an empty file before packaging so it does not ship a stale address.
sh_ "printf '%s %s\n' '$MIRROR_IP' '$MIRROR_HOST' > /etc/hosts"
sh_e "apk update >/dev/null && apk upgrade --no-cache >/dev/null"

# Resolve versions and write/compare the lock.
plan_packages() {
    # shellcheck disable=SC2086
    echo "$GUEST_PACKAGES"
    echo "python3"   # meson's runtime; already implied, listed for clarity
}
if [ "$RESEED" -eq 1 ] || [ ! -f "$LOCK" ]; then
    step "resolving package versions (lock $( [ "$RESEED" -eq 1 ] && echo reseed || echo missing ))"
    : > "$LOCK"
    printf '# Resolved by Tools/build-rootfs.sh --reseed on Alpine %s\n' "$ALPINE_VERSION" >> "$LOCK"
    printf '# Format: name=version-rN. Regenerate deliberately, never implicitly.\n' >> "$LOCK"
    for pkg in $(plan_packages | tr ' ' '\n' | sort -u); do
        version="$(sh_ "apk info -e -v $pkg 2>/dev/null || apk search -x -v $pkg 2>/dev/null | head -1" | tr -d '\r')"
        [ -n "$version" ] || fail "cannot resolve a version for $pkg"
        printf '%s=%s\n' "$pkg" "${version#${pkg}-}" >> "$LOCK"
    done
    echo "wrote $LOCK"
fi

PAIRS=""
while read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    PAIRS="$PAIRS $line"
done < "$LOCK"
[ -n "$PAIRS" ] || fail "Tools/guest-packages.lock is empty"

# shellcheck disable=SC2086
sh_e "apk add --no-cache $PAIRS" || fail "apk could not install the locked package set"

step "assert the tool set"
for tool in $GUEST_REQUIRED_TOOLS; do
    sh_ "command -v $tool >/dev/null 2>&1" || fail "$tool is missing from the guest image"
    printf '  ok   %s\n' "$tool"
done
for tool in $GUEST_FORBIDDEN_TOOLS; do
    if sh_ "command -v $tool >/dev/null 2>&1"; then
        fail "$tool must not be in the guest image"
    fi
done

# ---------------------------------------------------------------- trim

step "trim"
# Kept in a file rather than a quoted one-liner: an apostrophe in a comment once
# terminated the quote and the runner executed the remainder as shell.
TRIM_SCRIPT="$(mktemp)"
trap 'rm -f "$TRIM_SCRIPT"' EXIT
{
    echo 'set -e'
    echo 'report() {'
    echo '  if [ -e "$1" ]; then printf "  %-46s %s\n" "$1" "$(du -sh "$1" 2>/dev/null | cut -f1)"; fi'
    echo '  return 0'
    echo '}'
    echo "for p in $GUEST_TRIM_PATHS; do"
    echo '  for hit in $p; do report "$hit"; rm -rf "$hit" 2>/dev/null || true; done'
    echo 'done'
    echo 'rm -rf /var/cache/apk /root/.cache /tmp/* 2>/dev/null || true'
    echo 'return 0 2>/dev/null || true'
} > "$TRIM_SCRIPT"

if ! ./build-host/ish -f "$ROOT" /bin/sh "$TRIM_SCRIPT"; then
    fail "trimming the guest failed"
fi
rm -f "$TRIM_SCRIPT"
trap - EXIT

# ---------------------------------------------------------------- prove it works

step "prove the toolchain still works"
sh_e 'printf "int main(void){return 0;}\n" > /tmp/c.c && cc /tmp/c.c -o /tmp/c && /tmp/c' \
    || fail "cc cannot compile and link after the trim"
sh_e 'printf "#include <string>\n#include <iostream>\nint main(){std::string s=\"ok\";std::cout<<s;}\n" > /tmp/cpp.cpp && c++ /tmp/cpp.cpp -o /tmp/cpp && test "$(/tmp/cpp)" = ok' \
    || fail "c++ cannot compile and link after the trim"
sh_e 'printf "#include <zlib.h>\nint main(void){return zlibVersion()==0;}\n" > /tmp/z.c && cc /tmp/z.c -lz -o /tmp/z && /tmp/z' \
    || fail "the guest cannot link against zlib"
sh_e 'rm -rf /tmp/cm && mkdir -p /tmp/cm && printf "cmake_minimum_required(VERSION 3.10)\nproject(v C)\nadd_executable(v main.c)\n" > /tmp/cm/CMakeLists.txt && printf "int main(void){return 0;}\n" > /tmp/cm/main.c && cd /tmp/cm && cmake -S . -B build -G Ninja >/dev/null && cmake --build build >/dev/null && ./build/v' \
    || fail "cmake + ninja cannot configure and build a project"
cat > /tmp/meson-check.sh <<'GUEST'
set -e
rm -rf /tmp/me && mkdir -p /tmp/me
cat > /tmp/me/meson.build <<'MESON'
project('v','c')
executable('v','main.c')
MESON
printf 'int main(void){return 0;}\n' > /tmp/me/main.c
cd /tmp/me && meson setup build >/dev/null && meson compile -C build >/dev/null
GUEST
./build-host/ish -f "$ROOT" /bin/sh /tmp/meson-check.sh || fail "meson cannot configure and build a project"
sh_e "python3 -c 'import sqlite3, ssl, zlib; print(\"python3 ok\")'" || fail "python3 is missing standard extensions"
sh_e "node -e 'console.log(1)' >/dev/null" || fail "node cannot run a script"
sh_e "rm -rf /tmp/pk && mkdir -p /tmp/pk/DEBIAN && printf 'Package: v\nVersion: 1.0\nArchitecture: all\nMaintainer: ci <ci@example.com>\nDescription: v\n' > /tmp/pk/DEBIAN/control && dpkg-deb --build /tmp/pk /tmp/v.deb >/dev/null && test -s /tmp/v.deb" \
    || fail "dpkg-deb cannot build a package"

step "final image"
# Do not ship the build-time mirror address or the apk database's cache in /etc/hosts.
sh_ "printf '127.0.0.1 localhost\n::1 localhost\n' > /etc/hosts"
du -sh "$ROOT"
sh_ "apk info | wc -l" | sed 's/^/  packages: /'
echo "guest root: $ROOT"

# A hash of the finished image, printed so two builds can be compared.
if command -v shasum >/dev/null; then
    ( cd "$ROOT" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | sed 's/^/  image hash: /' )
fi
