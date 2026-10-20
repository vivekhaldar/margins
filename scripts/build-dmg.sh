#!/usr/bin/env bash
# Package a release app and an Applications shortcut in a compressed disk image.
set -euo pipefail
cd "$(dirname "$0")/.."
export MARGINS_VERSION=${MARGINS_VERSION:-0.2.0}
scripts/build-app.sh
ARCH=$(uname -m)
NAME="Margins-${MARGINS_VERSION}-${ARCH}"
WORKING=$(mktemp -d "$PWD/build/dmg-work.XXXXXX")
STAGING="$WORKING/staging"
trap 'rm -rf "$WORKING"' EXIT
mkdir "$STAGING"
ditto build/Margins.app "$STAGING/Margins.app"
codesign --verify --deep --strict "$STAGING/Margins.app"
ln -s /Applications "$STAGING/Applications"
cp LICENSE README.md "$STAGING/"
# Native HFS+ creation preserves the signature; makehybrid adds invalid Finder metadata.
for ATTEMPT in 1 2 3; do
  IMAGE="$WORKING/image-${ATTEMPT}.dmg"
  if CREATE_OUTPUT=$(hdiutil create -srcfolder "$STAGING" -volname "Margins ${MARGINS_VERSION}" \
    -fs HFS+ -format UDZO "$IMAGE" 2>&1); then
    printf '%s\n' "$CREATE_OUTPUT"
    break
  fi
  printf '%s\n' "$CREATE_OUTPUT" >&2
  # macOS can briefly report Resource busy immediately after a signed app is built.
  if [[ "$ATTEMPT" == 3 || "$CREATE_OUTPUT" != *"Resource busy"* ]]; then exit 1; fi
  sleep 2
done
hdiutil verify "$IMAGE"
mv -f "$IMAGE" "build/${NAME}.dmg"
(cd build && shasum -a 256 "${NAME}.dmg" > "${NAME}.dmg.sha256")
echo "Packaged build/${NAME}.dmg"
