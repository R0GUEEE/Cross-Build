#!/usr/bin/env bash
#
# Build CrossBuild end-to-end on a Mac, without GitHub Actions.
#
# This is the CI workflow translated into one script, because the pieces it needs
# live in .gitignore and are normally produced by CI:
#
#   Vendor/Python/                 the vendored CPython support package
#   Vendor/linuxkit/build-ios/     the ios-linuxkit engine, cross-built for iOS
#   Vendor/linuxkit/fakefs-root/   the Alpine root the guest boots from
#
# Without those three, `xcodegen generate` produces a project that cannot link.
# So this script builds them the same way CI does, then generates, builds,
# verifies and packages the IPA.
#
# REQUIREMENTS
#   - macOS with Xcode 16.4 (or edit XCODE below)
#   - brew install xcodegen meson ninja libarchive
#   - ~10 GB free, and a while: the engine cross-build and the guest provisioning
#     are the slow parts.
#
# USAGE
#   Tools/build-local.sh                 # full build, IPA at ./CrossBuild.ipa
#   Tools/build-local.sh --skip-vendor   # reuse Vendor/ from a previous run
#   Tools/build-local.sh --verify-only    # rebuild + verify, skip vendoring
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

XCODE="/Applications/Xcode_16.4.app/Contents/Developer"
# Every backend input -- engine commit, Alpine base, guest packages, Python support
# -- comes from Tools/pins.env. This script used to carry its own copies of three of
# them, which is how a local build and a CI build came to differ.
# shellcheck disable=SC1091
. "$REPO/Tools/pins.env"

VENDOR=1
for arg in "$@"; do
  case "$arg" in
    --skip-vendor) VENDOR=0 ;;
    --verify-only) VENDOR=0 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1  (brew install $2)"; exit 1; }; }

say "toolchain"
[ -d "$XCODE" ] && sudo xcode-select -s "$XCODE" || echo "warning: $XCODE not found, using the selected Xcode"
xcodebuild -version
need xcodegen xcodegen
need meson meson
need ninja ninja
need python3 python

if [ "$VENDOR" = 1 ]; then
  # The three products are built by the same scripts CI runs, so a local build and a
  # runner build cannot diverge. Each checks its own pins and proves its output.
  "$REPO/Tools/build-python.sh"
  "$REPO/Tools/build-engine.sh"
  "$REPO/Tools/build-rootfs.sh"
fi

say "checking the pins are in step"
python3 "$REPO/Tools/gen-pins.py" --check

say "generating the Xcode project"
CROSSBUILD_BUILD_NUMBER="${CROSSBUILD_BUILD_NUMBER:-1}" xcodegen generate

say "building"
set -o pipefail
xcodebuild -project CrossBuild.xcodeproj -scheme CrossBuild -configuration Release \
  -sdk iphoneos -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build | tee build.log

say "verifying the bundle"
APP="$(find build/DerivedData/Build/Products/Release-iphoneos -maxdepth 1 -name '*.app' -print -quit)"
test -n "$APP" || { echo "no .app produced"; exit 1; }
fail() { echo "error: $1"; exit 1; }
test -f "$APP/Info.plist" || fail "Info.plist missing"
test -d "$APP/Toolchains" || fail "Toolchains folder missing"
for manifest in LLVM Swift Python JavaScript Theos; do
  test -f "$APP/Toolchains/$manifest/manifest.json" || fail "Toolchains/$manifest/manifest.json missing"
done
test -f "$APP/THIRD-PARTY-NOTICES.md" || fail "third-party notices missing"
test -d "$APP/fakefs-root" || fail "Linux rootfs missing from the bundle"
test -f "$APP/python/lib/python3.13/os.py" || fail "Python stdlib missing"
for ext in _sqlite3 _ssl _hashlib zlib; do
  ls "$APP/python/lib/python3.13/lib-dynload/$ext"*.so >/dev/null 2>&1 || fail "Python extension $ext missing"
done
test -s "$APP/fakefs-root/meta.db" || fail "fakefs-root has no meta.db; the guest could not boot"
test -d "$APP/app" || fail "PYTHONPATH app folder missing"
test -d "$APP/Frameworks/Python.framework" || fail "Python.framework not embedded"
test -f "$APP/Frameworks/Python.framework/Info.plist" || fail "embedded framework has no Info.plist (installd rejects this)"
for fw in "$APP"/Frameworks/*.framework; do
  [ -e "$fw" ] || continue
  test -f "$fw/Info.plist" || fail "embedded framework $(basename "$fw") has no Info.plist"
done
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Info.plist" 2>/dev/null; }
test "$(plist UIFileSharingEnabled)" = "true" || fail "UIFileSharingEnabled not set (workspace invisible in Files.app)"
test "$(plist LSSupportsOpeningDocumentsInPlace)" = "true" || fail "LSSupportsOpeningDocumentsInPlace not set"
for k in CFBundleExecutable CFBundleIdentifier CFBundleVersion CFBundleShortVersionString; do
  test -n "$(plist "$k")" || fail "Info.plist is missing $k"
done

say "packaging"
rm -rf Payload CrossBuild.ipa
mkdir Payload
cp -R "$APP" Payload/
zip -qry CrossBuild.ipa Payload
shasum -a 256 CrossBuild.ipa | tee CrossBuild.ipa.sha256

say "done"
cat <<EOF
  $(pwd)/CrossBuild.ipa
  $(du -h CrossBuild.ipa | cut -f1)

The IPA is unsigned. To install:
  - TrollStore: install it directly.
  - Jailbroken: ldid -S CrossBuild.app/CrossBuild && copy into /Applications,
    then uicache -p <path>. Sign the embedded framework too, or dyld will refuse
    to load it.
  - Or re-sign with zsign / Sideloadly / AltStore.
EOF
