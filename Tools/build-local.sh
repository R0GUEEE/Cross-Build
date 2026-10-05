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
LINUXKIT_PIN="c1a4064e84f1a957280a62f77d107162032dc908"   # 2.4.1 build 818
ALPINE_ROOTFS="alpine-minirootfs-3.24.2-aarch64.tar.gz"
ALPINE_SHA="9bf70a7f18ea44094cbb5f70c58f9af129c8214745743db0e68e5502cc2ce773"
# The same list CI provisions, including the toolchain. Keep in step with
# ToolchainRuntimeArchitecture.guestRuntimePackages.
RUNTIME_PACKAGES="bash coreutils findutils grep sed gawk git tar gzip xz ca-certificates make gcc g++ musl-dev binutils"

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
  say "vendoring Python 3.13"
  PY_VER=3.13
  PY_TAG=3.13-b15
  PY_BUILD=${PY_TAG#*-}
  ASSET="Python-${PY_VER}-iOS-support.${PY_BUILD}.tar.gz"
  URL="https://github.com/beeware/Python-Apple-support/releases/download/${PY_TAG}/${ASSET}"
  rm -rf Vendor/Python && mkdir -p Vendor/Python
  curl -sSL "$URL" -o /tmp/python-support.tar.gz
  tar xzf /tmp/python-support.tar.gz -C Vendor/Python
  test -d Vendor/Python/Python.xcframework || { echo "Python.xcframework missing"; exit 1; }
  # CPython's iOS layout: pure stdlib and compiled extensions ship separately and
  # have to be merged into the PYTHONHOME the app expects.
  STDLIB=Vendor/Python/stdlib/python/lib/python${PY_VER}
  mkdir -p "$STDLIB" Vendor/Python/stdlib/app
  cp -R "Vendor/Python/Python.xcframework/lib/python${PY_VER}/." "$STDLIB/"
  cp -R "Vendor/Python/Python.xcframework/ios-arm64/lib-arm64/python${PY_VER}/lib-dynload" "$STDLIB/lib-dynload"
  test -f "$STDLIB/os.py" || { echo "stdlib staging failed (os.py missing)"; exit 1; }
  echo "# Placeholder: user Python modules live here at runtime." > Vendor/Python/stdlib/app/README.txt

  say "fetching ios-linuxkit @ ${LINUXKIT_PIN:0:8}"
  if [ ! -d Vendor/linuxkit/.git ]; then
    git clone --filter=blob:none https://github.com/rcarmo/ios-linuxkit.git Vendor/linuxkit
  fi
  git -C Vendor/linuxkit fetch --depth 1 origin "$LINUXKIT_PIN" || true
  git -C Vendor/linuxkit checkout -q "$LINUXKIT_PIN"
  git -C Vendor/linuxkit submodule update --init --recursive --depth 1 || echo "warning: submodules incomplete"

  say "cross-building the engine for iOS"
  # platform/darwin.c needs libdispatch declared, and a global -include reaches the
  # asbestos .S gadgets and breaks the assembler -- so it is prepended to that one
  # file.
  python3 - <<'PY'
import pathlib
p = pathlib.Path("Vendor/linuxkit/platform/darwin.c")
src = p.read_text()
if "#include <dispatch/dispatch.h>" not in src.split("\n")[0]:
    p.write_text("#include <dispatch/dispatch.h>\n" + src)
PY
  SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
  sed "s|@IOS_SDK@|$SDK|" Tools/linuxkit-cross-ios.txt > Vendor/linuxkit/cross-ios.txt
  ( cd Vendor/linuxkit && rm -rf build-ios && \
    meson setup build-ios --cross-file cross-ios.txt \
      -Dguest_arch=arm64 -Djit=false -Djit_emit=false -Dcli_aot= --buildtype=release && \
    meson compile -C build-ios )
  ls -la Vendor/linuxkit/build-ios/*.a

  say "building the Alpine root and fakefsify"
  ( cd Vendor/linuxkit && \
    python3 "$REPO/Tools/patch_linuxkit.py" "$PWD" && \
    rm -rf build-host && \
    meson setup build-host --buildtype=release -Dguest_arch=arm64 \
      -Dc_args="-D_XOPEN_SOURCE=600 -D_DARWIN_C_SOURCE" && \
    meson compile -C build-host fakefsify ish:executable )
  curl -fsSL -o "/tmp/${ALPINE_ROOTFS}" \
    "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/${ALPINE_ROOTFS}"
  echo "${ALPINE_SHA}  /tmp/${ALPINE_ROOTFS}" | shasum -a 256 -c -
  rm -rf Vendor/linuxkit/fakefs-root
  Vendor/linuxkit/build-host/tools/fakefsify "/tmp/${ALPINE_ROOTFS}" "$REPO/Vendor/linuxkit/fakefs-root"
  test -d Vendor/linuxkit/fakefs-root || { echo "fakefs image not produced"; exit 1; }

  say "provisioning the guest (this is the slow one)"
  ROOT="$REPO/Vendor/linuxkit/fakefs-root"
  ISH="$REPO/Vendor/linuxkit/build-host/ish"
  MIRROR=dl-cdn.alpinelinux.org
  IP="$(python3 -c "import socket,sys; print(socket.gethostbyname(sys.argv[1]))" "$MIRROR")"
  # The guest cannot resolve DNS, so the mirror's address is put in /etc/hosts.
  "$ISH" -f "$ROOT" /bin/sh -c "echo '$IP $MIRROR' >> /etc/hosts" >/dev/null 2>&1 || true
  "$ISH" -f "$ROOT" /bin/sh -ec "apk update >/dev/null && apk add --no-cache $RUNTIME_PACKAGES" \
    || echo "warning: apk provisioning did not complete"
  for t in make cc gcc c++ g++; do
    "$ISH" -f "$ROOT" /bin/sh -c "command -v $t >/dev/null 2>&1" \
      || { echo "error: $t missing from the guest; builds will fail at runtime"; exit 1; }
  done
  "$ISH" -f "$ROOT" /bin/sh -c "printf 'int main(void){return 0;}\n' > /tmp/t.c && cc /tmp/t.c -o /tmp/t && /tmp/t" \
    || { echo "error: the guest toolchain cannot compile and link"; exit 1; }
  "$ISH" -f "$ROOT" /bin/sh -ec '
    rm -rf /usr/share/doc /usr/share/man /usr/share/info /usr/share/locale /usr/share/terminfo 2>/dev/null || true
    rm -f /usr/lib/gcc/*/*/libgcc.a /usr/lib/gcc/*/*/libgcc_eh.a 2>/dev/null || true
    rm -rf /usr/lib/gcc/*/include-fixed /usr/share/zoneinfo /usr/share/perl5/core_perl/pod 2>/dev/null || true
    rm -f /usr/bin/gprof /usr/bin/gcov /usr/bin/gcov-dump /usr/bin/gcov-tool /usr/bin/ld.gold /usr/bin/dwp 2>/dev/null || true
    rm -rf /var/cache/apk /root/.cache /tmp/* 2>/dev/null || true
  ' || echo "warning: trimming did not run cleanly"
  du -sh "$ROOT"
fi

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
test -f "$APP/Toolchains/LLVM/manifest.json" || fail "Toolchains/LLVM/manifest.json missing"
test -d "$APP/fakefs-root" || fail "Linux rootfs missing from the bundle"
test -f "$APP/python/lib/python3.13/os.py" || fail "Python stdlib missing"
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
