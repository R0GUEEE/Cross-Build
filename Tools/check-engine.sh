#!/bin/bash
# Fail the build if the engine source is not actually present.
#
# Vendor/linuxkit is a git submodule. Three separate things had to line up for CI to
# get it, and each of them has been silently wrong at least once:
#
#   1. the gitlink must be in the commit (a branch cut from before the submodule
#      commit inherited .gitmodules but not the link, so checkout left it empty);
#   2. actions/checkout must be told `submodules: recursive`;
#   3. the checked-out commit must be the one in Tools/pins.env.
#
# This checks all of them from the working tree, so a failure says which one broke.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO/Tools/pins.env"

ENGINE="$REPO/Vendor/linuxkit"

if [ ! -d "$ENGINE" ] || [ -z "$(ls -A "$ENGINE" 2>/dev/null)" ]; then
    echo "::error::Vendor/linuxkit is missing or empty."
    echo "The engine is a submodule; it is present only when the checkout fetched it"
    echo "(actions/checkout with submodules: recursive) and the gitlink is in the commit."
    echo "Locally: git submodule update --init --recursive"
    exit 1
fi

if [ ! -e "$ENGINE/meson.build" ]; then
    echo "::error::Vendor/linuxkit has no meson.build; the submodule is not checked out."
    exit 1
fi

actual="$(git -C "$ENGINE" rev-parse HEAD 2>/dev/null || echo unknown)"
if [ "$actual" != "$ENGINE_COMMIT" ]; then
    echo "::error::Vendor/linuxkit is at $actual, Tools/pins.env pins $ENGINE_COMMIT"
    exit 1
fi

if git -C "$ENGINE" submodule status 2>/dev/null | grep -q '^-'; then
    echo "::warning::engine submodules are not initialised:"
    git -C "$ENGINE" submodule status | grep '^-' || true
fi

echo "engine source ok: $(git -C "$ENGINE" rev-parse --short HEAD)"
