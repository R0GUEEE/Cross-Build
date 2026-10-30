#!/bin/bash
# Stage the embedded CPython runtime from the pins in Tools/pins.env.
#
# Replaces the inline "Vendor Python runtime" step. The staging rules were spread
# across that step, PythonEmbeddedEngine.swift (which spells out python3.13) and
# AppToolchainLibraries.swift; this script is now the single place that decides what
# a Python runtime looks like, and it proves the important parts are present before
# handing it to the app.
#
# Output (both gitignored):
#   Vendor/Python/Python.xcframework   the framework, embedded by the app target
#   Vendor/Python/stdlib/python        PYTHONHOME: lib/python3.X plus lib-dynload
#   Vendor/Python/stdlib/app           PYTHONPATH for user modules
#
# Usage: Tools/build-python.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO/Tools/pins.env"

step() { printf '\n== %s\n' "$*"; }
fail() { echo "::error::$*" >&2; exit 1; }

ARCHIVE="/tmp/python-support-${PYTHON_SUPPORT_TAG}.tar.gz"
VENDOR="$REPO/Vendor/Python"
STDLIB="$VENDOR/stdlib/python/lib/python${PYTHON_VERSION}"

step "fetch ${PYTHON_SUPPORT_TAG}"
curl -fsSL -o "$ARCHIVE" "$PYTHON_SUPPORT_URL"
if command -v shasum >/dev/null; then
    echo "$PYTHON_SUPPORT_SHA256  $ARCHIVE" | shasum -a 256 -c - \
        || fail "the Python support package does not match pins.env"
else
    echo "::warning::shasum unavailable; checksum not verified"
fi

step "unpack"
rm -rf "$VENDOR"
mkdir -p "$VENDOR"
tar xzf "$ARCHIVE" -C "$VENDOR"
[ -d "$VENDOR/Python.xcframework" ] || fail "Python.xcframework missing from the support package"

step "assemble PYTHONHOME"
# CPython documents this layout for iOS: the pure standard library and the compiled
# extensions ship in two places inside the support package and must be merged.
mkdir -p "$STDLIB" "$VENDOR/stdlib/app"
cp -R "$VENDOR/Python.xcframework/lib/python${PYTHON_VERSION}/." "$STDLIB/"
cp -R "$VENDOR/Python.xcframework/ios-arm64/lib-arm64/python${PYTHON_VERSION}/lib-dynload" "$STDLIB/lib-dynload"
[ -f "$STDLIB/os.py" ] || fail "standard library did not stage (os.py missing)"

step "trim"
for entry in $PYTHON_STDLIB_TRIM; do
    if [ -e "$STDLIB/$entry" ]; then
        printf '  remove %-28s %s\n' "$entry" "$(du -sh "$STDLIB/$entry" | cut -f1)"
    fi
    rm -rf "$STDLIB/$entry"
done
rm -f "$STDLIB"/lib-dynload/_test*.so "$STDLIB"/lib-dynload/xxlimited*.so \
      "$STDLIB"/lib-dynload/xxsubtype*.so "$STDLIB"/lib-dynload/_ctypes_test*.so
find "$STDLIB" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

step "assert the extension modules"
# Missing extensions are invisible until an import fails: Python still starts.
for ext in $PYTHON_REQUIRED_EXTENSIONS; do
    if ls "$STDLIB"/lib-dynload/"$ext"*.so >/dev/null 2>&1; then
        printf '  ok   %s\n' "$ext"
    else
        fail "lib-dynload is missing $ext; the C extensions did not stage"
    fi
done

printf '# User Python modules go here at runtime (this directory is PYTHONPATH).\n' \
    > "$VENDOR/stdlib/app/README.txt"

step "result"
du -sh "$STDLIB"
echo "  framework: $(du -sh "$VENDOR/Python.xcframework" | cut -f1)"
echo "  stdlib:    $(find "$STDLIB" -type f | wc -l | tr -d ' ') files"
