#!/usr/bin/env bash
# Build Margins.app from the SwiftPM package (Command Line Tools are enough — no Xcode needed).
#   scripts/build-app.sh            # release build → build/Margins.app
#   scripts/build-app.sh --open     # …and launch it
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
VERSION=${MARGINS_VERSION:-0.2.0}
BUILD_NUMBER=${MARGINS_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "MARGINS_VERSION must be X.Y.Z and MARGINS_BUILD_NUMBER must be numeric" >&2
  exit 1
fi
swift build -c "$CONFIG" --product Margins
BIN_DIR=$(swift build -c "$CONFIG" --show-bin-path)

APP=build/Margins.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Margins" "$APP/Contents/MacOS/Margins"
cp -R "$BIN_DIR/Margins_Margins.bundle" "$APP/Contents/Resources/"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # regenerate: swift scripts/make-icon.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Margins</string>
  <key>CFBundleDisplayName</key><string>Margins</string>
  <key>CFBundleIdentifier</key><string>com.vivekhaldar.margins</string>
  <key>CFBundleExecutable</key><string>Margins</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Margins Document</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>CFBundleTypeIconFile</key><string>AppIcon</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>com.vivekhaldar.margins.document</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.vivekhaldar.margins.document</string>
      <key>UTTypeDescription</key><string>Margins Document</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>margins</string></array></dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"
if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
