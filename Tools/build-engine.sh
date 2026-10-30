#!/bin/bash
# Build the ios-linuxkit engine for iOS, from the pins in Tools/pins.env.
#
# This replaces the inline recipe that used to live in build-ipa.yml, for three
# reasons that all cost real debugging time:
#
#   * the recipe was one of three places that named the engine commit, so a bump
#     could leave two of them behind;
#   * it patched a vendored source file in place (platform/darwin.c) with a `cat`
#     redirect, which is silent the second time it runs and unreadable in a diff;
#   * it could not be run anywhere except CI.
#
# Usage:
#   Tools/build-engine.sh                 # build into Vendor/linuxkit/build-ios
#   Tools/build-engine.sh --verify-only   # check the existing build
#
# Requires: macOS with Xcode, meson, ninja. The engine tree must already be checked
# out at Vendor/linuxkit (git submodule update --init --recursive).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO/Tools/pins.env"

ENGINE_DIR="$REPO/Vendor/linuxkit"
BUILD_DIR="$ENGINE_DIR/build-ios"
FAIL=0
fail() { echo "::error::$*" >&2; FAIL=$((FAIL + 1)); }
ok() { printf '  ok   %s\n' "$*"; }

# Install what is missing rather than only complaining: a script that runs on a
# bare runner (or a fresh Mac) is the point of moving this out of the workflow.
ensure() {
    local tool=$1 formula=${2:-$1}
    if ! command -v "$tool" >/dev/null 2>&1; then
        if command -v brew >/dev/null 2>&1; then
            echo "installing $formula"
            brew install "$formula" >/dev/null || { echo "::error::could not install $formula" >&2; exit 1; }
        else
            echo "::error::$tool is required and Homebrew is not available" >&2
            exit 1
        fi
    fi
    command -v "$tool" >/dev/null 2>&1 || { echo "::error::$tool still missing after install" >&2; exit 1; }
}
ensure meson
ensure ninja
command -v xcrun >/dev/null 2>&1 || { echo "::error::Xcode command line tools are required" >&2; exit 1; }

verify() {
    local archive
    for archive in libish.a libish_emu.a libfakefs.a libsqlite3.a; do
        if [ ! -s "$BUILD_DIR/$archive" ]; then
            # libsqlite3.a is provided by the SDK rather than the engine; only the
            # three engine archives are mandatory here.
            [ "$archive" = "libsqlite3.a" ] && continue
            fail "build-ios/$archive is missing or empty"
            continue
        fi
        local archs
        archs="$(lipo -archs "$BUILD_DIR/$archive" 2>/dev/null || echo unknown)"
        [ "$archs" = "arm64" ] || fail "build-ios/$archive is $archs, expected arm64"
        ok "$archive ($archs, $(du -h "$BUILD_DIR/$archive" | cut -f1))"
    done
    # A library can exist and hold nothing useful. Require one of the API symbols
    # the shim links against; which ones a build exposes varies with LTO, so accept
    # a set and print what was found when none matches.
    expect_symbols() {
        local archive=$1; shift
        local symbols
        symbols="$(nm -g "$BUILD_DIR/$archive" 2>/dev/null | awk '$2=="T"{print $3}')"
        local want
        for want in "$@"; do
            if printf '%s\n' "$symbols" | grep -qx "$want"; then
                ok "$archive exports $want"
                return 0
            fi
        done
        fail "$archive exports none of: $* (found: $(printf '%s' "$symbols" | head -6 | tr '\n' ' '))"
    }
    expect_symbols libish.a _do_execve _task_run_current _generic_mkdirat _do_mount
    expect_symbols libish_emu.a _emu_run _cpu_run _tlb_flush
}

if [ "${1:-}" = "--verify-only" ]; then
    verify
    [ "$FAIL" -eq 0 ] || { echo "engine verification failed ($FAIL problem(s))" >&2; exit 1; }
    echo "engine build verified"
    exit 0
fi

# ---------------------------------------------------------------- provenance

cd "$ENGINE_DIR"
actual="$(git rev-parse HEAD)"
[ "$actual" = "$ENGINE_COMMIT" ] \
    || { echo "::error::Vendor/linuxkit is at $actual, pins.env says $ENGINE_COMMIT" >&2; exit 1; }
git submodule update --init --recursive --depth 1 \
    || echo "::warning::engine submodule init failed; continuing"
[ -f meson.build ] || { echo "::error::Vendor/linuxkit has no meson.build" >&2; exit 1; }

# The engine's darwin.c calls dispatch_once and relies on a system header to pull
# libdispatch in. A global -include also reaches the .S gadgets and breaks the
# assembler, so it is scoped to the one translation unit that needs it -- and the
# patch is idempotent, because this script may run twice on one checkout.
if ! head -3 platform/darwin.c | grep -q 'dispatch/dispatch.h'; then
    { printf '#include <dispatch/dispatch.h>\n'; cat platform/darwin.c; } > platform/darwin.c.tmp
    mv platform/darwin.c.tmp platform/darwin.c
fi

# ---------------------------------------------------------------- configure

IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "iOS SDK: $IOS_SDK"
sed "s|@IOS_SDK@|$IOS_SDK|" "$REPO/Tools/linuxkit-cross-ios.txt" > "$ENGINE_DIR/cross-ios.txt"

rm -rf "$BUILD_DIR"
meson setup "$BUILD_DIR" --cross-file cross-ios.txt \
    -Dguest_arch=arm64 -Djit="$ENGINE_JIT" -Djit_emit="$ENGINE_JIT_EMIT" -Dcli_aot= \
    --buildtype=release
meson compile -C "$BUILD_DIR"

verify
[ "$FAIL" -eq 0 ] || { echo "engine build failed verification ($FAIL problem(s))" >&2; exit 1; }

# What was actually built, for the app to report and for the log to record.
cat > "$REPO/build/engine.txt" <<EOF
engine_repo=$ENGINE_REPO
engine_commit=$ENGINE_COMMIT
engine_version=$ENGINE_VERSION
engine_jit=$ENGINE_JIT
engine_jit_emit=$ENGINE_JIT_EMIT
engine_aot=$([ "$ENGINE_JIT" = true ] && [ "$ENGINE_JIT_EMIT" = false ] && echo yes || echo no)
engine_built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
echo "engine built: $ENGINE_VERSION @ ${ENGINE_COMMIT:0:12} (jit=$ENGINE_JIT)"
