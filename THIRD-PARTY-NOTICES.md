# Third-party notices

Cross Build links, embeds and redistributes the components below. This file is
the notice required by several of their licences. It is also bundled with the app
(Settings → About → Licences).

Nothing here is legal advice. Two items carry obligations that are not satisfied
by this file alone — they are marked **ACTION REQUIRED**.

---

## ios-linuxkit (the embedded Linux engine) — GPLv3

- Source: https://github.com/rcarmo/ios-linuxkit (pinned in
  `.github/workflows/build-ipa.yml` as `c1a4064e84f1a957280a62f77d107162032dc908`)
- Licence: **GNU GPL version 3**, with the additional terms in the upstream
  `LICENSE.IOS` file, which state that the iSH copyright holders will not pursue a
  licence violation that arises *solely* from the conflict between the GPL and
  Apple's App Store terms, provided the GPL is complied with in all other
  respects — including the requirement to provide users with the source code and
  the text of the licence.
- It is derived from iSH (https://github.com/ish-app/ish), also GPLv3, with
  contributions additionally relicensed under GPLv2 to allow linking with GPLv2
  code.

**ACTION REQUIRED.** The engine is *statically linked* into the `CrossBuild`
executable. Distributing that binary (an IPA on a release page is distribution)
carries the GPLv3 obligation to convey the complete corresponding source of the
combined work under GPLv3, and to include the licence text. This repository is
public, which satisfies the "same place" part for the Cross Build sources and for
the pinned engine commit, but a recipient must be able to obtain the *exact*
sources that produced a given IPA:

- record the engine commit and the Apple-support package version in the release
  notes for every build, and
- keep the build inputs reproducible (see the "Reproducibility" gaps in the
  repository's own audit notes), or ship a written offer valid for three years.

## iSH / iSH-AOK lineage

The engine is an iSH fork; the same GPLv3 terms and the same source-availability
obligation apply to the portions derived from iSH.

## CPython 3.13 (PSF License Agreement)

- Source: https://github.com/python/cpython, distributed for iOS by
  beeware/Python-Apple-support (`3.13-b15`, pinned by SHA-256 in CI).
- Licence text ships with the runtime: `python/lib/python3.13/LICENSE.txt`.

Bundled unmodified except that the test suite, `ensurepip`, `idlelib`, `tkinter`
and `pydoc_data` are removed, and `lib-dynload` test extensions are dropped.

## Python-Apple-support

- Source: https://github.com/beeware/Python-Apple-support
- The support package's own build scripts and patches are distributed under the
  terms stated in that repository. The CPython build it produces is covered by the
  PSF licence above.

## ZIPFoundation (MIT)

- Source: https://github.com/weichsel/ZIPFoundation (pinned in `project.yml`)
- Copyright (c) 2017-2024 Thomas Zoechling and contributors.

```
Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in the
Software without restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN
AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## Alpine Linux guest userland

`fakefs-root` contains an Alpine Linux minirootfs plus these packages:
bash, coreutils, findutils, grep, sed, gawk, git, tar, gzip, xz,
ca-certificates, make, gcc, g++, musl-dev, binutils, dpkg, fakeroot.

These are **redistributed as binaries** inside the app. Their licences are a mix
of GPLv2, GPLv3, LGPL, MIT/BSD and others (GNU toolchain, bash, git and busybox
are the significant copyleft ones).

**ACTION REQUIRED.** GPL/LGPL binaries must be accompanied by their licence text
and by the corresponding source (or a written offer). Options, cheapest first:

- include `/usr/share/licenses/**` from the guest image in the packaged app and
  link to https://git.alpinelinux.org/ for the exact package versions, or
- publish the `apk` package list plus a three-year written offer to supply source
  on request, in the release notes, and
- pin every package version in `RUNTIME_PACKAGES`, so "the source that produced
  this IPA" is a finite, nameable set.

## Apple SDK and platform frameworks

JavaScriptCore, UIKit, SwiftUI, Compression, CoreGraphics and SQLite are provided
by iOS and are not redistributed by this app.

---

## If this app is published

The two **ACTION REQUIRED** items are not paperwork: they are the conditions on
which GPLv3 code may be distributed at all. Everything else here is satisfied by
this file plus the sources already listed.
