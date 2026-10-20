#!/usr/bin/env bash
# Package a release app and an Applications shortcut in a compressed disk image.
set -euo pipefail
cd "$(dirname "$0")/.."
export MARGINS_VERSION=${MARGINS_VERSION:-0.2.0}
scripts/build-app.sh
ARCH=$(uname -m)
NAME="Margins-${MARGINS_VERSION}-${ARCH}"
STAGING=$(mktemp -d "$PWD/build/dmg-stage.XXXXXX")
trap 'rm -rf "$STAGING"; rm -f "$STAGING.dmg"' EXIT
ditto build/Margins.app "$STAGING/Margins.app"
ln -s /Applications "$STAGING/Applications"
cp LICENSE README.md "$STAGING/"
# Create HFS+ without mounting a virtual disk, then compress to standard UDIF.
# This also works in build sandboxes without access to disk-image devices.
hdiutil makehybrid -hfs -hfs-volume-name "Margins ${MARGINS_VERSION}" \
  -o "$STAGING.dmg" "$STAGING"
hdiutil convert "$STAGING.dmg" -format UDZO -ov -o "build/${NAME}.dmg"
hdiutil verify "build/${NAME}.dmg"
(cd build && shasum -a 256 "${NAME}.dmg" > "${NAME}.dmg.sha256")
echo "Packaged build/${NAME}.dmg"
