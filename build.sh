#!/bin/bash
# Builds Mixer.app into ./build.
#   ./build.sh          build only
#   ./build.sh install  also copy to /Applications and launch
#   ./build.sh dmg      also create build/Mixer-<version>.dmg for sharing
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Mixer"

APP=build/Mixer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Mixer"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon (generated once, then reused).
if [[ ! -f build/AppIcon.icns ]]; then
  ICONSET=build/AppIcon.iconset
  mkdir -p "$ICONSET"
  swift Scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
  rm -rf "$ICONSET" build/icon-1024.png
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature unless SIGN_IDENTITY names a certificate.
codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x Mixer 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Mixer.app
  cp -R "$APP" /Applications/
  open /Applications/Mixer.app
  echo "Installed to /Applications/Mixer.app and launched."
fi

if [[ "${1:-}" == "dmg" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
  DMG="build/Mixer-$VERSION.dmg"
  STAGE=build/dmg-stage
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Mixer" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "Created $DMG"
fi
