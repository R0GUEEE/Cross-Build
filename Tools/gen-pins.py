#!/usr/bin/env python3
"""Generate the Swift mirror of Tools/pins.env.

The list of guest packages, required tools and forbidden tools was written out
twice: once in Tools/pins.env (which the build uses) and once in
ToolchainRuntimeArchitecture.swift (which the app shows). A comment in the Swift
file admitted they could drift, which is another way of saying nothing checked.

Running this produces the Swift arrays from the pins, so the app cannot describe a
guest other than the one the build makes. It is run by build-ipa.yml before
`xcodegen`, and its output is committed so a checkout compiles without it.

Usage: Tools/gen-pins.py [--check]
"""
import re
import sys

PINS = "Tools/pins.env"
SWIFT = "CrossBuild/ToolchainRuntimeArchitecture.swift"
MARK_BEGIN = "    // BEGIN GENERATED FROM Tools/pins.env — run Tools/gen-pins.py\n"
MARK_END = "    // END GENERATED\n"


def read_pins(path):
    values = {}
    for line in open(path):
        line = line.split("#", 1)[0].strip()
        if not line or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip('"')
    return values


def swift_list(name, items):
    body = ",\n".join(f'        "{item}"' for item in items)
    return f"    static let {name}: [String] = [\n{body}\n    ]\n"


def main():
    pins = read_pins(PINS)
    packages = pins["GUEST_PACKAGES"].split()
    required = pins["GUEST_REQUIRED_TOOLS"].split()
    forbidden = pins["GUEST_FORBIDDEN_TOOLS"].split()

    block = MARK_BEGIN
    block += swift_list("guestRuntimePackages", packages)
    block += swift_list("requiredGuestTools", required)
    block += swift_list("forbiddenGuestBuildTools", forbidden)
    block += MARK_END

    source = open(SWIFT).read()
    pattern = re.compile(re.escape(MARK_BEGIN) + r".*?" + re.escape(MARK_END), re.S)
    if not pattern.search(source):
        sys.exit("gen-pins: markers not found in ToolchainRuntimeArchitecture.swift")
    updated = pattern.sub(lambda _: block, source)

    if "--check" in sys.argv:
        if updated != source:
            print("gen-pins: ToolchainRuntimeArchitecture.swift is out of date with Tools/pins.env")
            print("          run Tools/gen-pins.py and commit the result")
            sys.exit(1)
        print("gen-pins: Swift mirrors match Tools/pins.env")
        return

    if updated != source:
        open(SWIFT, "w").write(updated)
        print(f"gen-pins: wrote {len(packages)} packages, {len(required)} required, {len(forbidden)} forbidden")
    else:
        print("gen-pins: already up to date")


if __name__ == "__main__":
    main()
